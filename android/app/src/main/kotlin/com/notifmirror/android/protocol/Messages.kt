package com.notifmirror.android.protocol

import org.json.JSONArray
import org.json.JSONObject

const val PROTO_VERSION = 2
const val MIN_ACCEPTED_PROTO = 1

data class ActionDescriptor(val id: String, val title: String, val isReply: Boolean)

sealed class WireMessage {
    data class Hello(
        val secret: String,
        val deviceName: String,
        val proto: Int,
        val features: List<String> = emptyList()
    ) : WireMessage()

    data class HelloAck(
        val accepted: Boolean,
        val serverName: String,
        val features: List<String> = emptyList(),
        val dataPort: Int = 0
    ) : WireMessage()

    data class Posted(
        val key: String,
        val pkg: String,
        val app: String,
        val title: String?,
        val text: String?,
        val subText: String?,
        val appIcon: String?,
        val largeIcon: String?,
        val picture: String?,
        val postTime: Long,
        val silent: Boolean,
        val actions: List<ActionDescriptor>
    ) : WireMessage()

    data class Removed(val key: String) : WireMessage()
    data class Dismiss(val key: String) : WireMessage()
    data class Action(val key: String, val actionId: String, val text: String?) : WireMessage()

    data class Clip(val text: String, val origin: String, val seq: Int) : WireMessage()

    data class MediaState(
        val pkg: String?,
        val app: String?,
        val title: String?,
        val artist: String?,
        val album: String?,
        val artwork: String?,
        val playing: Boolean,
        val positionMs: Long,
        val durationMs: Long,
        val canPause: Boolean,
        val canSkipNext: Boolean,
        val canSkipPrev: Boolean,
        val volume: Int,
        val maxVolume: Int,
        val updatedAt: Long
    ) : WireMessage()

    data class MediaCmd(val cmd: String, val value: Int? = null) : WireMessage()

    /** Phone → Mac battery snapshot. Pushed on connect, on charge-state
     *  transitions, on low/okay events, and on each ≥1 % level change. */
    data class BatteryState(
        val level: Int,
        val charging: Boolean,
        val status: String,
        val plugged: String,
        val temperatureC: Double?,
        val voltageMv: Int?,
        val low: Boolean,
        val updatedAt: Long
    ) : WireMessage()

    data class FileOffer(
        val xid: String,
        val name: String,
        val size: Long,
        val mime: String?,
        val sha256: String?
    ) : WireMessage()

    data class FileAccept(val xid: String) : WireMessage()
    data class FileReject(val xid: String, val reason: String) : WireMessage()
    data class FileChunk(val xid: String, val offset: Long, val data: String, val last: Boolean) : WireMessage()
    data class FileDone(val xid: String) : WireMessage()
    data class FileAck(val xid: String, val ok: Boolean, val error: String?) : WireMessage()
    data class FileCancel(val xid: String, val reason: String) : WireMessage()

    // Phone file browse. Request/response correlated via `reqId`. Read and
    // write stream body bytes through `FsChunk`.
    data class FsEntry(val name: String, val kind: String, val size: Long, val mtime: Long)

    data class FsList(val reqId: String, val path: String) : WireMessage()
    data class FsListResult(
        val reqId: String,
        val path: String,
        val entries: List<FsEntry>,
        val error: String?
    ) : WireMessage()

    data class FsDelete(val reqId: String, val path: String) : WireMessage()
    data class FsMkdir(val reqId: String, val path: String) : WireMessage()
    data class FsRename(val reqId: String, val from: String, val to: String) : WireMessage()
    data class FsOpResult(val reqId: String, val ok: Boolean, val error: String?) : WireMessage()

    data class FsDisk(val reqId: String, val path: String) : WireMessage()
    data class FsDiskResult(
        val reqId: String,
        val free: Long,
        val total: Long,
        val error: String?
    ) : WireMessage()

