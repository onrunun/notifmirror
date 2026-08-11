package com.notifmirror.android.ui

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ClearAll
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.notifmirror.android.data.BlockedApps
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private enum class FilterMode { All, Enabled, Blocked }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FilterScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val store = remember { BlockedApps.get(context) }

    val seenComparator = remember {
        compareByDescending<BlockedApps.SeenApp> { it.count }
            .thenBy { it.name.lowercase() }
    }
    var seen by remember { mutableStateOf(store.loadSeen().sortedWith(seenComparator)) }
    var blocked by remember { mutableStateOf(store.blockedSet()) }
    var query by remember { mutableStateOf("") }
    var mode by remember { mutableStateOf(FilterMode.All) }

    LaunchedEffect(Unit) {
        while (true) {
            delay(2000)
            seen = store.loadSeen().sortedWith(seenComparator)
            blocked = store.blockedSet()
        }
    }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        "Mirrored apps",
                        fontWeight = FontWeight.SemiBold
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    if (seen.isNotEmpty()) {
                        IconButton(
                            onClick = {
                                store.clearSeen()
                                seen = emptyList()
                            }
                        ) {
                            Icon(
                                Icons.Filled.ClearAll,
                                contentDescription = "Clear seen apps"
                            )
                        }
                    }
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
                .padding(horizontal = 20.dp)
        ) {
            SummaryStrip(
                total = seen.size,
                mirrored = seen.count { !blocked.contains(it.pkg) }
            )

            Spacer(Modifier.height(14.dp))

            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                leadingIcon = {
                    Icon(
                        Icons.Filled.Search,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                },
                placeholder = { Text("Search apps") },
                singleLine = true,
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.fillMaxWidth(),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent
                )
            )

            Spacer(Modifier.height(12.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                FilterMode.entries.forEach { m ->
                    FilterChip(
                        selected = mode == m,
                        onClick = { mode = m },
                        label = {
                            Text(
                                when (m) {
                                    FilterMode.All -> "All"
                                    FilterMode.Enabled -> "Mirrored"
                                    FilterMode.Blocked -> "Blocked"
                                }
                            )
                        },
                        shape = RoundedCornerShape(14.dp),
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                            selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer
                        )
                    )
                }
            }

            Spacer(Modifier.height(8.dp))

            val filtered = remember(query, seen, blocked, mode) {
                seen
                    .asSequence()
                    .filter {
                        query.isBlank() ||
                            it.name.contains(query, ignoreCase = true) ||
                            it.pkg.contains(query, ignoreCase = true)
                    }
                    .filter {
                        when (mode) {
                            FilterMode.All -> true
                            FilterMode.Enabled -> !blocked.contains(it.pkg)
                            FilterMode.Blocked -> blocked.contains(it.pkg)
                        }
                    }
                    .toList()
            }

            if (filtered.isEmpty()) {
                EmptyState(
                    hasSeen = seen.isNotEmpty(),
                    hasQuery = query.isNotBlank() || mode != FilterMode.All
                )
            } else {
                val iconCache = remember { mutableStateMapOf<String, Painter?>() }
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 4.dp)
                ) {
                    items(filtered, key = { it.pkg }) { app ->
                        AppRow(
                            name = app.name,
                            pkg = app.pkg,
                            count = app.count,
                            isMirrored = !blocked.contains(app.pkg),
                            iconCache = iconCache,
                            onToggle = { enabled ->
                                store.setBlocked(app.pkg, blocked = !enabled)
                                blocked = store.blockedSet()
                            }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SummaryStrip(total: Int, mirrored: Int) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f))
            .padding(horizontal = 18.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        SummaryItem(
            label = "Total",
            value = total.toString(),
            modifier = Modifier.weight(1f)
        )
        VerticalDivider()
        SummaryItem(
            label = "Mirrored",
            value = mirrored.toString(),
            accent = MaterialTheme.colorScheme.secondary,
            modifier = Modifier.weight(1f)
        )
        VerticalDivider()
        SummaryItem(
            label = "Blocked",
            value = (total - mirrored).toString(),
            accent = MaterialTheme.colorScheme.error,
            modifier = Modifier.weight(1f)
        )
    }
}

