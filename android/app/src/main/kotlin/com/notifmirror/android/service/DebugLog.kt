package com.notifmirror.android.service

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * File-based debug log. Android 16's logd dropped our Log.* output in some
 * configurations, so we append to a flat file at
 * `/sdcard/Download/notifmirror_debug.log` for easy tailing/pulling via adb.
 * Mirrors the Mac-side DebugLog pattern.
 */
internal object DebugLog {
    private val file = File("/sdcard/Download/notifmirror_debug.log")
    private val fmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    @Synchronized
    fun line(msg: String) {
        try {
            file.appendText("${fmt.format(Date())} $msg\n")
        } catch (_: Throwable) {
        }
    }
}
