package com.notifmirror.android.service

import android.app.Notification
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.Icon
import android.os.Build
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.Log
import com.notifmirror.android.protocol.ActionDescriptor
import com.notifmirror.android.protocol.WireMessage
import java.io.ByteArrayOutputStream

object NotificationExtractor {

    private const val TAG = "NotifExtract"
    private const val MAX_PICTURE_EDGE = 1024
    private const val MAX_ICON_EDGE = 192

    fun shouldMirror(sbn: StatusBarNotification): Boolean {
        val flags = sbn.notification.flags
        if ((flags and Notification.FLAG_ONGOING_EVENT) != 0) return false
        if ((flags and Notification.FLAG_GROUP_SUMMARY) != 0) return false
        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString().orEmpty()
        return title.isNotEmpty() || text.isNotEmpty() || bigText.isNotEmpty()
    }

    fun extract(
        context: Context,
        sbn: StatusBarNotification,
        isSilent: Boolean = false
    ): WireMessage.Posted {
        val n = sbn.notification
        val extras = n.extras

        val pkg = sbn.packageName
        val pm = context.packageManager
        val app = runCatching {
            val ai = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationLabel(ai).toString()
        }.getOrDefault(pkg)

        val appIconB64 = runCatching {
            val drawable = pm.getApplicationIcon(pkg)
            drawableToBase64Png(drawable, MAX_ICON_EDGE)
        }.getOrNull()

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
        val text = bigText ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
        val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()

        val largeIconB64 = extractIconExtra(context, extras, Notification.EXTRA_LARGE_ICON_BIG)
            ?: extractIconExtra(context, extras, Notification.EXTRA_LARGE_ICON)

        val pictureB64 = extractPicture(context, extras)

        val actions = (n.actions?.toList() ?: emptyList()).mapIndexedNotNull { idx, a ->
            val title = a.title?.toString() ?: return@mapIndexedNotNull null
            val isReply = if (Build.VERSION.SDK_INT >= 24) {
                a.remoteInputs?.any { it.allowFreeFormInput } == true
            } else false
            ActionDescriptor(id = idx.toString(), title = title, isReply = isReply)
        }

        return WireMessage.Posted(
            key = sbn.key,
            pkg = pkg,
            app = app,
            title = title,
            text = text,
            subText = subText,
            appIcon = appIconB64,
            largeIcon = largeIconB64,
            picture = pictureB64,
            postTime = sbn.postTime,
            silent = isSilent,
            actions = actions
        )
    }

    private fun extractPicture(context: Context, extras: android.os.Bundle): String? {
        val bitmap: Bitmap? = runCatching {
            @Suppress("DEPRECATION")
            (extras.getParcelable(Notification.EXTRA_PICTURE) as? Bitmap)
        }.getOrNull()
        if (bitmap != null) return bitmapToBase64Jpeg(bitmap, MAX_PICTURE_EDGE)

        // EXTRA_PICTURE_ICON exists on API 31+
        if (Build.VERSION.SDK_INT >= 31) {
            val icon: Icon? = runCatching {
                @Suppress("DEPRECATION")
                (extras.getParcelable("android.pictureIcon") as? Icon)
            }.getOrNull()
            if (icon != null) {
                val drawable = icon.loadDrawable(context)
                if (drawable != null) {
                    return drawableToBase64Jpeg(drawable, MAX_PICTURE_EDGE)
                }
            }
        }
        return null
    }

    private fun extractIconExtra(context: Context, extras: android.os.Bundle, key: String): String? {
        val direct = runCatching {
            @Suppress("DEPRECATION")
            (extras.getParcelable(key) as? Bitmap)
        }.getOrNull()
        if (direct != null) return bitmapToBase64Jpeg(direct, MAX_ICON_EDGE)

        val icon = runCatching {
            @Suppress("DEPRECATION")
            (extras.getParcelable(key) as? Icon)
        }.getOrNull()
        if (icon != null) {
            val drawable = icon.loadDrawable(context)
            if (drawable != null) return drawableToBase64Png(drawable, MAX_ICON_EDGE)
        }
        return null
    }

    private fun drawableToBase64Png(drawable: Drawable, maxEdge: Int): String {
        val bm = drawableToBitmap(drawable, maxEdge)
        val out = ByteArrayOutputStream()
        bm.compress(Bitmap.CompressFormat.PNG, 100, out)
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    private fun drawableToBase64Jpeg(drawable: Drawable, maxEdge: Int): String {
        val bm = drawableToBitmap(drawable, maxEdge)
        return bitmapToBase64Jpeg(bm, maxEdge)
    }

    private fun bitmapToBase64Jpeg(src: Bitmap, maxEdge: Int): String {
        val bm = downscale(src, maxEdge)
        val out = ByteArrayOutputStream()
        bm.compress(Bitmap.CompressFormat.JPEG, 80, out)
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    private fun drawableToBitmap(drawable: Drawable, maxEdge: Int): Bitmap {
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            return downscale(drawable.bitmap, maxEdge)
        }
        val w = (drawable.intrinsicWidth.takeIf { it > 0 } ?: maxEdge).coerceAtMost(maxEdge)
        val h = (drawable.intrinsicHeight.takeIf { it > 0 } ?: maxEdge).coerceAtMost(maxEdge)
        val bm = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bm)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bm
    }

    private fun downscale(src: Bitmap, maxEdge: Int): Bitmap {
        val longest = maxOf(src.width, src.height)
        if (longest <= maxEdge) return src
        val ratio = maxEdge.toFloat() / longest
        val w = (src.width * ratio).toInt().coerceAtLeast(1)
        val h = (src.height * ratio).toInt().coerceAtLeast(1)
        return runCatching { Bitmap.createScaledBitmap(src, w, h, true) }
            .getOrElse {
                Log.w(TAG, "scale failed", it); src
            }
    }
}
