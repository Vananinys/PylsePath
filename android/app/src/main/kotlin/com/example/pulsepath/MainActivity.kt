package com.example.pulsepath

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.Manifest
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.ByteArrayOutputStream
import java.io.InputStream

class MainActivity : FlutterActivity() {
    private var voiceGuidance: VoiceGuidance? = null
    private var networkStatus: NetworkStatusBridge? = null
    private var stepListener: SensorEventListener? = null
    private var gpxImportSink: EventChannel.EventSink? = null
    private var pendingGpxUri: Uri? = null
    private val sensorManager by lazy { getSystemService(SENSOR_SERVICE) as SensorManager }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        networkStatus?.close()
        networkStatus = NetworkStatusBridge(this).also { it.attach(flutterEngine.dartExecutor.binaryMessenger) }
        BackgroundLocationBridge(this).attach(flutterEngine.dartExecutor.binaryMessenger)
        // The legacy sensor channel below stays available for old consumers.
        // Daily activity now uses an independent Play Services subscription.
        StepRecordingBridge(this).attach(flutterEngine.dartExecutor.binaryMessenger)
        voiceGuidance = VoiceGuidance(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pulsepath/voice_guidance")
            .setMethodCallHandler { call, result -> voiceGuidance?.handle(call, result) }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "pulsepath/gpx_import")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    gpxImportSink = events
                    pendingGpxUri?.let { deliverGpx(it) }
                }
                override fun onCancel(arguments: Any?) {
                    gpxImportSink = null
                }
            })
        pendingGpxUri = extractGpxUri(intent)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pulsepath/steps")
            .setMethodCallHandler { call, result ->
                if (call.method == "available") result.success(sensorManager.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) != null)
                else result.notImplemented()
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "pulsepath/step_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    if (Build.VERSION.SDK_INT >= 29 && checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) != PackageManager.PERMISSION_GRANTED) {
                        events.error("PERMISSION", "Разрешите доступ к физической активности", null)
                        return
                    }
                    val sensor = sensorManager.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)
                    if (sensor == null) {
                        events.error("UNAVAILABLE", "Датчик шагов не найден", null)
                        return
                    }
                    stepListener?.let { sensorManager.unregisterListener(it) }
                    val listener = object : SensorEventListener {
                        override fun onSensorChanged(event: SensorEvent) {
                            events.success(mapOf("count" to event.values[0].toLong(), "uptime" to SystemClock.elapsedRealtime(), "at" to (System.currentTimeMillis() - SystemClock.elapsedRealtime() + event.timestamp / 1000000L)))
                        }
                        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
                    }
                    stepListener = listener
                    if (!sensorManager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_NORMAL)) {
                        events.error("UNAVAILABLE", "Не удалось включить датчик шагов", null)
                    }
                }
                override fun onCancel(arguments: Any?) {
                    stepListener?.let { sensorManager.unregisterListener(it) }
                    stepListener = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pulsepath/app_updates")
            .setMethodCallHandler { call, result ->
                if (call.method != "installApk") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val suppliedPath = call.argument<String>("path") ?: ""
                    val updatesDirectory = File(cacheDir, "updates").canonicalFile
                    val apk = File(suppliedPath).canonicalFile
                    if (!apk.path.startsWith(updatesDirectory.path + File.separator) ||
                        !apk.isFile || !apk.name.endsWith(".apk")) {
                        result.error("INVALID_APK", "Invalid update file", null)
                        return@setMethodCallHandler
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        !packageManager.canRequestPackageInstalls()) {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                        result.success("permission_required")
                        return@setMethodCallHandler
                    }
                    val uri = FileProvider.getUriForFile(
                        this, "$packageName.app_updates", apk,
                    )
                    val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(intent)
                    result.success("started")
                } catch (error: Exception) {
                    result.error("INSTALL_FAILED", error.message, null)
                }
            }
    }

    override fun onStart() {
        super.onStart()
        BackgroundLocationRuntime.visible = true
    }

    override fun onStop() {
        BackgroundLocationRuntime.visible = false
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingGpxUri = extractGpxUri(intent)
        pendingGpxUri?.let { deliverGpx(it) }
    }

    private fun extractGpxUri(source: Intent?): Uri? {
        if (source == null) return null
        return when (source.action) {
            Intent.ACTION_VIEW -> source.data
            Intent.ACTION_SEND -> {
                if (Build.VERSION.SDK_INT >= 33) {
                    source.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    source.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
                }
            }
            else -> null
        }
    }

    private fun deliverGpx(uri: Uri) {
        val sink = gpxImportSink ?: return
        try {
            val stream = contentResolver.openInputStream(uri)
                ?: throw IllegalArgumentException("Не удалось открыть GPX-файл")
            val content = stream.use { readLimited(it, 10 * 1024 * 1024) }
            if (content.isEmpty()) throw IllegalArgumentException("GPX-файл пуст")
            pendingGpxUri = null
            sink.success(content)
        } catch (error: Exception) {
            pendingGpxUri = null
            sink.error("GPX_READ_FAILED", error.message ?: "Не удалось прочитать GPX", null)
        }
    }

    private fun readLimited(input: InputStream, maxBytes: Int): String {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        var total = 0
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > maxBytes) throw IllegalArgumentException("GPX-файл слишком большой")
            output.write(buffer, 0, count)
        }
        return output.toString(Charsets.UTF_8.name())
    }

    override fun onDestroy() {
        networkStatus?.close()
        networkStatus = null
        voiceGuidance?.close()
        voiceGuidance = null
        stepListener?.let { sensorManager.unregisterListener(it) }
        stepListener = null
        super.onDestroy()
    }
}
