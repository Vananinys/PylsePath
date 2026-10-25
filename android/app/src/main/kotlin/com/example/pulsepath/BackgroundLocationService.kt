package com.example.pulsepath

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.AtomicFile
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.location.LocationAvailability
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.time.Instant
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/** Process-level flags, independent of the Flutter engine. */
object BackgroundLocationRuntime {
    @Volatile var visible = false
    @Volatile var running = false
}

/** Stored only in noBackupFilesDir: neither coordinates nor credentials enter cloud backups. */
internal object BackgroundLocationState {
    private val lock = Any()
    private fun file(context: Context) = AtomicFile(File(context.noBackupFilesDir, "background_location.json"))
    fun read(context: Context): JSONObject = synchronized(lock) {
        try { file(context).openRead().bufferedReader().use { JSONObject(it.readText()) } }
        catch (_: Exception) { JSONObject() }
    }
    fun update(context: Context, change: (JSONObject) -> Unit): JSONObject = synchronized(lock) {
        val state = read(context)
        change(state)
        val target = file(context)
        val stream = target.startWrite()
        try {
            stream.write(state.toString().toByteArray(Charsets.UTF_8))
            target.finishWrite(stream)
        } catch (error: Exception) { target.failWrite(stream); throw error }
        state
    }
    fun precise(context: Context) = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
    fun background(context: Context) = Build.VERSION.SDK_INT < 29 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
    fun locationEnabled(context: Context) = LocationManagerCompat.isLocationEnabled(
        context.getSystemService(Context.LOCATION_SERVICE) as android.location.LocationManager)
    fun services(context: Context) = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS
    fun snapshot(context: Context): Map<String, Any> {
        val original = read(context)
        val state = if (original.optString("deviceId").isEmpty()) update(context) {
            if (it.optString("deviceId").isEmpty()) it.put("deviceId", java.util.UUID.randomUUID().toString())
        } else original
        return mapOf(
            "deviceId" to state.getString("deviceId"),
            "owner" to state.optString("owner"), "enabled" to state.optBoolean("enabled"),
            "running" to BackgroundLocationRuntime.running, "expiresAt" to state.optLong("expiresAt"),
            "lastFixAt" to state.optLong("lastFixAt"), "lastPublishedAt" to state.optLong("lastPublishedAt"),
            "notice" to state.optString("notice"), "precisePermission" to precise(context),
            "backgroundPermission" to background(context), "locationEnabled" to locationEnabled(context),
            "servicesAvailable" to services(context),
        )
    }
    fun stop(context: Context, expectedOwner: String? = null) {
        var changed = false
        update(context) { state ->
            if (expectedOwner != null && state.optString("owner") != expectedOwner) return@update
            changed = true
            val token = state.optString("token")
            val queue = state.optJSONArray("revocations") ?: JSONArray()
            if (token.isNotEmpty() && (0 until queue.length()).none { queue.getJSONObject(it).optString("token") == token }) {
                queue.put(JSONObject().put("token", token).put("url", state.optString("url")).put("apiKey", state.optString("apiKey")))
            }
            state.put("revocations", queue).put("enabled", false).put("token", "").put("pending", JSONObject()).put("notice", "")
        }
        if (changed) {
            context.stopService(Intent(context, BackgroundLocationService::class.java))
            revokeLater(context)
        }
    }
    fun revokeLater(context: Context) {
        if ((read(context).optJSONArray("revocations")?.length() ?: 0) == 0) return
        val request = OneTimeWorkRequestBuilder<BackgroundLocationRevokeWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build()
        WorkManager.getInstance(context).enqueueUniqueWork("pulsepath-location-revoke", ExistingWorkPolicy.KEEP, request)
    }
}

internal class LocationHttpError(val status: Int) : Exception("Location request failed ($status)")
internal object LocationRpc {
    fun post(config: JSONObject, method: String, body: JSONObject): JSONObject {
        val base = URI(config.getString("url"))
        require(base.scheme == "https" && base.host != null && base.userInfo == null && base.rawQuery == null && base.rawFragment == null)
        val url = URI(base.toString().trimEnd('/') + "/rest/v1/rpc/" + method).toURL()
        val connection = url.openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 10_000
            connection.readTimeout = 10_000
            connection.instanceFollowRedirects = false
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            val key = config.getString("apiKey")
            connection.setRequestProperty("apikey", key)
            // New publishable keys are not JWTs and must not be sent as bearer JWTs.
            if (key.startsWith("eyJ")) connection.setRequestProperty("Authorization", "Bearer $key")
            connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            if (connection.responseCode !in 200..299) throw LocationHttpError(connection.responseCode)
            val text = connection.inputStream.bufferedReader().use { it.readText() }
            return if (text.isBlank()) JSONObject() else JSONObject(text)
        } finally { connection.disconnect() }
    }
}

