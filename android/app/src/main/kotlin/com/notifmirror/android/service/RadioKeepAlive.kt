package com.notifmirror.android.service

import java.util.concurrent.atomic.AtomicInteger

/**
 * Keeps the Wi-Fi radio out of power-save during a bulk file transfer by
 * spamming tiny 1-byte binary WS frames at ~10 ms cadence.
 *
 * Empirically, on this device (Xiaomi Redmi Note 13 Pro / LineageOS + MT7981
 * AP), router→phone ping drops from avg 64 ms (with max 184 ms) to avg 6 ms
 * as soon as the phone has a steady stream of outgoing packets. The Wi-Fi
 * stack's idle-to-PSM transition is the culprit, and even
 * `WIFI_MODE_FULL_LOW_LATENCY` doesn't fully prevent it on this platform.
 *
 * Reference-counted: concurrent pulls / pushes share one heartbeat thread.
 * Enable via `begin()`, release via `end()`; thread auto-stops when refcount
 * drops to zero.
 */
internal object RadioKeepAlive {
    private val refs = AtomicInteger(0)

    @Volatile private var thread: Thread? = null
    @Volatile private var running = false

    fun begin() {
        if (refs.getAndIncrement() == 0) startThread()
    }

    fun end() {
        if (refs.decrementAndGet() == 0) stopThread()
    }

    private fun startThread() {
        running = true
        val t = Thread({
            while (running) {
                MirrorCore.sendHeartbeat()
                try { Thread.sleep(10) } catch (_: InterruptedException) { return@Thread }
            }
        }, "wifi-keepalive").apply {
            isDaemon = true
            priority = Thread.NORM_PRIORITY + 1
        }
        thread = t
        t.start()
    }

    private fun stopThread() {
        running = false
        thread?.interrupt()
        thread = null
    }
}
