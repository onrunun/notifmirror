package com.notifmirror.android.service

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import com.notifmirror.android.protocol.WireMessage
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Reads the active media session via MediaSessionManager (allowed because we
 * already hold a NotificationListener binding — same permission gate) and
 * forwards state to the Mac. Transport commands (`play`/`pause`/…) arrive via
 * [handleCommand] and are routed to the matching MediaController.
 *
 * State updates are throttled to one per 500 ms so seek-scrub doesn't flood
 * the socket.
 *
 * The latest snapshot is also published on [state] so the app's own UI can
 * render a now-playing card, and transport commands can be issued locally
 * through [current].
 */
class MediaBridge(private val context: Context) {

    private val mgr: MediaSessionManager =
        context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
    private val audio: AudioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private val listenerComponent = ComponentName(context, MirrorListenerService::class.java)

    private var controllers: List<MediaController> = emptyList()
    private val controllerCallbacks = mutableMapOf<MediaController, MediaController.Callback>()

    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingPublish = false
    private var lastPublishedAt = 0L

    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { list ->
        try { rebind(list ?: emptyList()) } catch (e: Throwable) { Log.w(TAG, "rebind failed", e) }
    }

    fun start() {
        try {
            instance = this
            mgr.addOnActiveSessionsChangedListener(sessionsListener, listenerComponent)
            rebind(mgr.getActiveSessions(listenerComponent))
        } catch (e: SecurityException) {
            Log.w(TAG, "no notification-listener access yet for media; will pick up later", e)
        }
    }

    fun stop() {
        if (instance === this) instance = null
        try { mgr.removeOnActiveSessionsChangedListener(sessionsListener) } catch (_: Throwable) {}
        controllerCallbacks.forEach { (c, cb) -> try { c.unregisterCallback(cb) } catch (_: Throwable) {} }
        controllerCallbacks.clear()
        controllers = emptyList()
    }

