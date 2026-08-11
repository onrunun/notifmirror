package com.notifmirror.android.data

import android.content.Context
import android.content.SharedPreferences

class Settings private constructor(ctx: Context) {
    private val prefs: SharedPreferences = ctx.applicationContext
        .getSharedPreferences("settings", Context.MODE_PRIVATE)

    var skipSilent: Boolean
        get() = prefs.getBoolean(KEY_SKIP_SILENT, false)
        set(value) = prefs.edit().putBoolean(KEY_SKIP_SILENT, value).apply()

    companion object {
        private const val KEY_SKIP_SILENT = "skip_silent"

        @Volatile private var instance: Settings? = null

        fun get(context: Context): Settings =
            instance ?: synchronized(this) {
                instance ?: Settings(context).also { instance = it }
            }
    }
}
