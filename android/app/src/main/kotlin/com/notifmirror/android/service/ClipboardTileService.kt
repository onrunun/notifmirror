package com.notifmirror.android.service

import android.content.ClipboardManager
import android.content.Context
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast
import com.notifmirror.android.protocol.WireMessage

/**
 * Quick-Settings tile. Tapping it reads the current clipboard (tile service
 * is considered "in focus" long enough for the read) and pushes it to the Mac.
 *
 * This is the reliable path when the Accessibility route won't bind on a
 * given device.
 */
class ClipboardTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        qsTile?.apply {
            state = Tile.STATE_ACTIVE
            label = "Send clipboard"
            updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        val clip = cm?.primaryClip
        val text = if (clip != null && clip.itemCount > 0) {
            clip.getItemAt(0)?.coerceToText(this)?.toString()
        } else null

        if (text.isNullOrEmpty()) {
            showToast("Clipboard is empty")
            return
        }

        MirrorCore.dispatch(
            WireMessage.Clip(text = text, origin = "android", seq = 0)
        )
        showToast("Sent to Mac")
    }

    private fun showToast(msg: String) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
    }
}
