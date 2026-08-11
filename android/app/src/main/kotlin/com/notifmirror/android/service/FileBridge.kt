package com.notifmirror.android.service

import android.app.Notification
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import androidx.core.content.FileProvider
import com.notifmirror.android.App
import com.notifmirror.android.protocol.WireMessage
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.random.Random
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** A transfer shown in the app's Transfers card. Both directions, live and
 *  recently-finished. */
data class TransferEntry(
    val id: String,
    val direction: Direction,
    val name: String,
    val size: Long,
    val bytesTransferred: Long,
    val status: Status,
    val updatedAt: Long
) {
    enum class Direction { Incoming, Outgoing }
    enum class Status { Pending, Active, Done, Failed, Cancelled }
}

/**
 * Handles incoming file transfers from the Mac (writes to Downloads via
 * MediaStore on Android 10+, or directly to the public Downloads dir on older
 * releases) and sends outgoing transfers when the user shares content to
 * NotifMirror.
 *
 * Chunk size is fixed at 256 KiB on both sides; we rely on OkHttp's
 * [okhttp3.WebSocket.queueSize] back-pressure signal to avoid runaway buffering.
 */
class FileBridge(private val context: Context) {

    private val incoming = ConcurrentHashMap<String, Incoming>()
    private val outgoing = ConcurrentHashMap<String, Outgoing>()

    private data class Incoming(
        val name: String,
        val size: Long,
        val uri: Uri?,
        val tempFile: File?,
        val outputStream: OutputStream,
        var received: Long
    )

    private data class Outgoing(
        val xid: String,
        val name: String,
        val size: Long,
        val uri: Uri,
        var offset: Long,
        @Volatile var cancelled: Boolean = false
    )

    fun handleIncoming(msg: WireMessage) {
        when (msg) {
            is WireMessage.FileOffer -> onOffer(msg)
            is WireMessage.FileChunk -> onChunk(msg)
            is WireMessage.FileDone -> onDone(msg)
            is WireMessage.FileCancel -> onIncomingCancel(msg)
            is WireMessage.FileAccept -> onAccept(msg)
            is WireMessage.FileReject -> onReject(msg)
            is WireMessage.FileAck -> onAck(msg)
            else -> {}
        }
    }

    private fun upsert(entry: TransferEntry) {
        _transfers.update { current ->
            val next = (current.filterNot { it.id == entry.id } + entry)
                .sortedByDescending { it.updatedAt }
            next.take(HISTORY_LIMIT)
        }
    }

    fun cancelAll() {
        incoming.keys.toList().forEach { xid ->
            val s = incoming.remove(xid) ?: return@forEach
            runCatching { s.outputStream.close() }
            s.tempFile?.delete()
        }
        outgoing.values.forEach { it.cancelled = true }
        outgoing.clear()
    }

    // ───────────────────────────────────────── Incoming (Mac → Android)

    private fun onOffer(offer: WireMessage.FileOffer) {
        try {
            val (uri, temp, os) = openDownloadsSink(offer.name)
            incoming[offer.xid] = Incoming(
                name = offer.name,
                size = offer.size,
                uri = uri,
                tempFile = temp,
                outputStream = os,
                received = 0
            )
            upsert(
                TransferEntry(
                    id = offer.xid,
                    direction = TransferEntry.Direction.Incoming,
                    name = offer.name,
                    size = offer.size,
                    bytesTransferred = 0,
                    status = TransferEntry.Status.Active,
                    updatedAt = System.currentTimeMillis()
                )
            )
            // Keep the Wi-Fi radio active during the incoming transfer so AP→
            // phone chunks aren't stuck in DTIM buffers. Balanced in onDone /
            // failIncoming / onIncomingCancel.
            RadioKeepAlive.begin()
            MirrorCore.dispatch(WireMessage.FileAccept(offer.xid))
        } catch (e: Throwable) {
            Log.w(TAG, "offer open failed", e)
            MirrorCore.dispatch(WireMessage.FileReject(offer.xid, "io_error"))
        }
    }