class BackgroundLocationBridge(private val activity: Activity) {
    fun attach(messenger: BinaryMessenger) {
        val context = activity.applicationContext
        MethodChannel(messenger, "pulsepath/background_location").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "status" -> result.success(BackgroundLocationState.snapshot(context))
                    "stop" -> {
                        BackgroundLocationState.stop(context, call.argument<String>("owner"))
                        result.success(BackgroundLocationState.snapshot(context))
                    }
                    "start" -> {
                        val owner = call.argument<String>("owner") ?: error("Missing owner")
                        check(BackgroundLocationState.precise(context)) { "PRECISE_PERMISSION" }
                        check(BackgroundLocationState.background(context)) { "BACKGROUND_PERMISSION" }
                        check(BackgroundLocationState.locationEnabled(context)) { "LOCATION_DISABLED" }
                        check(BackgroundLocationState.services(context)) { "PLAY_SERVICES" }
                        val previous = BackgroundLocationState.read(context)
                        if (previous.optString("owner").isNotEmpty() && previous.optString("owner") != owner) {
                            BackgroundLocationState.stop(context)
                        }
                        BackgroundLocationState.update(context) { state ->
                            val token = call.argument<String>("token")
                            if (token != null) {
                                require(token.length == 72)
                                state.put("token", token).put("expiresAt", call.argument<Number>("expiresAt")!!.toLong())
                                    .put("url", call.argument<String>("url")).put("apiKey", call.argument<String>("apiKey"))
                            }
                            check(state.optString("token").length == 72 && state.optLong("expiresAt") > System.currentTimeMillis()) { "CREDENTIAL_EXPIRED" }
                            if (!state.optBoolean("enabled") || state.optString("owner") != owner) {
                                state.put("enabledSince", System.currentTimeMillis()).put("pending", JSONObject())
                                    .put("lastFixAt", 0L).put("lastPublishedAt", 0L)
                            }
                            state.put("owner", owner).put("enabled", true).put("notice", "")
                        }
                        try {
                            ContextCompat.startForegroundService(context, Intent(context, BackgroundLocationService::class.java))
                        } catch (error: Exception) {
                            BackgroundLocationState.stop(context, owner)
                            throw error
                        }
                        result.success(BackgroundLocationState.snapshot(context))
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("BACKGROUND_LOCATION", error.message ?: "Cannot start background location", null)
            }
        }
    }
}

