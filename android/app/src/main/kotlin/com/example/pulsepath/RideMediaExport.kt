package com.example.pulsepath

import android.app.Activity
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID

/** Remux only audio/video samples. Do not copy location/container metadata tracks. */
class RideMediaExport(private val activity: Activity) {
    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, "pulsepath/ride_media").setMethodCallHandler { call, result ->
            if (call.method != "stripVideoMetadata") { result.notImplemented(); return@setMethodCallHandler }
            val path = call.argument<String>("path")
            if (path == null) { result.error("INVALID", "Нет видео", null); return@setMethodCallHandler }
            Thread {
                try {
                    val output = remux(path)
                    activity.runOnUiThread { result.success(output) }
                } catch (_: Exception) {
                    activity.runOnUiThread { result.error("EXPORT_FAILED", "Не удалось подготовить видео без геометаданных. Используйте MP4 с H.264/AAC.", null) }
                }
            }.start()
        }
    }

    private fun remux(path: String): String {
        val source = File(path).canonicalFile
        val privateRoot = File(activity.filesDir, "chat_pending").canonicalFile
        require(source.path.startsWith(privateRoot.path + File.separator))
        require(source.isFile && source.length() in 1..(50L * 1024 * 1024))
        val outputDir = File(activity.cacheDir, "ride_media_exports").apply { mkdirs() }
        val output = File(outputDir, "${UUID.randomUUID()}.mp4")
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        var started = false
        try {
            extractor.setDataSource(source.path)
            val writer = MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = writer
            val tracks = mutableMapOf<Int, Int>()
            var bufferSize = 4 * 1024 * 1024
            var hasVideo = false
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/") && !mime.startsWith("audio/")) continue
                if (mime.startsWith("video/")) hasVideo = true
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    bufferSize = maxOf(bufferSize, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
                tracks[index] = writer.addTrack(format)
                extractor.selectTrack(index)
            }
            require(hasVideo && bufferSize <= 16 * 1024 * 1024)
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(source.path)
                val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()
                if (rotation in listOf(0, 90, 180, 270)) writer.setOrientationHint(rotation!!)
            } finally { retriever.release() }
            writer.start(); started = true
            val buffer = ByteBuffer.allocateDirect(bufferSize)
            val info = MediaCodec.BufferInfo()
            while (true) {
                val sourceTrack = extractor.sampleTrackIndex
                if (sourceTrack < 0) break
                require(extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED == 0)
                buffer.clear()
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                require(size <= bufferSize)
                info.set(0, size, extractor.sampleTime, extractor.sampleFlags)
                writer.writeSampleData(tracks.getValue(sourceTrack), buffer, info)
                extractor.advance()
            }
            writer.stop(); started = false
            require(output.length() in 1..(50L * 1024 * 1024))
            return output.path
        } finally {
            if (started) { try { muxer?.stop() } catch (_: Exception) {} }
            muxer?.release(); extractor.release()
        }
    }
}
