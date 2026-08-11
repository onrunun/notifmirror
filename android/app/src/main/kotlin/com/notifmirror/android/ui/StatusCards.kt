package com.notifmirror.android.ui

import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.BatteryFull
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.notifmirror.android.protocol.WireMessage
import com.notifmirror.android.service.MediaBridge
import com.notifmirror.android.service.TransferEntry

// ---------- Battery ----------

@Composable
fun BatteryCard(battery: WireMessage.BatteryState?) {
    if (battery == null) return
    val charging = battery.charging
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                if (charging) Icons.Filled.BatteryChargingFull else Icons.Filled.BatteryFull,
                contentDescription = null,
                tint = if (battery.low) MaterialTheme.colorScheme.error
                else MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(28.dp)
            )
            Spacer(Modifier.size(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    if (battery.level >= 0) "${battery.level}%" else "—",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    batteryDetail(battery),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (battery.low) {
                Icon(
                    Icons.Filled.Warning,
                    contentDescription = "Low battery",
                    tint = MaterialTheme.colorScheme.error
                )
            }
        }
    }
}

private fun batteryDetail(b: WireMessage.BatteryState): String {
    val parts = mutableListOf<String>()
    when (b.status) {
        "charging" -> parts.add("Charging")
        "full" -> parts.add("Full")
        "discharging", "not_charging" -> parts.add("On battery")
    }
    if (b.plugged != "none" && b.plugged != "unknown") parts.add("via ${b.plugged}")
    b.temperatureC?.let { parts.add("%.1f°C".format(it)) }
    if (parts.isEmpty()) parts.add("Battery")
    return parts.joinToString(" • ")
}

// ---------- Now playing ----------

@Composable
fun NowPlayingCard(media: WireMessage.MediaState?) {
    val hasSession = media?.let {
        it.pkg != null || it.title != null || it.artist != null
    } ?: false
    if (!hasSession) return

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Artwork(media)
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    media?.title ?: media?.app ?: "Now playing",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                if (!media?.artist.isNullOrEmpty()) {
                    Text(
                        media?.artist.orEmpty(),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            Spacer(Modifier.width(8.dp))
            TransportButtons(media)
        }
    }
}

@Composable
private fun Artwork(media: WireMessage.MediaState?) {
    val artwork = media?.artwork?.let { decodeArtwork(it) }
    if (artwork != null) {
        Image(
            bitmap = artwork,
            contentDescription = null,
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(10.dp))
        )
    } else {
        Box(
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Filled.MusicNote,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

private fun decodeArtwork(b64: String?): androidx.compose.ui.graphics.ImageBitmap? {
    if (b64.isNullOrEmpty()) return null
    return try {
        val bytes = Base64.decode(b64, Base64.NO_WRAP)
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
    } catch (_: Throwable) { null }
}

@Composable
private fun TransportButtons(media: WireMessage.MediaState?) {
    val bridge = MediaBridge.current()
    IconButton(
        onClick = { bridge?.handleCommand("prev") },
        enabled = media?.canSkipPrev == true && bridge != null
    ) {
        Icon(
            Icons.Filled.SkipPrevious,
            contentDescription = "Previous",
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
    IconButton(
        onClick = { bridge?.handleCommand("toggle") },
        enabled = bridge != null
    ) {
        Icon(
            if (media?.playing == true) Icons.Filled.Pause else Icons.Filled.PlayArrow,
            contentDescription = if (media?.playing == true) "Pause" else "Play",
            tint = MaterialTheme.colorScheme.primary
        )
    }
    IconButton(
        onClick = { bridge?.handleCommand("next") },
        enabled = media?.canSkipNext == true && bridge != null
    ) {
        Icon(Icons.Filled.SkipNext, contentDescription = "Next", tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// ---------- Transfers ----------

@Composable
fun TransferCard(transfers: List<TransferEntry>) {
    if (transfers.isEmpty()) return
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
        )
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                "File transfers",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            transfers.take(5).forEach { t ->
                TransferRow(t)
            }
        }
    }
}

@Composable
private fun TransferRow(t: TransferEntry) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            if (t.direction == TransferEntry.Direction.Incoming) Icons.Filled.Download
            else Icons.Filled.Upload,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                t.name,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (t.status == TransferEntry.Status.Active || t.status == TransferEntry.Status.Pending) {
                val progress = if (t.size > 0) t.bytesTransferred.toFloat() / t.size else 0f
                LinearProgressIndicator(
                    progress = { progress.coerceIn(0f, 1f) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(4.dp)
                )
            }
            Spacer(Modifier.height(2.dp))
            val sizeText = if (t.size > 0) " / ${formatBytes(t.size)}" else ""
            Text(
                "${t.status.label} • ${formatBytes(t.bytesTransferred)}$sizeText",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

private val TransferEntry.Status.label: String
    get() = when (this) {
        TransferEntry.Status.Pending -> "Waiting"
        TransferEntry.Status.Active -> "Transferring"
        TransferEntry.Status.Done -> "Done"
        TransferEntry.Status.Failed -> "Failed"
        TransferEntry.Status.Cancelled -> "Cancelled"
    }

private fun formatBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024) return "%.0f KB".format(kb)
    val mb = kb / 1024.0
    if (mb < 1024) return "%.1f MB".format(mb)
    return "%.2f GB".format(mb / 1024.0)
}
