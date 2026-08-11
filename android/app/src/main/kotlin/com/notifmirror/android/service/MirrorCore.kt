package com.notifmirror.android.service

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import com.notifmirror.android.data.PairingStore
import com.notifmirror.android.protocol.WireMessage
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Owns the WebSocket client and the outbound mirror pipeline. Lifetime is
 * tied to [MirrorListenerService] — the NotificationListenerService is kept
 * bound by the system whenever the user has granted notification access, so
 * there is no separate foreground service and we don't appear in the OS
 * "Active apps" panel.
 */
class MirrorCore(context: Context) : WsClientCallbacks {

    private val appContext: Context = context.applicationContext
    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    private var pairing: com.notifmirror.android.data.PairingPayload? = null
    private var ws: WsClient? = null
    private var discovery: Discovery? = null
    private var backoffSeconds = 1L
    private var connectivity: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /// Features advertised in HELLO. `fsbrowse` is conditional on the
    /// MANAGE_EXTERNAL_STORAGE runtime grant.
    private fun currentFeatures(): List<String> {
        val base = mutableListOf("clip", "media", "file", "battery")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            android.os.Environment.isExternalStorageManager()) {
            base.add("fsbrowse")
        }
        return base
    }

    private val clipboardBridge = ClipboardBridge(appContext)
    private val mediaBridge = MediaBridge(appContext)
    private val _fileBridge = FileBridge(appContext)
    private val fileBrowseBridge = FileBrowseBridge(appContext)
    private val batteryBridge = BatteryBridge(appContext)

    @Volatile private var lastResolvedHost: String? = null
    @Volatile private var lastResolvedPort: Int = 0

    /// Held only while a file transfer is in flight. Forces the Wi-Fi radio
    /// to stay fully powered (no micro-sleeps between packets) — fixes the
    /// 15–60s mid-pull TCP stalls we traced to the radio dozing between
    /// bursts on a plugged-in phone. Reference-counted so nested reads /
    /// concurrent pulls stack correctly. Held only during transfers so it
    /// doesn't drain battery during idle notification mirroring.
    private var wifiHighPerfLock: WifiManager.WifiLock? = null

    fun start() {
        instance = this
        _runningFlow.value = true
        mediaBridge.start()
        batteryBridge.start()
        initWifiHighPerfLock()
        ensureRunning()
        registerNetworkCallback()
        while (true) {
            val pending = pendingQueue.poll() ?: break
            send(pending)
        }
    }

    fun stop() {
        if (instance === this) instance = null
        _runningFlow.value = false
        _connectedFlow.value = false
        try { mediaBridge.stop() } catch (_: Throwable) {}
        try { batteryBridge.stop() } catch (_: Throwable) {}
        try { _fileBridge.cancelAll() } catch (_: Throwable) {}
        try { fileBrowseBridge.cancelAll() } catch (_: Throwable) {}
        ws?.close()
        ws = null
        discovery?.stop()
        discovery = null
        try {
            val cb = networkCallback
            if (cb != null) connectivity?.unregisterNetworkCallback(cb)
        } catch (_: Throwable) {}
        networkCallback = null
        connectivity = null
        // Drain any outstanding refcounts so the radio isn't stuck high-perf.
        wifiHighPerfLock?.let { l ->
            while (l.isHeld) { try { l.release() } catch (_: Throwable) { break } }
        }
        wifiHighPerfLock = null
        executor.shutdownNow()
    }

    private fun initWifiHighPerfLock() {
        try {
            val wm = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiHighPerfLock = wm.createWifiLock(mode, "notifmirror:fs-transfer").also {
                it.setReferenceCounted(true)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "wifi high-perf lock init failed", e)
            wifiHighPerfLock = null
        }
    }

    private fun acquireWifiHighPerf() {
        try {
            wifiHighPerfLock?.acquire()
            val m = "[core] wifiLock acquired isHeld=${wifiHighPerfLock?.isHeld}"
            Log.i(TAG, m)
            DebugLog.line(m)
        } catch (e: Throwable) {
            Log.w(TAG, "wifi lock acquire failed", e)
        }
    }

    private fun releaseWifiHighPerf() {
        try {
            val l = wifiHighPerfLock ?: return
            if (l.isHeld) l.release()
            val m = "[core] wifiLock released isHeld=${l.isHeld}"
            Log.i(TAG, m)
            DebugLog.line(m)
        } catch (e: Throwable) {
            Log.w(TAG, "wifi lock release failed", e)
        }
    }

    /// Called after pairing is saved (or cleared) so WS picks up the new
    /// host/secret without waiting for the next reconnect tick.
    fun kickReconnect() {
        ensureRunning()
    }

    private fun ensureRunning() {
        val store = PairingStore(appContext)
        val p = store.load() ?: run {
            Log.i(TAG, "no pairing yet — idle")
            return
        }
        val previous = pairing
        val changed = previous == null ||
            previous.secret != p.secret ||
            previous.host != p.host ||
            previous.port != p.port ||
            previous.fp != p.fp
        pairing = p
        if (ws == null || changed) {
            if (changed && ws != null) {
                Log.i(TAG, "pairing changed — recreating WsClient")
                ws?.close()
                lastResolvedHost = null
                lastResolvedPort = 0
            }
            ws = WsClient(
                secret = p.secret,
                deviceName = Build.MODEL ?: "Android",
                features = currentFeatures(),
                serverFp = p.fp,
                callbacks = this
            )
            backoffSeconds = 1
        }
        attemptConnect()
        startDiscovery()
    }

    private fun startDiscovery() {
        if (discovery != null) return
        discovery = Discovery(appContext).also { d ->
            d.start { host, port ->
                lastResolvedHost = host
                lastResolvedPort = port
                if (ws?.isConnected != true) attemptConnect()
            }
        }
    }

    private fun attemptConnect() {
        val w = ws ?: return
        if (w.isConnected) return
        val host = lastResolvedHost ?: pairing?.host ?: return
        val port = if (lastResolvedPort > 0) lastResolvedPort else pairing?.port ?: return
        Log.i(TAG, "connecting to $host:$port")
        w.connect(host, port)
    }

    private fun scheduleReconnect() {
        executor.schedule({
            attemptConnect()
        }, backoffSeconds, TimeUnit.SECONDS)
        backoffSeconds = (backoffSeconds * 2).coerceAtMost(60)
    }

    private fun registerNetworkCallback() {
        connectivity = appContext.getSystemService(ConnectivityManager::class.java)
        val request = NetworkRequest.Builder()
            .addCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Log.i(TAG, "network available — trying immediate reconnect")
                backoffSeconds = 1
                executor.schedule({ attemptConnect() }, 200, TimeUnit.MILLISECONDS)
            }
        }
        networkCallback = cb
        connectivity?.registerNetworkCallback(request, cb)
    }

    private fun send(message: WireMessage) {
        ws?.send(message)
    }

    /** Returns true if the frame was passed to the socket; false on back-pressure. */
    private fun sendWithBackpressure(message: WireMessage): Boolean {
        val w = ws ?: return false
        if (w.queueSize() > BACKPRESSURE_THRESHOLD) return false
        return w.trySend(message)
    }

    // -------- WsClientCallbacks --------

    override fun onConnected() { Log.i(TAG, "ws connected") }

    override fun onAuthenticated(serverName: String, serverFeatures: List<String>, dataPort: Int) {
        Log.i(TAG, "authenticated with $serverName (features: $serverFeatures)")
        backoffSeconds = 1
        _connectedFlow.value = true
        // Push current media snapshot right away so the Mac menu isn't empty.
        mediaBridge.publishIfConnected()
        // Same for battery — push initial state so the Mac shows it without
        // waiting for the next system broadcast.
        batteryBridge.publishIfConnected()
        // dataPort is retired — bulk file bytes now ride as WS binary frames.
    }

    override fun onDisconnected() {
        Log.i(TAG, "ws disconnected, scheduling reconnect")
        _connectedFlow.value = false
        try { _fileBridge.cancelAll() } catch (_: Throwable) {}
        try { fileBrowseBridge.cancelAll() } catch (_: Throwable) {}
        scheduleReconnect()
    }

    // -------- Binary chunk routing --------
    //
    // Fixed 18-byte header:
    //   [0]     kind (1 = file_chunk, 2 = fs_chunk)
    //   [1..9]  id (8 ASCII hex)
    //   [9..17] offset uint64 BE
    //   [17]    flags bit0 = last
    //   [18..]  payload bytes
    override fun onBinaryMessage(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        val kind = bytes[0].toInt() and 0xFF
        if (kind == KIND_HEARTBEAT) return  // radio keep-alive, drop
        if (bytes.size < 18) return
        val id = String(bytes, 1, 8, Charsets.US_ASCII)
        var offset = 0L
        for (i in 0..7) offset = (offset shl 8) or (bytes[9 + i].toLong() and 0xFF)
        val last = (bytes[17].toInt() and 1) != 0
        val payload = if (bytes.size > 18) bytes.copyOfRange(18, bytes.size) else ByteArray(0)
        when (kind) {
            KIND_FILE -> _fileBridge.onBinaryChunk(id, offset, payload, last)
            KIND_FS -> fileBrowseBridge.onWriteBytes(id, offset, payload, last)
        }
    }

    override fun onDismiss(key: String) {
        MirrorListenerService.current()?.dismissByKey(key)
    }

    override fun onAction(key: String, actionId: String, text: String?) {
        MirrorListenerService.current()?.replyByKey(key, actionId, text)
    }

    override fun onClip(text: String, origin: String, seq: Int) {
        clipboardBridge.handleRemoteClip(text)
    }

    override fun onMediaCmd(cmd: String, value: Int?) {
        mediaBridge.handleCommand(cmd, value)
    }

    override fun onFileMessage(message: WireMessage) {
        _fileBridge.handleIncoming(message)
    }

    override fun onFsMessage(message: WireMessage) {
        fileBrowseBridge.handleIncoming(message)
    }

    override fun onTestRequest(reqId: String) {
        // Post a real notification from this app's package. The
        // NotificationListener catches it and the normal mirror pipeline
        // round-trips it back to the Mac so the *whole* path gets exercised
        // (WS in → NotificationManager → listener → WS out → macOS banner).
        // The reqId is embedded in the body so the Mac can correlate the
        // returned `posted` to its outstanding request.
        try {
            val nm = appContext.getSystemService(android.app.NotificationManager::class.java)
                ?: run { Log.w(TAG, "test_request: NotificationManager unavailable"); return }
            val notif = android.app.Notification.Builder(
                appContext, com.notifmirror.android.App.DIAGNOSTICS_CHANNEL_ID
            )
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("NotifMirror end-to-end test")
                .setContentText("Round-trip nonce: $reqId")
                .setAutoCancel(true)
                .build()
            nm.notify(TEST_NOTIF_ID, notif)
        } catch (e: Throwable) {
            Log.w(TAG, "test_request: notify failed", e)
        }
    }

    companion object {
        private const val TAG = "MirrorCore"
        /** Fixed notification ID for the diagnostics test notification —
         *  reusing the same ID means a fresh test replaces the previous one
         *  in the shade rather than piling up. */
        private const val TEST_NOTIF_ID = 0x7E51_7E51.toInt()
        /** OkHttp's `queueSize` is bytes pending. Keep 4 MiB of headroom
         *  so a brief Wi-Fi stall doesn't immediately stop the read thread —
         *  combined with the smaller 64 KiB chunk size, this is ~64 frames
         *  of buffering before we throttle. */
        private const val BACKPRESSURE_THRESHOLD: Long = 4L * 1024 * 1024

        @Volatile
        private var instance: MirrorCore? = null
        private val pendingQueue = ConcurrentLinkedQueue<WireMessage>()

        private val _runningFlow = MutableStateFlow(false)
        val runningFlow: StateFlow<Boolean> = _runningFlow.asStateFlow()

        private val _connectedFlow = MutableStateFlow(false)
        val connectedFlow: StateFlow<Boolean> = _connectedFlow.asStateFlow()

        fun dispatch(message: WireMessage) {
            val s = instance
            if (s != null) s.send(message) else pendingQueue.offer(message)
        }

        fun dispatchWithBackpressure(message: WireMessage): Boolean {
            val s = instance ?: return false
            return s.sendWithBackpressure(message)
        }

        /// Acquire the high-perf WifiLock for the duration of a transfer.
        /// Balanced by a matching `endFileTransfer()`; reference-counted, so
        /// concurrent pulls from multiple handleRead threads stack safely.
        fun beginFileTransfer() { instance?.acquireWifiHighPerf() }
        fun endFileTransfer() { instance?.releaseWifiHighPerf() }

        fun fileBridge(): FileBridge? = instance?._fileBridge

        /// Nudge the running core to pick up new pairing / reconnect. No-op
        /// if the listener isn't bound yet — when it is, [start] will read
        /// pairing from disk on its own.
        fun notifyPairingChanged() { instance?.kickReconnect() }

        const val KIND_FILE = 1
        const val KIND_FS = 2
        /// Heartbeat: tiny binary frame sent every ~10 ms during a transfer
        /// to keep this device's Wi-Fi radio out of power-save so AP→phone
        /// ACKs aren't buffered to DTIM boundaries. Empirically drops
        /// router→phone ping avg from 64 ms → 6 ms on this device.
        const val KIND_HEARTBEAT = 0xFE

        /// Push a binary chunk frame over the existing WebSocket. Encodes
        /// the 18-byte header in-place to avoid any base64 / JSON overhead.
        /// Returns false if the WS isn't authenticated yet or backpressure
        /// is hitting our soft threshold; caller's read loop naturally
        /// throttles since we also gate on WS queueSize.
        fun sendBinaryChunk(
            kind: Int, id: String, offset: Long, payload: ByteArray, last: Boolean
        ): Boolean {
            val w = instance?.ws ?: return false
            val idBytes = id.toByteArray(Charsets.US_ASCII)
            if (idBytes.size != 8) return false
            val buf = ByteArray(18 + payload.size)
            buf[0] = kind.toByte()
            System.arraycopy(idBytes, 0, buf, 1, 8)
            for (i in 0..7) {
                buf[9 + i] = ((offset ushr ((7 - i) * 8)) and 0xFF).toByte()
            }
            buf[17] = if (last) 1 else 0
            System.arraycopy(payload, 0, buf, 18, payload.size)
            return w.sendBinary(buf)
        }

        /// Soft backpressure — returns true if the WS queue has room for
        /// another chunk. Used by bulk readers to throttle their loop so
        /// OkHttp doesn't accumulate unbounded memory.
        fun wsHasRoom(): Boolean {
            val w = instance?.ws ?: return false
            return w.queueSize() < BACKPRESSURE_THRESHOLD
        }

        /// Sends a 1-byte heartbeat WS binary frame. Mac-side decoder sees
        /// kind=0xFE and drops it silently; the only point is radio traffic.
        private val HEARTBEAT_FRAME = byteArrayOf(KIND_HEARTBEAT.toByte())
        fun sendHeartbeat(): Boolean {
            val w = instance?.ws ?: return false
            return w.sendBinary(HEARTBEAT_FRAME)
        }

        /// Exposed for diagnostic logging — report whether the Wi-Fi high-perf
        /// lock is currently held by this process.
        fun isWifiLockHeld(): Boolean = instance?.wifiHighPerfLock?.isHeld == true
    }
}