class BackgroundLocationService : Service() {
    private val client by lazy { LocationServices.getFusedLocationProviderClient(this) }
    private val executor = Executors.newSingleThreadExecutor()
    private val uploading = AtomicBoolean(false)
    private var lastAttempt = 0L
    private var lastPreciseAttempt = 0L
    private var preciseRequest: CancellationTokenSource? = null
    @Volatile private var destroyed = false
    private var networkRegistered = false
    private val connectivity by lazy { getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager }
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { flush() }
    }
    private val callback = object : LocationCallback() {
        override fun onLocationAvailability(value: LocationAvailability) {
            if (destroyed || !BackgroundLocationState.read(this@BackgroundLocationService).optBoolean("enabled")) return
            if (!value.isLocationAvailable) {
                BackgroundLocationState.update(this@BackgroundLocationService) { it.put("notice", "Ожидаем свежую геопозицию. Последняя известная точка сохраняется.") }
                requestPreciseFix()
            }
        }
        override fun onLocationResult(result: LocationResult) {
            result.locations.maxByOrNull { it.time }?.let { receive(it) }
        }
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val state = BackgroundLocationState.read(this)
        if (!state.optBoolean("enabled") || state.optLong("expiresAt") <= System.currentTimeMillis() ||
            !BackgroundLocationState.precise(this) || !BackgroundLocationState.background(this)) {
            BackgroundLocationState.update(this) { it.put("notice", "Откройте настройки PulsePath и проверьте доступ к местоположению.") }
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Фоновое местоположение", NotificationManager.IMPORTANCE_LOW))
            val open = PendingIntent.getActivity(this, 7210, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val stop = PendingIntent.getBroadcast(this, 7211, Intent(this, BackgroundLocationReceiver::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val notification = NotificationCompat.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_pulsepath).setContentTitle("PulsePath — местоположение для друзей")
                .setContentText("Фоновое обновление · экономный режим").setContentIntent(open)
                .setOngoing(true).setOnlyAlertOnce(true).setCategory(NotificationCompat.CATEGORY_SERVICE)
                .addAction(0, "Остановить", stop).build()
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            else startForeground(NOTIFICATION, notification)
            BackgroundLocationRuntime.running = true
            client.removeLocationUpdates(callback)
            val request = LocationRequest.Builder(Priority.PRIORITY_BALANCED_POWER_ACCURACY, BackgroundLocationPolicy.INTERVAL_MS)
                .setMinUpdateIntervalMillis(BackgroundLocationPolicy.MIN_INTERVAL_MS)
                .setMinUpdateDistanceMeters(BackgroundLocationPolicy.DISTANCE_METERS)
                .setMaxUpdateDelayMillis(BackgroundLocationPolicy.INTERVAL_MS)
                .setWaitForAccurateLocation(false).build()
            client.requestLocationUpdates(request, callback, Looper.getMainLooper()).addOnFailureListener {
                BackgroundLocationState.update(this) { state -> state.put("notice", "Не удалось подключить фоновую геолокацию. Проверьте разрешения в настройках телефона.") }
                stopSelf()
            }
            if (!networkRegistered) {
                connectivity.registerDefaultNetworkCallback(networkCallback)
                networkRegistered = true
            }
            BackgroundLocationState.revokeLater(this)
        } catch (_: Exception) {
            BackgroundLocationState.update(this) { it.put("notice", "Фоновая геолокация приостановлена системой. Откройте PulsePath, чтобы возобновить.") }
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }
    private fun receive(location: Location) {
        if (destroyed) return
        val now = System.currentTimeMillis()
        if (!location.hasAccuracy() || !BackgroundLocationPolicy.valid(location.latitude, location.longitude, location.accuracy.toDouble(), location.time, now)) {
            requestPreciseFix()
            return
        }
        BackgroundLocationState.update(this) { state ->
            if (!state.optBoolean("enabled") || location.time < state.optLong("enabledSince")) return@update
            val point = JSONObject().put("latitude", location.latitude).put("longitude", location.longitude)
                .put("accuracy", location.accuracy.toDouble()).put("recordedAt", location.time)
            state.put("lastFixAt", location.time).put("pending", point).put("notice", "")
        }
        // The map/workout already publishes high-quality fixes while visible.
        if (!BackgroundLocationRuntime.visible) flush()
    }
    private fun requestPreciseFix() {
        val now = System.currentTimeMillis()
        if (destroyed || BackgroundLocationRuntime.visible || now-lastPreciseAttempt < 180_000L ||
            !BackgroundLocationState.read(this).optBoolean("enabled") || !BackgroundLocationState.locationEnabled(this)) return
        lastPreciseAttempt = now
        preciseRequest?.cancel()
        val cancellation = CancellationTokenSource()
        preciseRequest = cancellation
        try {
            val request = CurrentLocationRequest.Builder().setPriority(Priority.PRIORITY_HIGH_ACCURACY)
                .setMaxUpdateAgeMillis(0).setDurationMillis(10_000L).build()
            client.getCurrentLocation(request, cancellation.token).addOnSuccessListener { location ->
                if (location != null && !destroyed) receive(location)
            }.addOnFailureListener { /* Preserve the last measured position. */ }
        } catch (_: SecurityException) { }
    }
    private fun flush() {
        if (destroyed || executor.isShutdown || BackgroundLocationRuntime.visible || !uploading.compareAndSet(false, true)) return
        try { executor.execute {
            var uploadingToken: String? = null
            try {
                val state = BackgroundLocationState.read(this)
                val point = state.optJSONObject("pending") ?: return@execute
                val now = System.currentTimeMillis()
                if (!state.optBoolean("enabled") || now-lastAttempt < BackgroundLocationPolicy.MIN_INTERVAL_MS ||
                    !BackgroundLocationPolicy.valid(point.optDouble("latitude"), point.optDouble("longitude"), point.optDouble("accuracy"), point.optLong("recordedAt"), now)) return@execute
                lastAttempt = now
                val token = state.getString("token")
                uploadingToken = token
                val response = LocationRpc.post(state, "pulsepath_publish_background_location", JSONObject()
                    .put("p_token", token).put("p_latitude", point.getDouble("latitude"))
                    .put("p_longitude", point.getDouble("longitude")).put("p_accuracy", point.getDouble("accuracy"))
                    .put("p_recorded_at", Instant.ofEpochMilli(point.getLong("recordedAt")).toString()))
                BackgroundLocationState.update(this) { current ->
                    if (current.optString("token") == token && current.optBoolean("enabled")) {
                        if (response.optBoolean("accepted")) current.put("lastPublishedAt", point.getLong("recordedAt"))
                        current.put("notice", "")
                    }
                }
            } catch (error: Exception) {
                if (uploadingToken != BackgroundLocationState.read(this).optString("token")) return@execute
                if (error is LocationHttpError && error.status in listOf(401, 403)) {
                    BackgroundLocationState.stop(this)
                    BackgroundLocationState.update(this) { it.put("notice", "Доступ к фоновой передаче истёк. Включите её снова в настройках PulsePath.") }
                } else {
                    BackgroundLocationState.update(this) { it.put("notice", "Нет связи с сервером. Передадим свежую позицию после восстановления сети.") }
                }
            } finally { uploading.set(false) }
        } } catch (_: RejectedExecutionException) { uploading.set(false) }
    }
    override fun onDestroy() {
        destroyed = true
        preciseRequest?.cancel()
        BackgroundLocationRuntime.running = false
        try { client.removeLocationUpdates(callback) } catch (_: Exception) { }
        if (networkRegistered) try { connectivity.unregisterNetworkCallback(networkCallback) } catch (_: Exception) { }
        executor.shutdown()
        super.onDestroy()
    }
    companion object {
        const val ACTION_STOP = "com.example.pulsepath.STOP_BACKGROUND_LOCATION"
        private const val CHANNEL = "background_location_sharing"
        private const val NOTIFICATION = 7210
    }
}

class BackgroundLocationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == BackgroundLocationService.ACTION_STOP) {
            BackgroundLocationState.stop(context)
            return
        }
        if (intent.action !in listOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) return
        val state = BackgroundLocationState.read(context)
        BackgroundLocationState.revokeLater(context)
        if (state.optBoolean("enabled") && state.optLong("expiresAt") > System.currentTimeMillis() &&
            BackgroundLocationState.precise(context) && BackgroundLocationState.background(context)) {
            try { ContextCompat.startForegroundService(context, Intent(context, BackgroundLocationService::class.java)) }
            catch (_: Exception) { BackgroundLocationState.update(context) { it.put("notice", "Откройте PulsePath, чтобы возобновить фоновую геолокацию.") } }
        }
    }
}

class BackgroundLocationRevokeWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    override fun doWork(): Result {
        val queue = BackgroundLocationState.read(applicationContext).optJSONArray("revocations") ?: return Result.success()
        for (index in 0 until queue.length()) {
            val entry = queue.getJSONObject(index)
            try {
                LocationRpc.post(entry, "pulsepath_stop_background_location", JSONObject().put("p_token", entry.getString("token")))
            } catch (error: Exception) {
                if (error !is LocationHttpError || error.status !in listOf(401,403)) return Result.retry()
            }
            BackgroundLocationState.update(applicationContext) { state ->
                val pending = state.optJSONArray("revocations") ?: JSONArray()
                val remaining = JSONArray()
                for (i in 0 until pending.length()) if (pending.getJSONObject(i).optString("token") != entry.optString("token")) remaining.put(pending.getJSONObject(i))
                state.put("revocations", remaining)
            }
        }
        return if ((BackgroundLocationState.read(applicationContext).optJSONArray("revocations")?.length() ?: 0) > 0) Result.retry() else Result.success()
    }
}
