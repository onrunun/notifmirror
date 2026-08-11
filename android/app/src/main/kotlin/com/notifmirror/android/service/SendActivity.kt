package com.notifmirror.android.service

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Log
import android.widget.Toast

/**
 * Transparent receiver for share intents. Takes the first item from the
 * incoming ACTION_SEND / ACTION_SEND_MULTIPLE payload, hands it to the
 * [FileBridge] running inside the foreground service, and finishes.
 *
 * No UI — the toast is our sole acknowledgement. Progress shows in the Mac
 * menu bar; a future polish step could surface a notification on Android too.
 */
class SendActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val intent = intent

        // Shared plain text → push as a clip message.
        val sharedText = if (intent?.action == Intent.ACTION_SEND) {
            intent.getStringExtra(Intent.EXTRA_TEXT)
        } else null
        if (!sharedText.isNullOrEmpty()) {
            MirrorCore.dispatch(
                com.notifmirror.android.protocol.WireMessage.Clip(
                    text = sharedText, origin = "android", seq = 0
                )
            )
            toast("Sent text to Mac")
            finish(); return
        }

        val uris: List<Uri> = when (intent?.action) {
            Intent.ACTION_SEND -> {
                val u: Uri? = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
                }
                listOfNotNull(u)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) ?: emptyList()
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
                }
            }
            else -> emptyList()
        }

        if (uris.isEmpty()) {
            toast("NotifMirror: nothing to send")
            finish(); return
        }

        // Grant the foreground service access to each URI for the duration
        // of its process.
        uris.forEach {
            try {
                contentResolver.takePersistableUriPermission(
                    it, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Throwable) { /* many URIs don't allow persisting */ }
        }

        val bridge = MirrorCore.fileBridge()
        if (bridge == null) {
            toast("NotifMirror: service not running")
            finish(); return
        }

        var sent = 0
        for (uri in uris) {
            val meta = queryMeta(uri)
            try {
                bridge.sendFile(uri, meta.name, meta.size)
                sent++
            } catch (e: Throwable) {
                Log.w("SendActivity", "sendFile failed for $uri", e)
            }
        }

        toast(if (sent > 0) "Sending $sent file${if (sent > 1) "s" else ""} to Mac" else "NotifMirror: failed")
        finish()
    }

    private data class Meta(val name: String, val size: Long)

    private fun queryMeta(uri: Uri): Meta {
        var name = uri.lastPathSegment ?: "file"
        var size = 0L
        try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val si = c.getColumnIndex(OpenableColumns.SIZE)
                    if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                }
            }
        } catch (_: Throwable) {}
        return Meta(name, size)
    }

    private fun toast(msg: String) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
    }
}