    fun handleCommand(cmd: String, value: Int? = null) {
        // Volume commands are handled via AudioManager, not the session —
        // they work even if no media session is active.
        when (cmd) {
            "vol_up" -> {
                audio.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, 0
                )
                mainHandler.postDelayed({ publishNow() }, 100); return
            }
            "vol_down" -> {
                audio.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, 0
                )
                mainHandler.postDelayed({ publishNow() }, 100); return
            }
            "vol_set" -> {
                val target = (value ?: return).coerceIn(0, audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC))
                audio.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
                mainHandler.postDelayed({ publishNow() }, 100); return
            }
        }

        val c = primary() ?: run { publishNow(); return }
        val t = c.transportControls
        when (cmd) {
            "play" -> t.play()
            "pause" -> t.pause()
            "toggle" -> if (isPlaying(c)) t.pause() else t.play()
            "next" -> t.skipToNext()
            "prev" -> t.skipToPrevious()
            "refresh" -> publishNow()
            else -> Log.w(TAG, "unknown media cmd: $cmd")
        }
        // Give the player a beat to apply the command, then resend state.
        mainHandler.postDelayed({ publishNow() }, 250)
    }

    fun publishIfConnected() { publishNow() }

    private fun rebind(list: List<MediaController>) {
        controllerCallbacks.forEach { (c, cb) -> try { c.unregisterCallback(cb) } catch (_: Throwable) {} }
        controllerCallbacks.clear()
        controllers = list

        list.forEach { c ->
            val cb = object : MediaController.Callback() {
                override fun onPlaybackStateChanged(state: PlaybackState?) { schedulePublish() }
                override fun onMetadataChanged(metadata: MediaMetadata?) { schedulePublish() }
                override fun onSessionDestroyed() { schedulePublish() }
            }
            try {
                c.registerCallback(cb, mainHandler)
                controllerCallbacks[c] = cb
            } catch (e: Throwable) { Log.w(TAG, "registerCallback failed", e) }
        }
        schedulePublish()
    }

    private fun schedulePublish() {
        if (pendingPublish) return
        val now = System.currentTimeMillis()
        val wait = (500L - (now - lastPublishedAt)).coerceAtLeast(0L)
        pendingPublish = true
        mainHandler.postDelayed({
            pendingPublish = false
            publishNow()
        }, wait)
    }

    private fun publishNow() {
        val volume = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        val maxVolume = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val c = primary()
        val msg = if (c == null) {
            WireMessage.MediaState(
                pkg = null, app = null, title = null, artist = null, album = null,
                artwork = null, playing = false,
                positionMs = 0, durationMs = 0,
                canPause = false, canSkipNext = false, canSkipPrev = false,
                volume = volume, maxVolume = maxVolume,
                updatedAt = System.currentTimeMillis()
            )
        } else {
            snapshot(c, volume, maxVolume)
        }
        lastPublishedAt = System.currentTimeMillis()
        _state.value = msg
        MirrorCore.dispatch(msg)
    }

    private fun primary(): MediaController? {
        // Prefer the one that's actually playing; otherwise the first.
        val playing = controllers.firstOrNull { isPlaying(it) }
        return playing ?: controllers.firstOrNull()
    }

    private fun isPlaying(c: MediaController): Boolean {
        val s = c.playbackState ?: return false
        return s.state == PlaybackState.STATE_PLAYING
    }

    private fun snapshot(c: MediaController, volume: Int, maxVolume: Int): WireMessage.MediaState {
        val md = c.metadata
        val ps = c.playbackState
        val actions = ps?.actions ?: 0L
        val canPause = (actions and PlaybackState.ACTION_PAUSE) != 0L ||
            (actions and PlaybackState.ACTION_PLAY_PAUSE) != 0L
        val canNext = (actions and PlaybackState.ACTION_SKIP_TO_NEXT) != 0L
        val canPrev = (actions and PlaybackState.ACTION_SKIP_TO_PREVIOUS) != 0L

        val title = md?.getString(MediaMetadata.METADATA_KEY_TITLE)
            ?: md?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)
        val artist = md?.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: md?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
        val album = md?.getString(MediaMetadata.METADATA_KEY_ALBUM)
        val duration = md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
        val position = ps?.position ?: 0L

        val bitmap: Bitmap? = md?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: md?.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
            ?: md?.getBitmap(MediaMetadata.METADATA_KEY_ART)
        val artworkB64 = bitmap?.let { encodeArtwork(it) }

        val app = try {
            val pm = context.packageManager
            val info = pm.getApplicationInfo(c.packageName, 0)
            pm.getApplicationLabel(info).toString()
        } catch (_: Throwable) { null }

        return WireMessage.MediaState(
            pkg = c.packageName,
            app = app,
            title = title,
            artist = artist,
            album = album,
            artwork = artworkB64,
            playing = isPlaying(c),
            positionMs = position,
            durationMs = duration,
            canPause = canPause,
            canSkipNext = canNext,
            canSkipPrev = canPrev,
            volume = volume,
            maxVolume = maxVolume,
            updatedAt = System.currentTimeMillis()
        )
    }

    private fun encodeArtwork(bmp: Bitmap): String? {
        return try {
            val scaled = scaleDown(bmp, 512)
            val baos = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 80, baos)
            Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
        } catch (e: Throwable) {
            Log.w(TAG, "artwork encode failed", e); null
        }
    }

    private fun scaleDown(bmp: Bitmap, maxEdge: Int): Bitmap {
        val w = bmp.width
        val h = bmp.height
        val maxDim = maxOf(w, h)
        if (maxDim <= maxEdge) return bmp
        val ratio = maxEdge.toFloat() / maxDim
        return Bitmap.createScaledBitmap(bmp, (w * ratio).toInt(), (h * ratio).toInt(), true)
    }

    companion object {
        private const val TAG = "MediaBridge"

        private val _state = MutableStateFlow<WireMessage.MediaState?>(null)
        val state: StateFlow<WireMessage.MediaState?> = _state.asStateFlow()

        @Volatile private var instance: MediaBridge? = null
        /** The live bridge (while the notification listener is bound), for
         *  local UI transport buttons. Null when the service isn't running. */
        fun current(): MediaBridge? = instance
    }
}
