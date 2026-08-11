package com.notifmirror.android.service

import android.content.Context
import android.os.StatFs
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import android.util.Log
import com.notifmirror.android.protocol.WireMessage
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Handles `fs_*` protocol messages: directory listing, delete, mkdir, disk
 * usage, and streaming reads/writes. Only active when the user has granted
 * `MANAGE_EXTERNAL_STORAGE` — otherwise the service doesn't advertise the
 * `fsbrowse` feature and Mac shouldn't send us these messages anyway.
 *
 * Streaming reads run on a dedicated single-thread executor so a slow pull
 * can't block the WS dispatch thread. Writes receive chunks on whatever
 * thread the WS delivers them on; we keep state per `reqId` in a concurrent
 * map.
 */
class FileBrowseBridge(private val context: Context) {

    private val readExecutor = Executors.newCachedThreadPool { r ->
        Thread(r, "fs-read").apply { isDaemon = true }
    }

    /// Separate pool for metadata ops (list/delete/mkdir/disk). Keeps the
    /// WebSocket reader thread responsive so notifications and other traffic
    /// don't stall while listing a big directory.
    private val metaExecutor = Executors.newFixedThreadPool(2) { r ->
        Thread(r, "fs-meta").apply { isDaemon = true }
    }

    /// Recursive du scans can take many seconds on /sdcard. Run on their own
    /// thread so a long scan never blocks listings/deletes/disk-usage replies.
    private val duExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "fs-du").apply { isDaemon = true }
    }

    /** Active outgoing reads, keyed by reqId; used to cancel on disconnect. */
    private val activeReads = ConcurrentHashMap<String, AtomicBoolean>()

    /** Active incoming writes, keyed by reqId. */
    private data class IncomingWrite(
        val path: String,
        val expectedSize: Long,
        val out: OutputStream,
        @Volatile var bytesWritten: Long,
    )
    private val activeWrites = ConcurrentHashMap<String, IncomingWrite>()

    /** Dispatch a single `fs_*` message. Metadata ops offload to a worker
     *  pool so they don't stall the WS reader thread; streaming ops (chunks)
     *  stay inline to preserve order. */
    fun handleIncoming(message: WireMessage) {
        when (message) {
            is WireMessage.FsList -> metaExecutor.execute { handleList(message) }
            is WireMessage.FsDelete -> metaExecutor.execute { handleDelete(message) }
            is WireMessage.FsMkdir -> metaExecutor.execute { handleMkdir(message) }
            is WireMessage.FsRename -> metaExecutor.execute { handleRename(message) }
            is WireMessage.FsDisk -> metaExecutor.execute { handleDisk(message) }
            is WireMessage.FsDu -> duExecutor.execute { handleDu(message) }
            is WireMessage.FsRead -> handleRead(message)   // self-dispatches to readExecutor
            is WireMessage.FsWrite -> handleWrite(message)
            is WireMessage.FsChunk -> handleWriteChunk(message)
            is WireMessage.FsCancel -> handleCancel(message)
            else -> {}
        }
    }

    /** Mac has abandoned this reqId (watchdog, unknown-chunk detection, user
     *  cancel). Stop streaming for that reqId so the Wi-Fi link isn't spent
     *  on chunks the Mac will throw away. Applies to both directions:
     *  outgoing reads trip the cancel flag, incoming writes close + delete. */
    private fun handleCancel(msg: WireMessage.FsCancel) {
        Log.i(TAG, "peer cancelled reqId=${msg.reqId} reason=${msg.reason}")
        activeReads[msg.reqId]?.set(true)
        val write = activeWrites.remove(msg.reqId)
        if (write != null) {
            try { write.out.close() } catch (_: Throwable) {}
            try { File(write.path).delete() } catch (_: Throwable) {}
            RadioKeepAlive.end()
            MirrorCore.endFileTransfer()
        }
    }

    fun cancelAll() {
        activeReads.forEach { (_, flag) -> flag.set(true) }
        activeReads.clear()
        activeWrites.values.forEach { w ->
            try { w.out.close() } catch (_: Throwable) {}
        }
        activeWrites.clear()
    }

    // ---------- Metadata ops ----------

    private fun handleList(msg: WireMessage.FsList) {
        try {
            val dir = File(msg.path)
            if (!dir.exists()) {
                reply(WireMessage.FsListResult(msg.reqId, msg.path, emptyList(), "not found"))
                return
            }
            if (!dir.isDirectory) {
                reply(WireMessage.FsListResult(msg.reqId, msg.path, emptyList(), "not a directory"))
                return
            }
            // `File.list()` returns just names (one `readdir`); pairing it with
            // a single `Os.lstat` per entry is much faster than
            // File.listFiles() + .isDirectory/.isFile/.length/.lastModified,
            // each of which does its own native stat (so 4× the syscalls).
            val names = dir.list() ?: emptyArray()
            val sep = if (msg.path.endsWith("/")) "" else "/"
            val entries = ArrayList<WireMessage.FsEntry>(names.size)
            for (name in names) {
                try {
                    val full = msg.path + sep + name
                    val st = Os.lstat(full)
                    val kind = when {
                        OsConstants.S_ISDIR(st.st_mode) -> "dir"
                        OsConstants.S_ISLNK(st.st_mode) -> "link"
                        OsConstants.S_ISREG(st.st_mode) -> "file"
                        else -> "other"
                    }
                    entries.add(
                        WireMessage.FsEntry(
                            name = name,
                            kind = kind,
                            size = if (kind == "file") st.st_size else 0L,
                            mtime = st.st_mtime
                        )
                    )
                } catch (_: Throwable) {
                    // Unreadable entry — skip, don't fail the whole listing.
                }
            }
            reply(WireMessage.FsListResult(msg.reqId, msg.path, entries, null))
        } catch (e: Throwable) {
            Log.w(TAG, "list failed", e)
            reply(WireMessage.FsListResult(msg.reqId, msg.path, emptyList(), e.message ?: "error"))
        }
    }

    private fun handleDelete(msg: WireMessage.FsDelete) {
        try {
            val target = File(msg.path)
            val ok = if (target.isDirectory) target.deleteRecursively() else target.delete()
            reply(WireMessage.FsOpResult(msg.reqId, ok, if (ok) null else "delete failed"))
        } catch (e: Throwable) {
            Log.w(TAG, "delete failed", e)
            reply(WireMessage.FsOpResult(msg.reqId, false, e.message ?: "error"))
        }
    }

    private fun handleMkdir(msg: WireMessage.FsMkdir) {
        try {
            val target = File(msg.path)
            val ok = target.exists() || target.mkdirs()
            reply(WireMessage.FsOpResult(msg.reqId, ok, if (ok) null else "mkdir failed"))
        } catch (e: Throwable) {
            Log.w(TAG, "mkdir failed", e)
            reply(WireMessage.FsOpResult(msg.reqId, false, e.message ?: "error"))
        }
    }

    private fun handleRename(msg: WireMessage.FsRename) {
        try {
            val src = File(msg.from)
            val dst = File(msg.to)
            if (!src.exists()) {
                reply(WireMessage.FsOpResult(msg.reqId, false, "source not found"))
                return
            }
            if (dst.exists()) {
                reply(WireMessage.FsOpResult(msg.reqId, false, "destination already exists"))
                return
            }
            val ok = src.renameTo(dst)
            reply(WireMessage.FsOpResult(msg.reqId, ok, if (ok) null else "rename failed"))
        } catch (e: Throwable) {
            Log.w(TAG, "rename failed", e)
            reply(WireMessage.FsOpResult(msg.reqId, false, e.message ?: "error"))
        }
    }

    private fun handleDisk(msg: WireMessage.FsDisk) {
        try {
            val stat = StatFs(msg.path)
            val block = stat.blockSizeLong
            reply(WireMessage.FsDiskResult(
                reqId = msg.reqId,
                free = stat.availableBlocksLong * block,
                total = stat.blockCountLong * block,
                error = null
            ))
        } catch (e: Throwable) {
            reply(WireMessage.FsDiskResult(msg.reqId, 0, 0, e.message ?: "error"))
        }
    }

    // ---------- Recursive disk usage ----------

    /** Per-subtree accumulator. */
    private data class DuSums(var bytes: Long = 0L, var files: Long = 0L)

    private fun handleDu(msg: WireMessage.FsDu) {
        try {
            val root = File(msg.path)
            if (!root.exists()) {
                reply(WireMessage.FsDuResult(msg.reqId, msg.path, 0, emptyList(), "not found"))
                return
            }
            if (!root.isDirectory) {
                // Single file: trivial result with one entry.
                val st = try { Os.lstat(msg.path) } catch (_: Throwable) { null }
                val size = st?.st_size ?: 0L
                reply(WireMessage.FsDuResult(
                    msg.reqId, msg.path, size,
                    listOf(WireMessage.FsDuEntry(root.name, "file", size, 1)),
                    null
                ))
                return
            }

            val names = root.list() ?: emptyArray()
            val sep = if (msg.path.endsWith("/")) "" else "/"
            val children = ArrayList<WireMessage.FsDuEntry>(names.size)
            var grand = 0L

            for (name in names) {
                val full = msg.path + sep + name
                val st = try { Os.lstat(full) } catch (_: Throwable) { continue }
                val (kind, sums) = when {
                    OsConstants.S_ISDIR(st.st_mode) -> "dir" to walk(full)
                    OsConstants.S_ISREG(st.st_mode) -> "file" to DuSums(st.st_size, 1)
                    OsConstants.S_ISLNK(st.st_mode) -> "link" to DuSums(0, 0)
                    else                            -> "other" to DuSums(0, 0)
                }
                children.add(WireMessage.FsDuEntry(name, kind, sums.bytes, sums.files))
                grand += sums.bytes
            }

            reply(WireMessage.FsDuResult(msg.reqId, msg.path, grand, children, null))
        } catch (e: Throwable) {
            Log.w(TAG, "du failed", e)
            reply(WireMessage.FsDuResult(msg.reqId, msg.path, 0, emptyList(), e.message ?: "error"))
        }
    }

    /** Iterative depth-first walk of [start]. Uses an explicit stack so we
     *  don't blow the JVM frame stack on deeply nested trees. Skips
     *  unreadable entries silently and never follows symlinks. */
    private fun walk(start: String): DuSums {
        val sums = DuSums()
        val stack = ArrayDeque<String>()
        stack.addLast(start)
        while (stack.isNotEmpty()) {
            val dir = stack.removeLast()
            val names = try { File(dir).list() } catch (_: Throwable) { null } ?: continue
            val sep = if (dir.endsWith("/")) "" else "/"
            for (name in names) {
                val full = dir + sep + name
                val st = try { Os.lstat(full) } catch (_: Throwable) { continue }
                when {
                    OsConstants.S_ISDIR(st.st_mode) -> stack.addLast(full)
                    OsConstants.S_ISREG(st.st_mode) -> {
                        sums.bytes += st.st_size
                        sums.files += 1
                    }
                    // Symlinks and "other" contribute nothing — never follow.
                }
            }
        }
        return sums
    }

    // ---------- Read (phone → Mac) ----------

    private fun handleRead(msg: WireMessage.FsRead) {
        val file = File(msg.path)
        if (!file.exists() || !file.isFile) {
            reply(WireMessage.FsReadResult(msg.reqId, 0, "not a file"))
            return
        }
        val size = file.length()
        reply(WireMessage.FsReadResult(msg.reqId, size, null))

        val cancelled = AtomicBoolean(false)
        activeReads[msg.reqId] = cancelled

        readExecutor.execute {
            MirrorCore.beginFileTransfer()
            RadioKeepAlive.begin()
            try {
                Log.i(TAG, "read start reqId=${msg.reqId} size=$size path=${msg.path}")
                DebugLog.line("[fb] read start reqId=${msg.reqId} size=$size wifiLockHeld=${MirrorCore.isWifiLockHeld()}")
                val tStart = System.nanoTime()
                file.inputStream().use { input ->
                    val buffer = ByteArray(CHUNK_SIZE)
                    var offset = 0L
                    var firstChunkSent = false
                    var lastLogMs = 0L
                    while (!cancelled.get()) {
                        val read = input.read(buffer)
                        if (read <= 0) {
                            if (!firstChunkSent) {
                                MirrorCore.sendBinaryChunk(
                                    MirrorCore.KIND_FS,
                                    msg.reqId, 0, ByteArray(0), true
                                )
                            }
                            break
                        }
                        val payload = if (read == buffer.size) buffer.copyOf() else buffer.copyOf(read)
                        val isLast = (offset + read) >= size

                        // Gate on OkHttp's queueSize so a burst of chunks
                        // doesn't accumulate unbounded in the WS queue while
                        // TCP drains over Wi-Fi. The 4 MiB threshold holds
                        // ~64 chunks of headroom — a small burst tolerance
                        // without unbounded memory growth.
                        var spins = 0
                        while (!MirrorCore.wsHasRoom() && !cancelled.get()) {
                            Thread.sleep(5)
                            if (++spins > 20_000) break   // ~100 s safety
                        }

                        val sent = MirrorCore.sendBinaryChunk(
                            MirrorCore.KIND_FS,
                            msg.reqId, offset, payload, isLast
                        )
                        if (!sent) {
                            Log.w(TAG, "ws not ready mid-stream for reqId=${msg.reqId}")
                            break
                        }
                        offset += read
                        firstChunkSent = true

                        val elapsedMs = (System.nanoTime() - tStart) / 1_000_000
                        if (elapsedMs - lastLogMs > 1000) {
                            val mbps = if (elapsedMs > 0) (offset * 1000 / elapsedMs / 1024).toInt() else 0
                            val m = "[fb] progress reqId=${msg.reqId} off=$offset (${offset*100/size}%) elapsed=${elapsedMs}ms avg=${mbps}KB/s"
                            Log.i(TAG, m)
                            DebugLog.line(m)
                            lastLogMs = elapsedMs
                        }
                        if (isLast) break
                    }
                    val totalMs = (System.nanoTime() - tStart) / 1_000_000
                    val mbps = if (totalMs > 0) (offset * 1000 / totalMs / 1024).toInt() else 0
                    val m = "[fb] read done reqId=${msg.reqId} sent=$offset/$size in ${totalMs}ms (${mbps}KB/s)"
                    Log.i(TAG, m)
                    DebugLog.line(m)
                }
            } catch (e: Throwable) {
                Log.w(TAG, "read stream failed", e)
                try {
                    MirrorCore.sendBinaryChunk(
                        MirrorCore.KIND_FS, msg.reqId, 0, ByteArray(0), true
                    )
                } catch (_: Throwable) {}
            } finally {
                activeReads.remove(msg.reqId)
                RadioKeepAlive.end()
                MirrorCore.endFileTransfer()
            }
        }
    }

    // ---------- Write (Mac → phone) ----------

    private fun handleWrite(msg: WireMessage.FsWrite) {
        try {
            val target = File(msg.path)
            target.parentFile?.let { if (!it.exists()) it.mkdirs() }
            val out: OutputStream = FileOutputStream(target)
            activeWrites[msg.reqId] = IncomingWrite(msg.path, msg.size, out, 0)
            // Mac is about to stream chunks in; hold the radio at high perf
            // AND spam keep-alive frames until we see the final chunk in
            // handleWriteChunk.
            MirrorCore.beginFileTransfer()
            RadioKeepAlive.begin()
            reply(WireMessage.FsWriteReady(msg.reqId, null))
        } catch (e: Throwable) {
            Log.w(TAG, "open write failed", e)
            reply(WireMessage.FsWriteReady(msg.reqId, e.message ?: "error"))
        }
    }

    private fun handleWriteChunk(msg: WireMessage.FsChunk) {
        // Legacy WS fallback: decode base64 and reuse the binary path.
        val bytes = try { Base64.decode(msg.data, Base64.DEFAULT) } catch (_: Throwable) {
            ByteArray(0)
        }
        onWriteBytes(msg.reqId, msg.offset, bytes, msg.last)
    }

    /** Entry point for `kind=fs` chunks (Mac → phone writes). Bypasses
     *  base64 entirely. */
    fun onWriteBytes(reqId: String, offset: Long, bytes: ByteArray, last: Boolean) {
        val state = activeWrites[reqId] ?: return
        try {
            if (bytes.isNotEmpty()) {
                state.out.write(bytes)
                state.bytesWritten += bytes.size
            }
            if (last) {
                state.out.flush()
                state.out.close()
                activeWrites.remove(reqId)
                RadioKeepAlive.end()
                MirrorCore.endFileTransfer()
                reply(WireMessage.FsOpResult(reqId, true, null))
            }
            @Suppress("UNUSED_PARAMETER") val _unused = offset
        } catch (e: Throwable) {
            Log.w(TAG, "write chunk failed", e)
            try { state.out.close() } catch (_: Throwable) {}
            activeWrites.remove(reqId)
            RadioKeepAlive.end()
            MirrorCore.endFileTransfer()
            try { File(state.path).delete() } catch (_: Throwable) {}
            reply(WireMessage.FsOpResult(reqId, false, e.message ?: "error"))
        }
    }

    // ---------- Helpers ----------

    private fun reply(message: WireMessage) {
        MirrorCore.dispatch(message)
    }

    companion object {
        private const val TAG = "FileBrowseBridge"
        /** Same as FileBridge: ~256 KiB base64 → ~340 KiB JSON, well under 8 MiB cap. */
        // 16 KiB chunks: on Android 16 + our macOS NWConnection listener we
        // observed ~28 s stalls after ~5 × 64 KiB frames (classic TCP
        // zero-window probe backoff, ~1+2+4+8+16 = 31 s). With 16 KiB
        // frames the Mac side's receive callback fires ~4× more often, so
        // the kernel receive buffer drains steadily and rwnd stays open.
        private const val CHUNK_SIZE = 16 * 1024
    }
}
