package com.notifmirror.android.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings as SystemSettings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.notifmirror.android.service.MirrorCore
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationManagerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.notifmirror.android.data.PairingStore
import com.notifmirror.android.data.Settings
import com.notifmirror.android.service.BatteryBridge
import com.notifmirror.android.service.FileBridge
import com.notifmirror.android.service.MediaBridge
import com.notifmirror.android.ui.theme.StatusConnected
import com.notifmirror.android.ui.theme.StatusStopped
import com.notifmirror.android.ui.theme.StatusWaiting

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun HomeScreen(onPair: () -> Unit, onOpenFilter: () -> Unit) {
    val context = LocalContext.current
    val store = remember { PairingStore(context) }
    var paired by remember { mutableStateOf(store.isPaired) }
    val pairing = remember(paired) { store.load() }

    val listenerEnabled = remember {
        mutableStateOf(
            NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)
        )
    }
    var postNotifications by remember {
        mutableStateOf(hasPostNotificationsPermission(context))
    }
    val postNotifLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted -> postNotifications = granted }
    val settings = remember { Settings.get(context) }
    var skipSilent by remember { mutableStateOf(settings.skipSilent) }

    val serviceRunning by MirrorCore.runningFlow.collectAsState()
    val serviceConnected by MirrorCore.connectedFlow.collectAsState()
    val battery by BatteryBridge.state.collectAsState()
    val media by MediaBridge.state.collectAsState()
    val transfers by FileBridge.transfers.collectAsState()

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                listenerEnabled.value = NotificationManagerCompat
                    .getEnabledListenerPackages(context)
                    .contains(context.packageName)
                postNotifications = hasPostNotificationsPermission(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        "NotifMirror",
                        fontWeight = FontWeight.SemiBold
                    )
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = Color.Transparent
                )
            )
        },
        containerColor = MaterialTheme.colorScheme.background
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            ConnectionCard(
                paired = paired,
                pairedName = pairing?.name,
                pairedHost = pairing?.let { "${it.host}:${it.port}" },
                serviceRunning = serviceRunning,
                serviceConnected = serviceConnected,
                onPair = onPair
            )

            BatteryCard(battery)

            NowPlayingCard(media)

            QuickActions(
                onOpenFilter = onOpenFilter,
                onOpenBattery = {
                    val intent = Intent(SystemSettings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                        .setData(Uri.parse("package:${context.packageName}"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                }
            )

            val allFilesGranted = remember { mutableStateOf(isAllFilesAccessGranted()) }
            DisposableEffect(lifecycleOwner) {
                val observer = LifecycleEventObserver { _, event ->
                    if (event == Lifecycle.Event.ON_RESUME) {
                        allFilesGranted.value = isAllFilesAccessGranted()
                    }
                }
                lifecycleOwner.lifecycle.addObserver(observer)
                onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
            }

            PermissionsCard(
                notificationAccessGranted = listenerEnabled.value,
                onOpenNotificationAccess = {
                    val intent = if (Build.VERSION.SDK_INT >= 30) {
                        Intent(SystemSettings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                            .putExtra(
                                SystemSettings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                                "${context.packageName}/com.notifmirror.android.service.MirrorListenerService"
                            )
                    } else {
                        Intent(SystemSettings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    }
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                },
                allFilesGranted = allFilesGranted.value,
                onOpenAllFilesAccess = {
                    val intent = if (Build.VERSION.SDK_INT >= 30) {
                        Intent(SystemSettings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                            .setData(Uri.parse("package:${context.packageName}"))
                    } else {
                        Intent(SystemSettings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                    }
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                },
                postNotificationsGranted = postNotifications,
                onOpenPostNotifications = {
                    postNotifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
            )

            PreferencesCard(
                skipSilent = skipSilent,
                onSkipSilentChange = {
                    skipSilent = it
                    settings.skipSilent = it
                }
            )

            TransferCard(transfers)

            TipCard()

            AnimatedVisibility(visible = paired) {
                TextButton(
                    onClick = {
                        store.clear()
                        paired = false
                    }
                ) {
                    Text(
                        "Forget pairing",
                        color = MaterialTheme.colorScheme.error
                    )
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}

// ---------- Connection Card (hero) ----------

@Composable
private fun ConnectionCard(
    paired: Boolean,
    pairedName: String?,
    pairedHost: String?,
    serviceRunning: Boolean,
    serviceConnected: Boolean,
    onPair: () -> Unit
) {
    val (statusColor, statusLabel, statusDetail) = when {
        !paired -> Triple(StatusStopped, "Not paired", "Scan the QR on your Mac to get started")
        !serviceRunning -> Triple(
            StatusStopped, "Waiting for access",
            "Grant notification access below to enable mirroring"
        )
        serviceConnected -> Triple(
            StatusConnected, "Connected",
            pairedName?.let { "Streaming notifications to $it" } ?: "Streaming to Mac"
        )
        else -> Triple(StatusWaiting, "Looking for your Mac", "Scanning the network…")
    }

    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
        ),
        elevation = CardDefaults.elevatedCardElevation(defaultElevation = 0.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(color = statusColor, pulse = serviceRunning && !serviceConnected)
                Spacer(Modifier.size(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        statusLabel,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        statusDetail,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            if (paired && pairedName != null) {
                PairedInfoRow(name = pairedName, host = pairedHost.orEmpty())
            }

            FilledTonalButton(
                onClick = onPair,
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Filled.QrCodeScanner, contentDescription = null)
                Spacer(Modifier.size(8.dp))
                Text(if (paired) "Re-pair" else "Pair with Mac")
            }
        }
    }
}

@Composable
private fun PairedInfoRow(name: String, host: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center
        ) {
            Text(
                name.take(1).uppercase(),
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onPrimaryContainer
            )
        }
        Spacer(Modifier.size(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                name,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                host,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun StatusDot(color: Color, pulse: Boolean) {
    val transition = rememberInfiniteTransition(label = "status-pulse")
    val scale by transition.animateFloat(
        initialValue = 1f,
        targetValue = if (pulse) 1.6f else 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1100),
            repeatMode = RepeatMode.Reverse
        ),
        label = "scale"
    )
    val haloAlpha by transition.animateFloat(
        initialValue = 0.45f,
        targetValue = if (pulse) 0f else 0.3f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1100),
            repeatMode = RepeatMode.Reverse
        ),
        label = "alpha"
    )

    Box(
        modifier = Modifier.size(28.dp),
        contentAlignment = Alignment.Center
    ) {
        Box(
            modifier = Modifier
                .size((16 * scale).dp)
                .clip(CircleShape)
                .background(color.copy(alpha = haloAlpha))
        )
        Box(
            modifier = Modifier
                .size(12.dp)
                .clip(CircleShape)
                .background(color)
        )
    }
}

// ---------- Quick Actions ----------

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun QuickActions(
    onOpenFilter: () -> Unit,
    onOpenBattery: () -> Unit
) {
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        ActionTile(
            icon = Icons.Filled.Apps,
            label = "Mirrored apps",
            description = "Choose what to send",
            onClick = onOpenFilter,
            modifier = Modifier.weight(1f, fill = true)
        )
        ActionTile(
            icon = Icons.Filled.BatteryChargingFull,
            label = "Battery",
            description = "Stay connected",
            onClick = onOpenBattery,
            modifier = Modifier.weight(1f, fill = true)
        )
    }
}

@Composable
private fun ActionTile(
    icon: ImageVector,
    label: String,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        onClick = onClick,
        modifier = modifier,
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
        )
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.primaryContainer),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimaryContainer
                )
            }
            Text(
                label,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

// ---------- Permissions Card ----------

@Composable
private fun PermissionsCard(
    notificationAccessGranted: Boolean,
    onOpenNotificationAccess: () -> Unit,
    allFilesGranted: Boolean,
    onOpenAllFilesAccess: () -> Unit,
    postNotificationsGranted: Boolean,
    onOpenPostNotifications: () -> Unit
) {
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
                .padding(4.dp)
        ) {
            SettingRow(
                icon = Icons.Filled.NotificationsActive,
                title = "Notification access",
                subtitle = if (notificationAccessGranted) "Granted" else "Tap to grant",
                statusOk = notificationAccessGranted,
                onClick = onOpenNotificationAccess
            )
            SettingRow(
                icon = Icons.Filled.Info,
                title = "Notifications",
                subtitle = if (postNotificationsGranted) "Granted" else "Needed for received files & the Mac's test",
                statusOk = postNotificationsGranted,
                onClick = onOpenPostNotifications
            )
            SettingRow(
                icon = Icons.Filled.Folder,
                title = "All files access (for Mac file browser)",
                subtitle = if (allFilesGranted) "Granted — Mac can browse phone files" else "Tap to grant; optional",
                statusOk = allFilesGranted,
                onClick = onOpenAllFilesAccess
            )
        }
    }
}

private fun hasPostNotificationsPermission(context: android.content.Context): Boolean {
    return if (Build.VERSION.SDK_INT >= 33) {
        ContextCompat.checkSelfPermission(
            context, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
    } else {
        true
    }
}

/** Returns true if the app can list/read/write arbitrary shared storage. */
private fun isAllFilesAccessGranted(): Boolean {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        Environment.isExternalStorageManager()
    } else {
        true  // Pre-R apps that declared legacy READ/WRITE permissions are fine.
    }
}

// ---------- Preferences Card ----------

@Composable
private fun PreferencesCard(
    skipSilent: Boolean,
    onSkipSilentChange: (Boolean) -> Unit
) {
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
                .padding(horizontal = 20.dp, vertical = 18.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Skip silent notifications",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    "Don't mirror low/min importance channels",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Switch(
                checked = skipSilent,
                onCheckedChange = onSkipSilentChange,
                colors = SwitchDefaults.colors()
            )
        }
    }
}

// ---------- Tip Card ----------

@Composable
private fun TipCard() {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.55f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(18.dp),
            verticalAlignment = Alignment.Top
        ) {
            Icon(
                Icons.Filled.ContentPaste,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSecondaryContainer
            )
            Spacer(Modifier.size(12.dp))
            Column {
                Text(
                    "Send clipboard in one tap",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "Share text to NotifMirror from any app, or add the \"Send clipboard\" " +
                        "tile to Quick Settings for instant sending.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer
                )
            }
        }
    }
}

// ---------- Generic setting row ----------

@Composable
private fun SettingRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    statusOk: Boolean,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(
                    if (statusOk)
                        MaterialTheme.colorScheme.secondaryContainer
                    else
                        MaterialTheme.colorScheme.errorContainer
                ),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = if (statusOk)
                    MaterialTheme.colorScheme.onSecondaryContainer
                else
                    MaterialTheme.colorScheme.onErrorContainer
            )
        }
        Spacer(Modifier.size(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = if (statusOk)
                    MaterialTheme.colorScheme.onSurfaceVariant
                else
                    MaterialTheme.colorScheme.error
            )
        }
        IconButton(onClick = onClick) {
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
