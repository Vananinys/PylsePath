package com.example.pulsepath

import android.app.Activity
import android.os.Build
import android.media.MediaMetadataRetriever
import android.graphics.Bitmap
import android.graphics.Matrix
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.ByteArrayOutputStream
import kotlin.math.max

class VideoPreviewBridge(private val activity: Activity) {
    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, "pulsepath/video_preview").setMethodCallHandler { call, result ->
            if (call.method != "inspect") { result.notImplemented(); return@setMethodCallHandler }
            val path = call.argument<String>("path")
            if (path == null) { result.error("INVALID", "Нет видео", null); return@setMethodCallHandler }
            Thread {
                val retriever = MediaMetadataRetriever()
                try {
                    val file = File(path).canonicalFile
                    require(file.isFile && file.length() in 1..(50L * 1024 * 1024))
                    // Gallery-picker caches and retained drafts are inside app-owned directories.
                    val roots = listOfNotNull(activity.filesDir, activity.cacheDir,
                        activity.externalCacheDir, activity.getExternalFilesDir(null))
                    require(roots.any { file.path.startsWith(it.canonicalPath + File.separator) })
                    retriever.setDataSource(file.path)
                    val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                    val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                    val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                    val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                    val rotated = rotation == 90 || rotation == 270
                    val metadata = hashMapOf<String, Any>("width" to if (rotated) height else width,
                        "height" to if (rotated) width else height, "duration_ms" to duration)
                    val time = minOf(1_000_000L, duration * 500L)
                    val ratio = 512.0 / max(width, height).coerceAtLeast(512)
                    var frame = if (Build.VERSION.SDK_INT >= 27) retriever.getScaledFrameAtTime(
                        time, MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        max(1, (width * ratio).toInt()), max(1, (height * ratio).toInt()))
                    else retriever.getFrameAtTime(time, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    if (frame != null) {
                        if (rotated && ((width > height && frame.width > frame.height) || (height > width && frame.height > frame.width))) {
                            val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
                            val turned = Bitmap.createBitmap(frame, 0, 0, frame.width, frame.height, matrix, true)
                            if (turned !== frame) frame.recycle()
                            frame = turned
                        }
                        val scale = 512.0 / max(frame.width, frame.height).coerceAtLeast(1)
                        val thumb = if (scale < 1) Bitmap.createScaledBitmap(frame,
                            max(1, (frame.width * scale).toInt()), max(1, (frame.height * scale).toInt()), true) else frame
                        val bytes = ByteArrayOutputStream().use { stream ->
                            thumb.compress(Bitmap.CompressFormat.JPEG, 78, stream); stream.toByteArray()
                        }
                        if (thumb !== frame) thumb.recycle()
                        frame.recycle()
                        if (bytes.size <= 512 * 1024) metadata["poster"] = bytes
                    }
                    activity.runOnUiThread { result.success(metadata) }
                } catch (_: Exception) {
                    activity.runOnUiThread { result.error("PREVIEW_FAILED", "Превью недоступно", null) }
                } finally { retriever.release() }
            }.start()
        }
    }
}
