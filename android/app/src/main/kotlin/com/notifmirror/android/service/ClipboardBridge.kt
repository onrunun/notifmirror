package com.notifmirror.android.service

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.util.Log

/**
 * Android ↔ Mac clipboard bridge.
 *
 * Outbound direction (Android → Mac) is driven by the user invoking the
 * share sheet or the Quick-Settings tile — we never try to read the clipboard
 * unsolicited, because Android 10+ blocks background reads.
 *
 * Inbound direction (Mac → Android) writes to the primary clip here.
 */
class ClipboardBridge(private val context: Context) {

    private val cm: ClipboardManager =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    fun handleRemoteClip(text: String) {
        if (text.toByteArray(Charsets.UTF_8).size > TEXT_CAP) return
        try {
            cm.setPrimaryClip(ClipData.newPlainText("NotifMirror", text))
        } catch (e: Throwable) {
            Log.w(TAG, "setPrimaryClip failed", e)
        }
    }

    companion object {
        private const val TAG = "ClipboardBridge"
        private const val TEXT_CAP = 64 * 1024
    }
}
