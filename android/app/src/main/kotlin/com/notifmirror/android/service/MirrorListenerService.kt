package com.notifmirror.android.service

import android.app.Notification
import android.app.NotificationManager
import android.app.RemoteInput
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.NotificationListenerService.RankingMap
import android.service.notification.StatusBarNotification
import android.util.Log
import com.notifmirror.android.data.BlockedApps
import com.notifmirror.android.data.Settings
import com.notifmirror.android.protocol.WireMessage

/**
 * Hosts the mirror runtime. The system keeps us bound whenever the user
 * has granted notification access, so [MirrorCore] inherits that lifetime
 * without needing a separate foreground service — the app no longer shows
 * up as "active" in the system Active Apps panel.
 */
class MirrorListenerService : NotificationListenerService() {

    private var core: MirrorCore? = null

    // key → "title\0text" fingerprint of the last sent payload.
    // Prevents Android's re-ranking callbacks from sending duplicate posted
    // messages for the same notification content.
    private val sentFingerprints = HashMap<String, String>()

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "listener connected")
        instance = this
        if (core == null) {
            core = MirrorCore(this).also { it.start() }
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        Log.i(TAG, "listener disconnected")
        if (instance === this) instance = null
        sentFingerprints.clear()
        core?.stop()
        core = null
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance === this) instance = null
        sentFingerprints.clear()
        core?.stop()
        core = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification, rankingMap: RankingMap) {
        if (!NotificationExtractor.shouldMirror(sbn)) return
        try {
            val isSilent = computeSilent(sbn, rankingMap)
            if (isSilent && Settings.get(this).skipSilent) {
                Log.i(TAG, "silent notification skipped (user pref): ${sbn.packageName}")
                return
            }
            // Deduplicate: Android calls onNotificationPosted again when it
            // re-ranks a notification's importance. Skip if title+text haven't
            // changed since we last sent this key — prevents double banners on
            // Mac and stops silent notifications leaking through as non-silent
            // on the second re-ranking callback.
            val extras = sbn.notification.extras
            val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
            val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
                ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
            val fingerprint = "$title\u0000$text"
            if (sentFingerprints[sbn.key] == fingerprint) {
                Log.d(TAG, "duplicate notification skipped: ${sbn.packageName}")
                return
            }
            sentFingerprints[sbn.key] = fingerprint

            val payload = NotificationExtractor.extract(this, sbn, isSilent = isSilent)
            val blocked = BlockedApps.get(this).recordAndCheck(payload.pkg, payload.app)
            if (blocked) {
                Log.i(TAG, "blocked pkg, not mirroring: ${payload.pkg}")
                return
            }
            MirrorCore.dispatch(payload)
        } catch (e: Throwable) {
            Log.w(TAG, "extract/send failed", e)
        }
    }

    private fun computeSilent(sbn: StatusBarNotification, rankingMap: RankingMap): Boolean {
        val ranking = Ranking()
        if (rankingMap.getRanking(sbn.key, ranking)) {
            return ranking.importance < NotificationManager.IMPORTANCE_DEFAULT
        }
        return false
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        sentFingerprints.remove(sbn.key)
        MirrorCore.dispatch(WireMessage.Removed(sbn.key))
    }

    fun dismissByKey(key: String) {
        try {
            cancelNotification(key)
        } catch (e: Throwable) {
            Log.w(TAG, "cancel failed", e)
        }
    }

    fun replyByKey(key: String, actionId: String, text: String?) {
        try {
            val sbn = activeNotifications?.firstOrNull { it.key == key } ?: run {
                Log.w(TAG, "reply: notification not active key=$key"); return
            }
            val actionIndex = actionId.toIntOrNull() ?: run {
                Log.w(TAG, "reply: bad actionId=$actionId"); return
            }
            val action: Notification.Action = sbn.notification.actions?.getOrNull(actionIndex) ?: run {
                Log.w(TAG, "reply: action index OOB"); return
            }

            if (text != null) {
                val remoteInput = action.remoteInputs?.firstOrNull { it.allowFreeFormInput } ?: run {
                    Log.w(TAG, "reply: no free-form remote input"); return
                }
                val fillIn = Intent()
                val bundle = Bundle().apply { putCharSequence(remoteInput.resultKey, text) }
                RemoteInput.addResultsToIntent(arrayOf(remoteInput), fillIn, bundle)
                if (Build.VERSION.SDK_INT >= 28) {
                    RemoteInput.setResultsSource(fillIn, RemoteInput.SOURCE_FREE_FORM_INPUT)
                }
                action.actionIntent.send(this, 0, fillIn)
            } else {
                action.actionIntent.send()
            }
        } catch (e: Throwable) {
            Log.w(TAG, "reply failed", e)
        }
    }

    companion object {
        private const val TAG = "MirrorListener"

        @Volatile
        private var instance: MirrorListenerService? = null

        fun current(): MirrorListenerService? = instance
    }
}
