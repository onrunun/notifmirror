package com.notifmirror.android.service

import android.util.Log
import com.notifmirror.android.protocol.PROTO_VERSION
import com.notifmirror.android.protocol.WireCodec
import com.notifmirror.android.protocol.WireMessage
import com.notifmirror.android.security.pinnedSslSocketFactory
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.ConcurrentLinkedDeque
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HostnameVerifier

interface WsClientCallbacks {
    fun onConnected()
    fun onAuthenticated(serverName: String, serverFeatures: List<String>, dataPort: Int)
    fun onDisconnected()
    fun onDismiss(key: String)
    fun onAction(key: String, actionId: String, text: String?)
    fun onClip(text: String, origin: String, seq: Int)
    fun onMediaCmd(cmd: String, value: Int?)
    fun onFileMessage(message: WireMessage)
    fun onFsMessage(message: WireMessage) {}
    /** Bulk file bytes arrive as WS binary frames. */
    fun onBinaryMessage(bytes: ByteArray) {}
    /** Mac asked us to fire a real local notification from this app's
     *  package so the listener mirrors it back end-to-end. */
    fun onTestRequest(reqId: String) {}
}

class WsClient(
    private val secret: String,
    private val deviceName: String,
    private val features: List<String>,
    /// SHA-256 of the Mac server cert's SubjectPublicKeyInfo (base64),
    /// taken from the pairing QR. Pins the TLS handshake.
    private val serverFp: String,
    private val callbacks: WsClientCallbacks
) {
    private val client: OkHttpClient = run {
        val (factory, trustManager) = pinnedSslSocketFactory(serverFp)
        OkHttpClient.Builder()
            // The socket layer has multiple independent timeouts. All of them
            // have to tolerate the transient 10–30s TCP stalls we see on this
            // Wi-Fi link during file transfers, otherwise ONE of them trips and
            // OkHttp force-closes the socket — the real root cause of the
            // disconnect cycle we were seeing in logs.
            //
            // - pingInterval: how often OkHttp sends a WebSocket PING frame. If
            //   no pong comes back within the same interval, the socket is
            //   killed. 60s is our outer bound.
            // - readTimeout: max time between successive bytes arriving from the
            //   socket. 0 = disabled; the ping mechanism is what detects
            //   actually-dead connections, so we want to tolerate any inter-
            //   chunk gap that the ping still considers healthy.
            // - writeTimeout: max time a single socket write may block before
            //   the socket is failed. Default 10s. When TCP send window is
            //   closed because the Mac's recv buffer is momentarily full (or
            //   due to Wi-Fi packet loss retransmits), the writer thread can
            //   legitimately block for >10s, trip the default, and kill the
            //   connection. Match the ping interval.
            // - callTimeout: upper bound for an entire call; WS lives long-
            //   running so we disable.
            .pingInterval(60, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.MILLISECONDS)
            // Self-signed cert + SPKI pinning. The cert's CN is "NotifMirror"
            // and we connect to a private IP, so the default hostname verifier
            // would reject every connection. The pinning trust manager already
            // proves we're talking to the right server, so accept any name.
            .sslSocketFactory(factory, trustManager)
            .hostnameVerifier(HostnameVerifier { _, _ -> true })
            .build()
    }

    private val socket = AtomicReference<WebSocket?>(null)
    private val authed = AtomicBoolean(false)
    private val outbound = ConcurrentLinkedDeque<String>()
    private var currentUrl: String? = null

    @Volatile var isConnected: Boolean = false
        private set

    fun connect(host: String, port: Int) {
        val url = "wss://$host:$port"
        currentUrl = url
        val request = Request.Builder().url(url).build()
        val ws = client.newWebSocket(request, listener)
        socket.set(ws)
    }

    fun close() {
        socket.getAndSet(null)?.close(1000, "client shutdown")
        authed.set(false)
        isConnected = false
    }

    fun send(message: WireMessage) {
        val text = try {
            WireCodec.encode(message)
        } catch (e: Throwable) {
            Log.w(TAG, "encode failed", e); return
        }
        val ws = socket.get()
        if (ws != null && authed.get()) {
            if (!ws.send(text)) {
                outbound.addLast(text)
            }
        } else {
            outbound.addLast(text)
            // Bound the queue.
            while (outbound.size > 200) outbound.pollFirst()
        }
    }

    /** Returns true if the underlying socket accepted the frame without queueing. */
    fun trySend(message: WireMessage): Boolean {
        val ws = socket.get() ?: return false
        if (!authed.get()) return false
        val text = try {
            WireCodec.encode(message)
        } catch (e: Throwable) {
            Log.w(TAG, "encode failed", e); return false
        }
        return ws.send(text)
    }

    /** Sends a raw binary WS frame. Returns false if the socket can't accept
     *  it right now (backpressure) or the client isn't authenticated. */
    fun sendBinary(bytes: ByteArray): Boolean {
        val ws = socket.get() ?: return false
        if (!authed.get()) return false
        return ws.send(bytes.toByteString(0, bytes.size))
    }

    fun queueSize(): Long = socket.get()?.queueSize() ?: 0L

    private fun drainOutbound() {
        val ws = socket.get() ?: return
        while (true) {
            val msg = outbound.pollFirst() ?: break
            if (!ws.send(msg)) {
                outbound.addFirst(msg)
                break
            }
        }
    }

    private val listener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            Log.i(TAG, "ws open")
            isConnected = true
            callbacks.onConnected()
            val hello = WireMessage.Hello(
                secret = secret,
                deviceName = deviceName,
                proto = PROTO_VERSION,
                features = features
            )
            webSocket.send(WireCodec.encode(hello))
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            callbacks.onBinaryMessage(bytes.toByteArray())
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val message = try { WireCodec.decode(text) } catch (e: Exception) {
                Log.w(TAG, "decode error", e); return
            }
            when (message) {
                is WireMessage.HelloAck -> {
                    if (message.accepted) {
                        authed.set(true)
                        callbacks.onAuthenticated(message.serverName, message.features, message.dataPort)
                        drainOutbound()
                    } else {
                        Log.w(TAG, "auth rejected by server")
                        webSocket.close(1008, "auth rejected")
                    }
                }
                is WireMessage.Dismiss -> callbacks.onDismiss(message.key)
                is WireMessage.Action -> callbacks.onAction(message.key, message.actionId, message.text)
                is WireMessage.Clip -> callbacks.onClip(message.text, message.origin, message.seq)
                is WireMessage.MediaCmd -> callbacks.onMediaCmd(message.cmd, message.value)
                is WireMessage.FileOffer,
                is WireMessage.FileAccept,
                is WireMessage.FileReject,
                is WireMessage.FileChunk,
                is WireMessage.FileDone,
                is WireMessage.FileAck,
                is WireMessage.FileCancel -> callbacks.onFileMessage(message)
                is WireMessage.FsList,
                is WireMessage.FsDelete,
                is WireMessage.FsMkdir,
                is WireMessage.FsDisk,
                is WireMessage.FsDu,
                is WireMessage.FsRead,
                is WireMessage.FsWrite,
                is WireMessage.FsChunk,
                is WireMessage.FsCancel -> callbacks.onFsMessage(message)
                is WireMessage.TestRequest -> callbacks.onTestRequest(message.reqId)
                WireMessage.Ping -> webSocket.send(WireCodec.encode(WireMessage.Pong))
                WireMessage.Pong -> {}
                is WireMessage.Error -> Log.w(TAG, "server error: ${message.code} ${message.msg}")
                is WireMessage.Unknown -> Log.i(TAG, "ignoring unknown message type: ${message.type}")
                else -> {}
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            Log.i(TAG, "ws closing $code $reason")
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            Log.i(TAG, "ws closed $code $reason")
            isConnected = false
            authed.set(false)
            callbacks.onDisconnected()
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            Log.w(TAG, "ws failure", t)
            isConnected = false
            authed.set(false)
            callbacks.onDisconnected()
        }
    }

    companion object { private const val TAG = "WsClient" }
}