@Composable
private fun SummaryItem(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    accent: Color = MaterialTheme.colorScheme.onSurface
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            value,
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
            color = accent
        )
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun VerticalDivider() {
    Box(
        modifier = Modifier
            .size(width = 1.dp, height = 28.dp)
            .background(MaterialTheme.colorScheme.outlineVariant)
    )
}

@Composable
private fun AppRow(
    name: String,
    pkg: String,
    count: Long,
    isMirrored: Boolean,
    iconCache: androidx.compose.runtime.snapshots.SnapshotStateMap<String, Painter?>,
    onToggle: (Boolean) -> Unit
) {
    val context = LocalContext.current
    val fallback = rememberVectorPainter(Icons.Outlined.Inbox)
    // False positive: this producer DOES assign `value` below, but the
    // ProduceStateDoesNotAssignValue flow analysis trips on the snapshot-map
    // read (iconCache[pkg]) it shares with the initialValue expression.
    @Suppress("ProduceStateDoesNotAssignValue")
    val painter by produceState<Painter?>(initialValue = iconCache[pkg], pkg) {
        value = iconCache[pkg]
        if (value == null) {
            value = withContext(Dispatchers.IO) { loadAppIcon(context, pkg) }
            iconCache[pkg] = value
        }
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f))
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(MaterialTheme.colorScheme.surface),
            contentAlignment = Alignment.Center
        ) {
            androidx.compose.foundation.Image(
                painter = painter ?: fallback,
                contentDescription = null,
                modifier = Modifier.size(32.dp)
            )
        }
        Spacer(Modifier.size(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                name,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                pkg,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        if (count > 0) {
            Text(
                formatCount(count),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(Modifier.size(12.dp))
        } else {
            Spacer(Modifier.size(8.dp))
        }
        Switch(
            checked = isMirrored,
            onCheckedChange = onToggle
        )
    }
}

private fun formatCount(count: Long): String = when {
    count < 1_000 -> count.toString()
    count < 1_000_000 -> "%.1fk".format(count / 1_000.0).replace(".0k", "k")
    else -> "%.1fM".format(count / 1_000_000.0).replace(".0M", "M")
}

@Composable
private fun EmptyState(hasSeen: Boolean, hasQuery: Boolean) {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier
                .size(72.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                when {
                    !hasSeen -> Icons.Outlined.Inbox
                    hasQuery -> Icons.Filled.Search
                    else -> Icons.Filled.CheckCircle
                },
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(32.dp)
            )
        }
        Spacer(Modifier.height(14.dp))
        Text(
            when {
                !hasSeen -> "No apps yet"
                hasQuery -> "No matches"
                else -> "Nothing here"
            },
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(Modifier.height(4.dp))
        Text(
            when {
                !hasSeen -> "Apps appear once they send their first notification."
                hasQuery -> "Try a different search or filter."
                else -> "No apps match this filter."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 32.dp)
        )
    }
}

private fun loadAppIcon(context: Context, pkg: String): Painter? {
    val pm = context.packageManager
    return try {
        val drawable: Drawable = pm.getApplicationIcon(pkg)
        BitmapPainter(drawable.toBitmapSafe().asImageBitmap())
    } catch (_: PackageManager.NameNotFoundException) {
        null
    } catch (_: Throwable) {
        null
    }
}

private fun Drawable.toBitmapSafe(): Bitmap {
    if (this is BitmapDrawable && bitmap != null) return bitmap
    val w = intrinsicWidth.takeIf { it > 0 } ?: 96
    val h = intrinsicHeight.takeIf { it > 0 } ?: 96
    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bmp)
    setBounds(0, 0, canvas.width, canvas.height)
    draw(canvas)
    return bmp
}
