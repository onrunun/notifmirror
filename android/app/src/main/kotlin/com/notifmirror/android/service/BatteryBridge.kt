package com.notifmirror.android.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.util.Log
import com.notifmirror.android.protocol.WireMessage
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Watches the system battery state via the sticky `ACTION_BATTERY_CHANGED`
 * broadcast plus the targeted plug/unplug and low/okay broadcasts, and
 * forwards a `battery_state` snapshot to the Mac.
 *
 * Throttling: republishes only when level changes by ≥1 %, charge-state
 * transitions, plug source changes, or low-state toggles. A hard 5s
 * minimum interval guards against the brief level chatter that happens
 * around plug-in.
 *
 * The latest snapshot is also published on [state] so the app's own UI can
 * show it without waiting for the next system broadcast.
 */
class BatteryBridge(private val context: Context) {

    private var registered = false
    private var lastLevel: Int = Int.MIN_VALUE
    private var lastCharging: Boolean? = null
    private var lastStatus: String = ""
    private var lastPlugged: String = ""
    private var lastLow: Boolean = false
    private var lastSentAt: Long = 0L

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_BATTERY_LOW -> { lastLow = true; refreshAndPublish(force = true) }
                Intent.ACTION_BATTERY_OKAY -> { lastLow = false; refreshAndPublish(force = true) }
                Intent.ACTION_POWER_CONNECTED,
                Intent.ACTION_POWER_DISCONNECTED -> refreshAndPublish(force = true)
                Intent.ACTION_BATTERY_CHANGED -> publishFrom(intent, force = false)
            }
        }
    }

    fun start() {
        if (registered) return
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(Intent.ACTION_BATTERY_LOW)
            addAction(Intent.ACTION_BATTERY_OKAY)
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }
        // ACTION_BATTERY_CHANGED is sticky — registerReceiver returns the
        // most recent intent immediately, so we get an initial snapshot.
        val sticky = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        registered = true
        if (sticky != null && sticky.action == Intent.ACTION_BATTERY_CHANGED) {
            publishFrom(sticky, force = true)
        }
    }

    fun stop() {
        if (!registered) return
        try { context.unregisterReceiver(receiver) } catch (_: Throwable) {}
        registered = false
    }

    /** Force-publish current state — used when the WS reconnects so the Mac
     *  sees a fresh snapshot without waiting for the next change event. */
    fun publishIfConnected() {
        val sticky = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        if (sticky != null) publishFrom(sticky, force = true) else sendUnknown()
    }

    private fun refreshAndPublish(force: Boolean) {
        val sticky = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        if (sticky != null) publishFrom(sticky, force = force) else sendUnknown()
    }

    private fun publishFrom(intent: Intent, force: Boolean) {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val pct = if (level < 0 || scale <= 0) -1 else ((level * 100) / scale).coerceIn(0, 100)

        val rawStatus = intent.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN)
        val status = when (rawStatus) {
            BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
            BatteryManager.BATTERY_STATUS_DISCHARGING -> "discharging"
            BatteryManager.BATTERY_STATUS_FULL -> "full"
            BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "not_charging"
            else -> "unknown"
        }

        val rawPlugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
        val plugged = when (rawPlugged) {
            BatteryManager.BATTERY_PLUGGED_AC -> "ac"
            BatteryManager.BATTERY_PLUGGED_USB -> "usb"
            BatteryManager.BATTERY_PLUGGED_WIRELESS -> "wireless"
            // BATTERY_PLUGGED_DOCK = 8 on Android 12+; reference by literal so
            // we still compile against older SDKs.
            8 -> "dock"
            0 -> "none"
            else -> "unknown"
        }

        val charging = rawStatus == BatteryManager.BATTERY_STATUS_CHARGING ||
            (rawStatus == BatteryManager.BATTERY_STATUS_FULL && rawPlugged != 0)

        val tempTenths = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
        val temperatureC: Double? = if (tempTenths == Int.MIN_VALUE) null else tempTenths / 10.0

        val voltMv = intent.getIntExtra(BatteryManager.EXTRA_VOLTAGE, Int.MIN_VALUE)
        val voltageMv: Int? = if (voltMv == Int.MIN_VALUE) null else voltMv

        val now = System.currentTimeMillis()
        val levelChanged = pct != lastLevel
        val chargingChanged = lastCharging != charging
        val statusChanged = status != lastStatus
        val pluggedChanged = plugged != lastPlugged
        val anyChange = levelChanged || chargingChanged || statusChanged || pluggedChanged
        val cooldownOver = (now - lastSentAt) >= MIN_INTERVAL_MS

        if (!force && !anyChange) return
        if (!force && !cooldownOver) return

        lastLevel = pct
        lastCharging = charging
        lastStatus = status
        lastPlugged = plugged
        lastSentAt = now

        val msg = WireMessage.BatteryState(
            level = pct,
            charging = charging,
            status = status,
            plugged = plugged,
            temperatureC = temperatureC,
            voltageMv = voltageMv,
            low = lastLow,
            updatedAt = now
        )
        _state.value = msg
        Log.i(TAG, "publish level=$pct charging=$charging status=$status plugged=$plugged")
        MirrorCore.dispatch(msg)
    }

    /** Fallback when the OS hasn't fired ACTION_BATTERY_CHANGED yet
     *  (e.g. emulator). Send a level=-1 snapshot so the Mac UI shows a
     *  placeholder rather than nothing at all. */
    private fun sendUnknown() {
        val now = System.currentTimeMillis()
        if (lastLevel == -1 && (now - lastSentAt) < MIN_INTERVAL_MS) return
        lastLevel = -1
        lastSentAt = now
        val msg = WireMessage.BatteryState(
            level = -1, charging = false, status = "unknown",
            plugged = "unknown", temperatureC = null, voltageMv = null,
            low = false, updatedAt = now
        )
        _state.value = msg
        MirrorCore.dispatch(msg)
    }

    companion object {
        private const val TAG = "BatteryBridge"
        private const val MIN_INTERVAL_MS = 5_000L

        private val _state = MutableStateFlow<WireMessage.BatteryState?>(null)
        val state: StateFlow<WireMessage.BatteryState?> = _state.asStateFlow()
    }
}