    /** One immediate child of an `fs_du` request's path. `totalSize` is
     *  recursive for directories, equal to file size for files. */
    data class FsDuEntry(
        val name: String,
        val kind: String,
        val totalSize: Long,
        val fileCount: Long
    )

    data class FsDu(val reqId: String, val path: String) : WireMessage()
    data class FsDuResult(
        val reqId: String,
        val path: String,
        val totalSize: Long,
        val entries: List<FsDuEntry>,
        val error: String?
    ) : WireMessage()

    data class FsRead(val reqId: String, val path: String) : WireMessage()
    data class FsReadResult(val reqId: String, val size: Long, val error: String?) : WireMessage()

    data class FsWrite(val reqId: String, val path: String, val size: Long) : WireMessage()
    data class FsWriteReady(val reqId: String, val error: String?) : WireMessage()

    data class FsChunk(
        val reqId: String,
        val offset: Long,
        val data: String,
        val last: Boolean
    ) : WireMessage()

    data class FsCancel(val reqId: String, val reason: String) : WireMessage()

    /** Mac → phone end-to-end notification test. The phone must post a real
     *  notification from this app's package (NotificationListener will then
     *  catch it and mirror back), with `reqId` embedded in the body so the
     *  Mac can correlate the round-trip. */
    data class TestRequest(val reqId: String) : WireMessage()

    object Ping : WireMessage()
    object Pong : WireMessage()
    data class Error(val code: String, val msg: String) : WireMessage()

    /** Received a valid JSON frame with an unknown `t` value — callers should ignore. */
    data class Unknown(val type: String) : WireMessage()
}

