package com.notifmirror.android.ui

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.util.Log
import android.view.ViewGroup
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.notifmirror.android.data.PairingPayload
import com.notifmirror.android.data.PairingStore
import com.notifmirror.android.service.MirrorCore

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairingScreen(onDone: () -> Unit, onCancel: () -> Unit) {
    val context = LocalContext.current
    var hasCamera by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
                == PackageManager.PERMISSION_GRANTED
        )
    }
    val launcher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { granted -> hasCamera = granted }

    LaunchedEffect(Unit) {
        if (!hasCamera) launcher.launch(Manifest.permission.CAMERA)
    }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        "Pair with Mac",
                        fontWeight = FontWeight.SemiBold
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onCancel) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
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
                .padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp)
        ) {
            Spacer(Modifier.height(4.dp))

            Text(
                "Scan the QR code",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onBackground
            )
            Text(
                "Open NotifMirror on your Mac and point your camera at the pairing QR.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center
            )

            if (hasCamera) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(1f)
                        .clip(RoundedCornerShape(28.dp))
                        .background(Color.Black)
                ) {
                    CameraScannerView(
                        onPayload = { payload ->
                            val parsed = PairingPayload.fromJson(payload)
                            if (parsed != null) {
                                PairingStore(context).save(parsed)
                                MirrorCore.notifyPairingChanged()
                                onDone()
                            } else {
                                Log.w("PairingScreen", "non-pairing QR scanned")
                            }
                        }
                    )
                    ViewfinderOverlay(modifier = Modifier.fillMaxSize())
                }
            } else {
                CameraPermissionPrompt(
                    onRequest = { launcher.launch(Manifest.permission.CAMERA) }
                )
            }

            HintRow()

            Spacer(Modifier.weight(1f))

            FilledTonalButton(
                onClick = onCancel,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Cancel")
            }

            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun ViewfinderOverlay(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "scan-line")
    val sweep by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1800),
            repeatMode = RepeatMode.Restart
        ),
        label = "sweep"
    )

    val cornerColor = MaterialTheme.colorScheme.primary
    val scanLine = MaterialTheme.colorScheme.primary.copy(alpha = 0.7f)

    Canvas(modifier = modifier) {
        val frameSize = size.minDimension * 0.7f
        val left = (size.width - frameSize) / 2f
        val top = (size.height - frameSize) / 2f
        val corner = frameSize * 0.14f
        val stroke = 4.dp.toPx()

        // Top-left L
        drawLine(
            cornerColor,
            start = Offset(left, top + corner),
            end = Offset(left, top),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        drawLine(
            cornerColor,
            start = Offset(left, top),
            end = Offset(left + corner, top),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        // Top-right L
        drawLine(
            cornerColor,
            start = Offset(left + frameSize - corner, top),
            end = Offset(left + frameSize, top),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        drawLine(
            cornerColor,
            start = Offset(left + frameSize, top),
            end = Offset(left + frameSize, top + corner),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        // Bottom-left L
        drawLine(
            cornerColor,
            start = Offset(left, top + frameSize - corner),
            end = Offset(left, top + frameSize),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        drawLine(
            cornerColor,
            start = Offset(left, top + frameSize),
            end = Offset(left + corner, top + frameSize),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        // Bottom-right L
        drawLine(
            cornerColor,
            start = Offset(left + frameSize - corner, top + frameSize),
            end = Offset(left + frameSize, top + frameSize),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        drawLine(
            cornerColor,
            start = Offset(left + frameSize, top + frameSize - corner),
            end = Offset(left + frameSize, top + frameSize),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )

        // Animated scan line
        val y = top + frameSize * sweep
        drawLine(
            scanLine,
            start = Offset(left + corner, y),
            end = Offset(left + frameSize - corner, y),
            strokeWidth = 2.dp.toPx(),
            cap = StrokeCap.Round
        )
    }
}

@Composable
private fun CameraPermissionPrompt(onRequest: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(1f)
            .clip(RoundedCornerShape(28.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier
                .size(72.dp)
                .clip(RoundedCornerShape(24.dp))
                .background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Filled.CameraAlt,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.size(32.dp)
            )
        }
        Spacer(Modifier.height(16.dp))
        Text(
            "Camera access needed",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "We use the camera only to scan your pairing QR.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            modifier = Modifier.padding(horizontal = 24.dp)
        )
        Spacer(Modifier.height(16.dp))
        FilledTonalButton(onClick = onRequest) {
            Text("Allow camera")
        }
    }
}

@Composable
private fun HintRow() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f))
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            Icons.Filled.QrCodeScanner,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary
        )
        Spacer(Modifier.size(12.dp))
        Text(
            "Both devices must be on the same Wi-Fi network.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

@Composable
@OptIn(ExperimentalGetImage::class)
@SuppressLint("UnsafeOptInUsageError")
private fun CameraScannerView(onPayload: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val executor = remember { java.util.concurrent.Executors.newSingleThreadExecutor() }
    val scanner = remember { BarcodeScanning.getClient() }
    var consumed by remember { mutableStateOf(false) }

    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { ctx ->
            val previewView = PreviewView(ctx).apply {
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
                scaleType = PreviewView.ScaleType.FILL_CENTER
            }
            val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
            cameraProviderFuture.addListener({
                val cameraProvider = cameraProviderFuture.get()
                val preview = Preview.Builder().build().also {
                    it.setSurfaceProvider(previewView.surfaceProvider)
                }
                val analyzer = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analyzer.setAnalyzer(executor) { proxy: ImageProxy ->
                    if (consumed) { proxy.close(); return@setAnalyzer }
                    val mediaImage = proxy.image
                    if (mediaImage == null) { proxy.close(); return@setAnalyzer }
                    val image = InputImage.fromMediaImage(
                        mediaImage,
                        proxy.imageInfo.rotationDegrees
                    )
                    scanner.process(image)
                        .addOnSuccessListener { codes ->
                            val payload = codes
                                .firstOrNull { it.format == Barcode.FORMAT_QR_CODE }
                                ?.rawValue
                            if (payload != null && !consumed) {
                                consumed = true
                                onPayload(payload)
                            }
                        }
                        .addOnCompleteListener { proxy.close() }
                }
                val selector = CameraSelector.DEFAULT_BACK_CAMERA
                runCatching {
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(lifecycleOwner, selector, preview, analyzer)
                }.onFailure { Log.w("CameraScanner", "bind failed", it) }
            }, ContextCompat.getMainExecutor(ctx))
            previewView
        }
    )
}
