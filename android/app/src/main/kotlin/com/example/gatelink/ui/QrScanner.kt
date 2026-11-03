package com.example.gatelink.ui

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.camera.core.ImageAnalysis
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.BinaryBitmap
import com.google.zxing.LuminanceSource
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Full-screen camera view that reports the first QR code it sees. Needs the CAMERA permission. */
@Composable
fun QrScannerDialog(onResult: (String) -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val result by rememberUpdatedState(onResult)
    val controller = remember { LifecycleCameraController(context) }

    DisposableEffect(lifecycleOwner) {
        val analysis = Executors.newSingleThreadExecutor()
        val done = AtomicBoolean(false)
        val main = ContextCompat.getMainExecutor(context)
        controller.imageAnalysisBackpressureStrategy = ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST
        controller.setImageAnalysisAnalyzer(analysis) { image ->
            image.use {
                val y = it.planes[0]
                val bytes = ByteArray(y.buffer.remaining()).also { b -> y.buffer.get(b) }
                // The Y plane is the grey image; rowStride can be wider than the frame.
                val source = PlanarYUVLuminanceSource(bytes, y.rowStride, it.height, 0, 0, it.width, it.height, false)
                val text = decodeQr(source)
                if (text != null && done.compareAndSet(false, true)) main.execute { result(text) }
            }
        }
        controller.bindToLifecycle(lifecycleOwner)
        onDispose {
            controller.unbind()
            controller.clearImageAnalysisAnalyzer()
            analysis.shutdown()
        }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            AndroidView({ PreviewView(it).apply { this.controller = controller } }, Modifier.fillMaxSize())
            Column(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(Color.Black.copy(alpha = 0.6f))
                    .navigationBarsPadding().padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Point the camera at the 2FA QR code.", color = Color.White, style = MaterialTheme.typography.bodyLarge)
                Button(onClick = onDismiss) { Text("Cancel") }
            }
        }
    }
}

/** The QR code payload in an image the user picked. */
fun readQr(context: Context, uri: Uri): String {
    val bitmap = context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
        ?: throw IllegalArgumentException("Could not open that image.")
    val pixels = IntArray(bitmap.width * bitmap.height)
    bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
    return decodeQr(RGBLuminanceSource(bitmap.width, bitmap.height, pixels))
        ?: throw IllegalArgumentException("No QR code found in the image.")
}

private fun decodeQr(source: LuminanceSource): String? = try {
    QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source))).text
} catch (e: Exception) {
    null
}