object WireCodec {
    fun encode(message: WireMessage): String {
        val obj = JSONObject()
        obj.put("v", PROTO_VERSION)
        when (message) {
            is WireMessage.Hello -> {
                obj.put("t", "hello")
                obj.put("secret", message.secret)
                obj.put("deviceName", message.deviceName)
                obj.put("proto", message.proto)
                if (message.features.isNotEmpty()) {
                    obj.put("features", JSONArray(message.features))
                }
            }
            is WireMessage.HelloAck -> {
                obj.put("t", "hello_ack")
                obj.put("accepted", message.accepted)
                obj.put("serverName", message.serverName)
                if (message.features.isNotEmpty()) {
                    obj.put("features", JSONArray(message.features))
                }
                if (message.dataPort > 0) obj.put("dataPort", message.dataPort)
            }
            is WireMessage.Posted -> {
                obj.put("t", "posted")
                obj.put("key", message.key)
                obj.put("pkg", message.pkg)
                obj.put("app", message.app)
                obj.put("title", message.title ?: JSONObject.NULL)
                obj.put("text", message.text ?: JSONObject.NULL)
                obj.put("subText", message.subText ?: JSONObject.NULL)
                obj.put("appIcon", message.appIcon ?: JSONObject.NULL)
                obj.put("largeIcon", message.largeIcon ?: JSONObject.NULL)
                obj.put("picture", message.picture ?: JSONObject.NULL)
                obj.put("postTime", message.postTime)
                obj.put("silent", message.silent)
                val arr = JSONArray()
                message.actions.forEach { a ->
                    val ao = JSONObject()
                    ao.put("id", a.id)
                    ao.put("title", a.title)
                    ao.put("isReply", a.isReply)
                    arr.put(ao)
                }
                obj.put("actions", arr)
            }
            is WireMessage.Removed -> {
                obj.put("t", "removed"); obj.put("key", message.key)
            }
            is WireMessage.Dismiss -> {
                obj.put("t", "dismiss"); obj.put("key", message.key)
            }
            is WireMessage.Action -> {
                obj.put("t", "action")
                obj.put("key", message.key)
                obj.put("actionId", message.actionId)
                if (message.text != null) obj.put("text", message.text)
            }
            is WireMessage.Clip -> {
                obj.put("t", "clip")
                obj.put("text", message.text)
                obj.put("origin", message.origin)
                obj.put("seq", message.seq)
            }
            is WireMessage.MediaState -> {
                obj.put("t", "media_state")
                obj.put("pkg", message.pkg ?: JSONObject.NULL)
                obj.put("app", message.app ?: JSONObject.NULL)
                obj.put("title", message.title ?: JSONObject.NULL)
                obj.put("artist", message.artist ?: JSONObject.NULL)
                obj.put("album", message.album ?: JSONObject.NULL)
                obj.put("artwork", message.artwork ?: JSONObject.NULL)
                obj.put("playing", message.playing)
                obj.put("positionMs", message.positionMs)
                obj.put("durationMs", message.durationMs)
                obj.put("canPause", message.canPause)
                obj.put("canSkipNext", message.canSkipNext)
                obj.put("canSkipPrev", message.canSkipPrev)
                obj.put("volume", message.volume)
                obj.put("maxVolume", message.maxVolume)
                obj.put("updatedAt", message.updatedAt)
            }
            is WireMessage.MediaCmd -> {
                obj.put("t", "media_cmd"); obj.put("cmd", message.cmd)
                if (message.value != null) obj.put("value", message.value)
            }
            is WireMessage.BatteryState -> {
                obj.put("t", "battery_state")
                obj.put("level", message.level)
                obj.put("charging", message.charging)
                obj.put("status", message.status)
                obj.put("plugged", message.plugged)
                obj.put("temperatureC", message.temperatureC ?: JSONObject.NULL)
                obj.put("voltageMv", message.voltageMv ?: JSONObject.NULL)
                obj.put("low", message.low)
                obj.put("updatedAt", message.updatedAt)
            }
            is WireMessage.FileOffer -> {
                obj.put("t", "file_offer")
                obj.put("xid", message.xid)
                obj.put("name", message.name)
                obj.put("size", message.size)
                if (message.mime != null) obj.put("mime", message.mime)
                if (message.sha256 != null) obj.put("sha256", message.sha256)
            }
            is WireMessage.FileAccept -> {
                obj.put("t", "file_accept"); obj.put("xid", message.xid)
            }
            is WireMessage.FileReject -> {
                obj.put("t", "file_reject"); obj.put("xid", message.xid); obj.put("reason", message.reason)
            }
            is WireMessage.FileChunk -> {
                obj.put("t", "file_chunk")
                obj.put("xid", message.xid)
                obj.put("offset", message.offset)
                obj.put("data", message.data)
                obj.put("last", message.last)
            }
            is WireMessage.FileDone -> {
                obj.put("t", "file_done"); obj.put("xid", message.xid)
            }
            is WireMessage.FileAck -> {
                obj.put("t", "file_ack"); obj.put("xid", message.xid); obj.put("ok", message.ok)
                if (message.error != null) obj.put("error", message.error)
            }
            is WireMessage.FileCancel -> {
                obj.put("t", "file_cancel"); obj.put("xid", message.xid); obj.put("reason", message.reason)
            }
            is WireMessage.FsList -> {
                obj.put("t", "fs_list"); obj.put("reqId", message.reqId); obj.put("path", message.path)
            }
            is WireMessage.FsListResult -> {
                obj.put("t", "fs_list_result")
                obj.put("reqId", message.reqId)
                obj.put("path", message.path)
                val arr = JSONArray()
                message.entries.forEach { e ->
                    val eo = JSONObject()
                    eo.put("name", e.name)
                    eo.put("kind", e.kind)
                    eo.put("size", e.size)
                    eo.put("mtime", e.mtime)
                    arr.put(eo)
                }
                obj.put("entries", arr)
                if (message.error != null) obj.put("error", message.error)
            }
            is WireMessage.FsDelete -> {
                obj.put("t", "fs_delete"); obj.put("reqId", message.reqId); obj.put("path", message.path)
            }
            is WireMessage.FsMkdir -> {
                obj.put("t", "fs_mkdir"); obj.put("reqId", message.reqId); obj.put("path", message.path)
            }
            is WireMessage.FsRename -> {
                obj.put("t", "fs_rename")
                obj.put("reqId", message.reqId)
                obj.put("from", message.from); obj.put("to", message.to)
            }
            is WireMessage.FsOpResult -> {
                obj.put("t", "fs_op_result")
                obj.put("reqId", message.reqId); obj.put("ok", message.ok)
                if (message.error != null) obj.put("error", message.error)
            }
            is WireMessage.FsDisk -> {
                obj.put("t", "fs_disk"); obj.put("reqId", message.reqId); obj.put("path", message.path)
            }
            is WireMessage.FsDiskResult -> {
                obj.put("t", "fs_disk_result")
                obj.put("reqId", message.reqId)
                obj.put("free", message.free); obj.put("total", message.total)
                if (message.error != null) obj.put("error", message.error)
            }
            is WireMessage.FsDu -> {
                obj.put("t", "fs_du"); obj.put("reqId", message.reqId); obj.put("path", message.path)
            }
            is WireMessage.FsDuResult -> {
                obj.put("t", "fs_du_result")
                obj.put("reqId", message.reqId)
                obj.put("path", message.path)
                obj.put("totalSize", message.totalSize)
                val arr = JSONArray()
                message.entries.forEach { e ->
                    val eo = JSONObject()
                    eo.put("name", e.name)
                    eo.put("kind", e.kind)
                    eo.put("totalSize", e.totalSize)
                    eo.put("fileCount", e.fileCount)
                    arr.put(eo)
                }
                obj.put("entries", arr)
                if (message.error != null) obj.put("error", message.error)
            }
            is WireMessage.FsRead -> {
                obj.put("t", "fs_read"); obj.put("reqId", message.reqId); obj.put("path", message.path)
            }
            is WireMessage.FsReadResult -> {
                obj.put("t", "fs_read_result")
                obj.put("reqId", message.reqId); obj.put("size", message.size)
                if (message.error != null) obj.put("error", message.error)
            }
            is WireMessage.FsWrite -> {
                obj.put("t", "fs_write")
                obj.put("reqId", message.reqId); obj.put("path", message.path); obj.put("size", message.size)
            }
            is WireMessage.FsWriteReady -> {
                obj.put("t", "fs_write_ready"); obj.put("reqId", message.reqId)
                if (message.error != null) obj.put("error", message.error)
            }
            is WireMessage.FsChunk -> {
                obj.put("t", "fs_chunk")
                obj.put("reqId", message.reqId)
                obj.put("offset", message.offset)
                obj.put("data", message.data)
                obj.put("last", message.last)
            }
            is WireMessage.FsCancel -> {
                obj.put("t", "fs_cancel")
                obj.put("reqId", message.reqId)
                obj.put("reason", message.reason)
            }
            is WireMessage.TestRequest -> {
                obj.put("t", "test_request"); obj.put("reqId", message.reqId)
            }
            WireMessage.Ping -> obj.put("t", "ping")
            WireMessage.Pong -> obj.put("t", "pong")
            is WireMessage.Error -> {
                obj.put("t", "error"); obj.put("code", message.code); obj.put("msg", message.msg)
            }
            is WireMessage.Unknown -> throw IllegalArgumentException("Unknown is not encodable")
        }
        return obj.toString()
    }