    private fun onChunk(chunk: WireMessage.FileChunk) {
        // Legacy WS chunk path — bytes now arrive on the raw-TCP data channel
        // via onBinaryChunk. Kept for peers that haven't picked up a dataPort.
        val bytes = try { Base64.decode(chunk.data, Base64.NO_WRAP) } catch (_: Throwable) {
            failIncoming(chunk.xid, "io_error"); return
        }
        onBinaryChunk(chunk.xid, chunk.offset, bytes, chunk.last)
    }

    /** Entry point from DataClient. Writes bytes to the open output stream
     *  without any base64 round-trip. */
    fun onBinaryChunk(xid: String, offset: Long, bytes: ByteArray, last: Boolean) {
        val s = incoming[xid] ?: return
        try {
            if (bytes.isNotEmpty()) {
                s.outputStream.write(bytes)
                s.received += bytes.size
            }
            upsert(
                TransferEntry(
                    id = xid,
                    direction = TransferEntry.Direction.Incoming,
                    name = s.name,
                    size = s.size,
                    bytesTransferred = s.received,
                    status = TransferEntry.Status.Active,
                    updatedAt = System.currentTimeMillis()
                )
            )
            // `last` is informational here; the FileDone WS message still
            // drives the flush/close/ack path in onDone.
            @Suppress("UNUSED_PARAMETER") val _u = offset
            @Suppress("UNUSED_PARAMETER") val _v = last
        } catch (e: Throwable) {
            Log.w(TAG, "chunk write failed", e)
            failIncoming(xid, "io_error")
        }
    }

    private fun onDone(done: WireMessage.FileDone) {
        val s = incoming.remove(done.xid) ?: return
        RadioKeepAlive.end()
        val ok: Boolean
        val err: String?
        try {
            s.outputStream.flush()
            s.outputStream.close()
            if (s.size > 0 && s.received != s.size) {
                ok = false; err = "size_mismatch"
            } else {
                ok = true; err = null
            }
        } catch (e: Throwable) {
            Log.w(TAG, "close failed", e)
            failIncoming(done.xid, "io_error"); return
        }
        if (ok) notifyArrived(s)
        upsert(
            TransferEntry(
                id = done.xid,
                direction = TransferEntry.Direction.Incoming,
                name = s.name,
                size = s.size,
                bytesTransferred = s.received,
                status = if (ok) TransferEntry.Status.Done else TransferEntry.Status.Failed,
                updatedAt = System.currentTimeMillis()
            )
        )
        MirrorCore.dispatch(WireMessage.FileAck(done.xid, ok, err))
    }

