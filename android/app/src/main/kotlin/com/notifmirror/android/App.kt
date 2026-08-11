package com.notifmirror.android

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        createTransfersChannel()
        createDiagnosticsChannel()
    }

    private fun createTransfersChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(
                    TRANSFERS_CHANNEL_ID,
                    "Transfers",
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "Incoming files from your paired Mac"
                }
            )
        }
    }

    private fun createDiagnosticsChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(
                    DIAGNOSTICS_CHANNEL_ID,
                    "Diagnostics",
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "End-to-end test notifications fired from the Mac"
                }
            )
        }
    }

    companion object {
        const val TRANSFERS_CHANNEL_ID = "notifmirror.transfers"
        const val DIAGNOSTICS_CHANNEL_ID = "notifmirror.diagnostics"
    }
}