    fun decode(text: String): WireMessage {
        val obj = JSONObject(text)
        val t = obj.optString("t")
        return when (t) {
            "hello" -> WireMessage.Hello(
                secret = obj.getString("secret"),
                deviceName = obj.getString("deviceName"),
                proto = obj.getInt("proto"),
                features = obj.optJSONArray("features").toStringListOrEmpty()
            )
            "hello_ack" -> WireMessage.HelloAck(
                accepted = obj.optBoolean("accepted"),
                serverName = obj.optString("serverName"),
                features = obj.optJSONArray("features").toStringListOrEmpty(),
                dataPort = obj.optInt("dataPort", 0)
            )
            "removed" -> WireMessage.Removed(obj.getString("key"))
            "dismiss" -> WireMessage.Dismiss(obj.getString("key"))
            "action" -> WireMessage.Action(
                key = obj.getString("key"),
                actionId = obj.getString("actionId"),
                text = if (obj.has("text") && !obj.isNull("text")) obj.getString("text") else null
            )
            "clip" -> WireMessage.Clip(
                text = obj.getString("text"),
                origin = obj.optString("origin", "unknown"),
                seq = obj.optInt("seq", 0)
            )
            "media_state" -> WireMessage.MediaState(
                pkg = obj.optStringOrNull("pkg"),
                app = obj.optStringOrNull("app"),
                title = obj.optStringOrNull("title"),
                artist = obj.optStringOrNull("artist"),
                album = obj.optStringOrNull("album"),
                artwork = obj.optStringOrNull("artwork"),
                playing = obj.optBoolean("playing"),
                positionMs = obj.optLong("positionMs"),
                durationMs = obj.optLong("durationMs"),
                canPause = obj.optBoolean("canPause"),
                canSkipNext = obj.optBoolean("canSkipNext"),
                canSkipPrev = obj.optBoolean("canSkipPrev"),
                volume = obj.optInt("volume", 0),
                maxVolume = obj.optInt("maxVolume", 0),
                updatedAt = obj.optLong("updatedAt")
            )
            "media_cmd" -> WireMessage.MediaCmd(
                cmd = obj.getString("cmd"),
                value = if (obj.has("value") && !obj.isNull("value")) obj.optInt("value") else null
            )
            "battery_state" -> WireMessage.BatteryState(
                level = obj.optInt("level", -1),
                charging = obj.optBoolean("charging"),
                status = obj.optString("status", "unknown"),
                plugged = obj.optString("plugged", "unknown"),
                temperatureC = if (obj.has("temperatureC") && !obj.isNull("temperatureC"))
                    obj.optDouble("temperatureC") else null,
                voltageMv = if (obj.has("voltageMv") && !obj.isNull("voltageMv"))
                    obj.optInt("voltageMv") else null,
                low = obj.optBoolean("low"),
                updatedAt = obj.optLong("updatedAt")
            )
            "file_offer" -> WireMessage.FileOffer(
                xid = obj.getString("xid"),
                name = obj.getString("name"),
                size = obj.optLong("size"),
                mime = obj.optStringOrNull("mime"),
                sha256 = obj.optStringOrNull("sha256")
            )
            "file_accept" -> WireMessage.FileAccept(obj.getString("xid"))
            "file_reject" -> WireMessage.FileReject(
                xid = obj.getString("xid"),
                reason = obj.optString("reason", "unknown")
            )
            "file_chunk" -> WireMessage.FileChunk(
                xid = obj.getString("xid"),
                offset = obj.optLong("offset"),
                data = obj.getString("data"),
                last = obj.optBoolean("last")
            )
            "file_done" -> WireMessage.FileDone(obj.getString("xid"))
            "file_ack" -> WireMessage.FileAck(
                xid = obj.getString("xid"),
                ok = obj.optBoolean("ok"),
                error = obj.optStringOrNull("error")
            )
            "file_cancel" -> WireMessage.FileCancel(
                xid = obj.getString("xid"),
                reason = obj.optString("reason", "unknown")
            )
            "fs_list" -> WireMessage.FsList(
                reqId = obj.getString("reqId"),
                path = obj.getString("path")
            )
            "fs_list_result" -> {
                val arr = obj.optJSONArray("entries")
                val entries = ArrayList<WireMessage.FsEntry>(arr?.length() ?: 0)
                if (arr != null) for (i in 0 until arr.length()) {
                    val e = arr.getJSONObject(i)
                    entries.add(
                        WireMessage.FsEntry(
                            name = e.getString("name"),
                            kind = e.getString("kind"),
                            size = e.optLong("size"),
                            mtime = e.optLong("mtime")
                        )
                    )
                }
                WireMessage.FsListResult(
                    reqId = obj.getString("reqId"),
                    path = obj.getString("path"),
                    entries = entries,
                    error = obj.optStringOrNull("error")
                )
            }
            "fs_delete" -> WireMessage.FsDelete(
                reqId = obj.getString("reqId"), path = obj.getString("path")
            )
            "fs_mkdir" -> WireMessage.FsMkdir(
                reqId = obj.getString("reqId"), path = obj.getString("path")
            )
            "fs_rename" -> WireMessage.FsRename(
                reqId = obj.getString("reqId"),
                from = obj.getString("from"),
                to = obj.getString("to")
            )
            "fs_op_result" -> WireMessage.FsOpResult(
                reqId = obj.getString("reqId"),
                ok = obj.optBoolean("ok"),
                error = obj.optStringOrNull("error")
            )
            "fs_disk" -> WireMessage.FsDisk(
                reqId = obj.getString("reqId"), path = obj.getString("path")
            )
            "fs_disk_result" -> WireMessage.FsDiskResult(
                reqId = obj.getString("reqId"),
                free = obj.optLong("free"),
                total = obj.optLong("total"),
                error = obj.optStringOrNull("error")
            )
            "fs_du" -> WireMessage.FsDu(
                reqId = obj.getString("reqId"), path = obj.getString("path")
            )
            "fs_du_result" -> {
                val arr = obj.optJSONArray("entries")
                val entries = ArrayList<WireMessage.FsDuEntry>(arr?.length() ?: 0)
                if (arr != null) for (i in 0 until arr.length()) {
                    val e = arr.getJSONObject(i)
                    entries.add(
                        WireMessage.FsDuEntry(
                            name = e.getString("name"),
                            kind = e.getString("kind"),
                            totalSize = e.optLong("totalSize"),
                            fileCount = e.optLong("fileCount")
                        )
                    )
                }
                WireMessage.FsDuResult(
                    reqId = obj.getString("reqId"),
                    path = obj.getString("path"),
                    totalSize = obj.optLong("totalSize"),
                    entries = entries,
                    error = obj.optStringOrNull("error")
                )
            }
            "fs_read" -> WireMessage.FsRead(
                reqId = obj.getString("reqId"), path = obj.getString("path")
            )
            "fs_read_result" -> WireMessage.FsReadResult(
                reqId = obj.getString("reqId"),
                size = obj.optLong("size"),
                error = obj.optStringOrNull("error")
            )
            "fs_write" -> WireMessage.FsWrite(
                reqId = obj.getString("reqId"),
                path = obj.getString("path"),
                size = obj.optLong("size")
            )
            "fs_write_ready" -> WireMessage.FsWriteReady(
                reqId = obj.getString("reqId"),
                error = obj.optStringOrNull("error")
            )
            "fs_chunk" -> WireMessage.FsChunk(
                reqId = obj.getString("reqId"),
                offset = obj.optLong("offset"),
                data = obj.getString("data"),
                last = obj.optBoolean("last")
            )
            "fs_cancel" -> WireMessage.FsCancel(
                reqId = obj.getString("reqId"),
                reason = obj.optString("reason", "abandoned")
            )
            "test_request" -> WireMessage.TestRequest(reqId = obj.getString("reqId"))
            "ping" -> WireMessage.Ping
            "pong" -> WireMessage.Pong
            "error" -> WireMessage.Error(
                code = obj.optString("code"),
                msg = obj.optString("msg")
            )
            else -> WireMessage.Unknown(t)
        }
    }
}

private fun JSONArray?.toStringListOrEmpty(): List<String> {
    if (this == null) return emptyList()
    val out = ArrayList<String>(length())
    for (i in 0 until length()) out.add(optString(i))
    return out
}

private fun JSONObject.optStringOrNull(key: String): String? =
    if (!has(key) || isNull(key)) null else optString(key)