    private fun notifyArrived(s: Incoming) {
        try {
            val nm = context.getSystemService(android.app.NotificationManager::class.java) ?: return
            val openIntent = buildOpenIntent(s)
            val pi = PendingIntent.getActivity(
                context, notifyIdSeq.incrementAndGet(), openIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val notif = Notification.Builder(context, App.TRANSFERS_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("File received from Mac")
                .setContentText(s.name)
                .setStyle(Notification.BigTextStyle().bigText("${s.name} • saved to Downloads"))
                .setAutoCancel(true)
                .setContentIntent(pi)
                .build()
            nm.notify(notifyIdSeq.get(), notif)
        } catch (e: Throwable) {
            Log.w(TAG, "notify failed", e)
        }
    }

    private fun buildOpenIntent(s: Incoming): Intent {
        val mime = guessMime(s.name)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val uri: Uri? = when {
            s.uri != null -> s.uri
            s.tempFile != null -> try {
                FileProvider.getUriForFile(
                    context, "${context.packageName}.fileprovider", s.tempFile
                )
            } catch (e: Throwable) { Log.w(TAG, "FileProvider failed", e); null }
            else -> null
        }
        if (uri != null) intent.setDataAndType(uri, mime ?: "*/*")
        return intent
    }

    private fun guessMime(name: String): String? {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "pdf" -> "application/pdf"
            "txt", "log" -> "text/plain"
            "mp3" -> "audio/mpeg"
            "mp4", "m4v" -> "video/mp4"
            "zip" -> "application/zip"
            else -> null
        }
    }

    private fun onIncomingCancel(cancel: WireMessage.FileCancel) {
        val s = incoming.remove(cancel.xid) ?: return
        RadioKeepAlive.end()
        runCatching { s.outputStream.close() }
        s.tempFile?.delete()
        upsert(
            TransferEntry(
                id = cancel.xid,
                direction = TransferEntry.Direction.Incoming,
                name = s.name,
                size = s.size,
                bytesTransferred = s.received,
                status = TransferEntry.Status.Cancelled,
                updatedAt = System.currentTimeMillis()
            )
        )
        // Nothing to ack; sender already gave up.
    }

    private fun failIncoming(xid: String, reason: String) {
        val s = incoming.remove(xid) ?: return
        RadioKeepAlive.end()
        runCatching { s.outputStream.close() }
        s.tempFile?.delete()
        upsert(
            TransferEntry(
                id = xid,
                direction = TransferEntry.Direction.Incoming,
                name = s.name,
                size = s.size,
                bytesTransferred = s.received,
                status = TransferEntry.Status.Failed,
                updatedAt = System.currentTimeMillis()
            )
        )
        MirrorCore.dispatch(WireMessage.FileCancel(xid, reason))
    }

    /**
     * Opens an output sink in the public Downloads folder. On API 29+ this
     * goes through MediaStore (no storage permission needed); on older
     * releases it writes directly to the legacy Downloads dir.
     */
    private fun openDownloadsSink(displayName: String): Triple<Uri?, File?, OutputStream> {
        val safe = sanitise(displayName)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, safe)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert returned null")
            val os = resolver.openOutputStream(uri, "w")
                ?: throw IllegalStateException("openOutputStream returned null")
            Triple(uri, null, os)
        } else {
            @Suppress("DEPRECATION")
            val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            dir.mkdirs()
            val file = uniquePath(dir, safe)
            Triple(null, file, FileOutputStream(file))
        }
    }

    private fun sanitise(name: String): String =
        name.replace(Regex("[\\\\/:*?\"<>|]"), "_").take(200).ifEmpty { "file.bin" }

    private fun uniquePath(dir: File, name: String): File {
        var f = File(dir, name)
        if (!f.exists()) return f
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        for (i in 1..999) {
            f = File(dir, "$stem ($i)$ext")
            if (!f.exists()) return f
        }
        return f
    }

    // ───────────────────────────────────────── Outgoing (Android → Mac)

    fun sendFile(uri: Uri, displayName: String, size: Long): String {
        val xid = newXid()
        outgoing[xid] = Outgoing(xid = xid, name = displayName, size = size, uri = uri, offset = 0)
        upsert(
            TransferEntry(
                id = xid,
                direction = TransferEntry.Direction.Outgoing,
                name = displayName,
                size = size,
                bytesTransferred = 0,
                status = TransferEntry.Status.Pending,
                updatedAt = System.currentTimeMillis()
            )
        )
        MirrorCore.dispatch(
            WireMessage.FileOffer(
                xid = xid, name = displayName, size = size, mime = null, sha256 = null
            )
        )
        return xid
    }

    private fun onAccept(accept: WireMessage.FileAccept) {
        val s = outgoing[accept.xid] ?: return
        upsert(
            TransferEntry(
                id = accept.xid,
                direction = TransferEntry.Direction.Outgoing,
                name = s.name,
                size = s.size,
                bytesTransferred = 0,
                status = TransferEntry.Status.Active,
                updatedAt = System.currentTimeMillis()
            )
        )
        // Pump from a background thread so the socket stays responsive.
        Thread({ pump(s) }, "file-pump-${s.xid}").start()
    }

    private fun onReject(reject: WireMessage.FileReject) {
        val s = outgoing.remove(reject.xid) ?: return
        upsert(
            TransferEntry(
                id = reject.xid,
                direction = TransferEntry.Direction.Outgoing,
                name = s.name,
                size = s.size,
                bytesTransferred = s.offset,
                status = TransferEntry.Status.Cancelled,
                updatedAt = System.currentTimeMillis()
            )
        )
    }

    private fun onAck(ack: WireMessage.FileAck) {
        val s = outgoing.remove(ack.xid) ?: return
        upsert(
            TransferEntry(
                id = ack.xid,
                direction = TransferEntry.Direction.Outgoing,
                name = s.name,
                size = s.size,
                bytesTransferred = s.offset,
                status = if (ack.ok) TransferEntry.Status.Done else TransferEntry.Status.Failed,
                updatedAt = System.currentTimeMillis()
            )
        )
    }

    private fun pump(s: Outgoing) {
        val resolver = context.contentResolver
        RadioKeepAlive.begin()
        try {
            resolver.openInputStream(s.uri)?.use { input ->
                val buf = ByteArray(CHUNK_SIZE)
                var offset = s.offset
                while (!s.cancelled) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    val payload = if (n == buf.size) buf.copyOf() else buf.copyOf(n)
                    val last = (s.size in 1..(offset + n))

                    var spins = 0
                    while (!MirrorCore.wsHasRoom() && !s.cancelled) {
                        Thread.sleep(5)
                        if (++spins > 20_000) break
                    }

                    val sent = MirrorCore.sendBinaryChunk(
                        kind = MirrorCore.KIND_FILE,
                        id = s.xid, offset = offset, payload = payload, last = last
                    )
                    if (!sent) {
                        upsertProgress(s, offset, TransferEntry.Status.Failed)
                        MirrorCore.dispatch(WireMessage.FileCancel(s.xid, "ws_unavailable"))
                        outgoing.remove(s.xid)
                        return@use
                    }
                    offset += n
                    s.offset = offset
                    upsertProgress(s, offset, TransferEntry.Status.Active)
                    if (last) break
                }
                if (!s.cancelled) {
                    upsertProgress(s, offset, TransferEntry.Status.Done)
                    MirrorCore.dispatch(WireMessage.FileDone(s.xid))
                } else {
                    upsertProgress(s, offset, TransferEntry.Status.Cancelled)
                }
            } ?: run {
                upsertProgress(s, s.offset, TransferEntry.Status.Failed)
                MirrorCore.dispatch(WireMessage.FileCancel(s.xid, "io_error"))
                outgoing.remove(s.xid)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "pump failed", e)
            upsertProgress(s, s.offset, TransferEntry.Status.Failed)
            MirrorCore.dispatch(WireMessage.FileCancel(s.xid, "io_error"))
            outgoing.remove(s.xid)
        } finally {
            RadioKeepAlive.end()
        }
    }

    private fun upsertProgress(s: Outgoing, transferred: Long, status: TransferEntry.Status) {
        upsert(
            TransferEntry(
                id = s.xid,
                direction = TransferEntry.Direction.Outgoing,
                name = s.name,
                size = s.size,
                bytesTransferred = transferred,
                status = status,
                updatedAt = System.currentTimeMillis()
            )
        )
    }

    private fun newXid(): String {
        val bytes = ByteArray(4)
        Random.nextBytes(bytes)
        return bytes.joinToString("") { "%02X".format(it) }
    }

    companion object {
        private const val TAG = "FileBridge"
        private const val CHUNK_SIZE = 256 * 1024
        private const val HISTORY_LIMIT = 30
        private val notifyIdSeq = AtomicInteger(5000)

        /** Live + recently-finished transfers, newest first, for the app UI. */
        private val _transfers = MutableStateFlow<List<TransferEntry>>(emptyList())
        val transfers: StateFlow<List<TransferEntry>> = _transfers.asStateFlow()
    }
}
