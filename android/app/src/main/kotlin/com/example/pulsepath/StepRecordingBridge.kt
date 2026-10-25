package com.example.pulsepath

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.fitness.FitnessLocal
import com.google.android.gms.fitness.LocalRecordingClient
import com.google.android.gms.fitness.data.LocalDataType
import com.google.android.gms.fitness.data.LocalField
import com.google.android.gms.fitness.request.LocalDataReadRequest
import com.google.android.gms.tasks.Tasks
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.time.ZoneId
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** No Flutter engine, GPS, sensor listener or wake lock is kept alive for counting. */
class StepRecordingBridge(private val activity: Activity) {
    fun attach(messenger: BinaryMessenger) {
        val context = activity.applicationContext
        MethodChannel(messenger, "pulsepath/step_recording").setMethodCallHandler { call, result ->
            if (call.method == "resolveServices") {
                val api = GoogleApiAvailability.getInstance()
                val code = StepRecordingStore.servicesCode(context)
                if (code != ConnectionResult.SUCCESS && api.isUserResolvableError(code)) {
                    api.getErrorDialog(activity, code, 7013)?.show()
                }
                result.success(null)
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val value: Any? = synchronized(StepRecordingStore.lock) {
                        when (call.method) {
                            "status" -> StepRecordingStore.status(context)
                            "initialize", "refresh", "setEnabled", "workoutSteps" -> {
                                val owner = call.argument<String>("owner")
                                    ?: throw IllegalArgumentException("Missing activity owner")
                                val store = StepRecordingStore(context, owner)
                                when (call.method) {
                                    "initialize" -> store.initialize(
                                        call.argument<Map<String, Number>>("seedDays") ?: emptyMap(),
                                        call.argument<Boolean>("legacyEnabled") == true,
                                    )
                                    "setEnabled" -> store.setEnabled(call.argument<Boolean>("enabled") == true)
                                    "workoutSteps" -> store.workoutSteps(call.argument<List<Map<String, Number>>>("windows") ?: emptyList())
                                    else -> store.refresh()
                                }
                            }
                            else -> null
                        }
                    }
                    main.post {
                        if (call.method in setOf("status", "initialize", "refresh", "setEnabled", "workoutSteps")) {
                            result.success(value)
                        } else result.notImplemented()
                    }
                } catch (error: Exception) {
                    val cause = error.cause ?: error
                    val code = when (cause) {
                        is SecurityException -> "PERMISSION"
                        is StepRecordingUnavailable -> "PLAY_SERVICES"
                        is ApiException -> "RECORDING_${cause.statusCode}"
                        else -> "RECORDING_FAILED"
                    }
                    main.post { result.error(code, cause.message, null) }
                }
            }
        }
    }

    companion object {
        private val executor = Executors.newSingleThreadExecutor()
        private val main = Handler(Looper.getMainLooper())
    }
}

private class StepRecordingUnavailable : IllegalStateException("Google Play Services unavailable")

/** Durable, account-scoped archives; all access is serialized with background checkpoints. */
internal class StepRecordingStore(private val context: Context, private val owner: String) {
    private val prefs = context.getSharedPreferences("step_recording_v1", Context.MODE_PRIVATE)
    private val key = "owner:$owner"
    private val client get() = FitnessLocal.getLocalRecordingClient(context)
    private var state = JSONObject(prefs.getString(key, null) ?: "{}")

    fun initialize(seed: Map<String, Number>, legacyEnabled: Boolean): Map<String, Any> {
        if (!prefs.contains(key)) {
            state.put("completed", JSONObject(seed))
            state.put("session", JSONObject())
            state.put("enabled", false)
            save()
            if (legacyEnabled && hasPermission(context)) return setEnabled(true)
        }
        state.put("completed", JSONObject(StepRecordingDays.restoreArchive(
            map("completed"), map("session"), seed.mapValues { it.value.toLong().coerceIn(0L, 500000L) })))
        save()
        return refresh()
    }

    fun setEnabled(enabled: Boolean): Map<String, Any> {
        if (enabled) {
            requireAvailable()
            if (!hasPermission(context)) throw SecurityException("Activity recognition permission required")
            // Idempotent: an existing subscription is not reset on app start.
            Tasks.await(client.subscribe(LocalDataType.TYPE_STEP_COUNT_DELTA), 30, TimeUnit.SECONDS)
            if (!state.optBoolean("enabled")) {
                state.put("activeSince", System.currentTimeMillis())
                state.put("session", JSONObject())
            }
            state.put("enabled", true)
            save()
            prefs.edit().putBoolean("unsubscribePending", false).commit()
            schedule(context)
            return refresh()
        }
        // Archive before unsubscribing: Google removes access to its data on unsubscribe.
        var archiveError: Exception? = null
        if (state.optBoolean("enabled")) {
            try { readSession() } catch (error: Exception) { archiveError = error }
            state.put("completed", JSONObject(totals()))
            state.put("session", JSONObject())
        }
        state.put("enabled", false)
        save()
        if (enabledOwners(context).isEmpty()) {
            prefs.edit().putBoolean("unsubscribePending", true).commit()
            cleanupSubscription(context)
        }
        return snapshot().apply {
            if (archiveError != null) put("warning", "Последние шаги перед выключением могли не сохраниться. Ранее сохранённая история доступна.")
            if (prefs.getBoolean("unsubscribePending", false)) put("warning", "Остановка системного счётчика отложена. Повторим автоматически, когда сервисы Google Play будут доступны.")
        }
    }

    fun refresh(): Map<String, Any> {
        if (state.optBoolean("enabled")) {
            requireAvailable()
            if (!hasPermission(context)) throw SecurityException("Activity recognition permission required")
            Tasks.await(client.subscribe(LocalDataType.TYPE_STEP_COUNT_DELTA), 30, TimeUnit.SECONDS)
            schedule(context)
            readSession()
        } else if (enabledOwners(context).isEmpty()) {
            cleanupSubscription(context)
        }
        return snapshot()
    }

    fun workoutSteps(windows: List<Map<String, Number>>): Map<String, Any> {
        requireAvailable()
        if (!hasPermission(context)) throw SecurityException("Activity recognition permission required")
        require(windows.size <= 256) { "Too many walking intervals" }
        val now = System.currentTimeMillis()
        val since = state.optLong("activeSince", now)
        var previousEnd = 0L
        val tasks = windows.map { window ->
            val start = window["start"]?.toLong() ?: throw IllegalArgumentException("Missing interval start")
            val end = window["end"]?.toLong() ?: throw IllegalArgumentException("Missing interval end")
            require(start >= previousEnd && end >= start && end <= now + 1000) { "Invalid walking interval" }
            previousEnd = end
            val from = maxOf(start, since)
            if (!state.optBoolean("enabled") || end - from < 2) null else client.readData(LocalDataReadRequest.Builder()
                .aggregate(LocalDataType.TYPE_STEP_COUNT_DELTA).bucketByTime(1, TimeUnit.DAYS)
                .setTimeRange(from, end - 1, TimeUnit.MILLISECONDS).build())
        }
        Tasks.await(Tasks.whenAllComplete(tasks.filterNotNull()), 30, TimeUnit.SECONDS)
        return mapOf("totals" to tasks.map { task ->
            if (task == null) 0L else {
                if (!task.isSuccessful) throw (task.exception ?: IllegalStateException("Steps unavailable"))
                task.result.buckets.sumOf { bucket -> bucket.dataSets.sumOf { data -> data.dataPoints.sumOf { it.getValue(LocalField.FIELD_STEPS).asInt().toLong() } } }
            }
        })
    }

    private fun readSession() {
        val now = System.currentTimeMillis()
        val since = state.optLong("activeSince", now)
        val lastRead = state.optLong("lastSyncedAt")
        val windows = StepRecordingDays.windows(since, now, ZoneId.systemDefault())
            .filter { it.end - it.start > 1 && it.end > lastRead - TimeUnit.MINUTES.toMillis(5) }
        val readings = windows.associate { window ->
            val request = LocalDataReadRequest.Builder()
                .aggregate(LocalDataType.TYPE_STEP_COUNT_DELTA)
                .bucketByTime(1, TimeUnit.DAYS)
                // Query each calendar day separately; a day may have 23 or 25 hours.
                .setTimeRange(window.start, window.end - 1, TimeUnit.MILLISECONDS)
                .build()
            window.day to client.readData(request)
        }
        // Run independent local queries together. Never block the Android main thread.
        Tasks.await(Tasks.whenAllComplete(readings.values), 30, TimeUnit.SECONDS)
        val successful = mutableMapOf<String, Long>()
        var failure: Exception? = null
        readings.forEach { (day, task) ->
            if (task.isSuccessful) {
                successful[day] = task.result.buckets.sumOf { bucket ->
                    bucket.dataSets.sumOf { dataSet ->
                        dataSet.dataPoints.sumOf { it.getValue(LocalField.FIELD_STEPS).asInt().toLong() }
                    }
                }
            } else failure = task.exception ?: IllegalStateException("Steps read cancelled")
        }
        state.put("session", JSONObject(StepRecordingDays.mergeSnapshot(map("session"), successful)))
        if (failure == null) state.put("lastSyncedAt", now)
        save()
        failure?.let { throw it }
    }

    private fun map(field: String): Map<String, Long> {
        val values = state.optJSONObject(field) ?: JSONObject()
        return values.keys().asSequence().associateWith { values.optLong(it).coerceAtLeast(0L) }
    }

    private fun totals() = StepRecordingDays.totals(map("completed"), map("session"))
    private fun snapshot(): MutableMap<String, Any> = mutableMapOf(
        "enabled" to state.optBoolean("enabled"),
        "days" to totals(),
        "lastSyncedAt" to state.optLong("lastSyncedAt"),
    )

    private fun requireAvailable() {
        if (servicesCode(context) != ConnectionResult.SUCCESS) throw StepRecordingUnavailable()
    }

    private fun save() {
        check(prefs.edit().putString(key, state.toString()).commit()) { "Cannot save step archive" }
    }

    companion object {
        val lock = Any()
        private const val WORK_NAME = "pulsepath-step-archive"
        fun cleanupSubscription(context: Context) {
            val prefs = context.getSharedPreferences("step_recording_v1", Context.MODE_PRIVATE)
            if (enabledOwners(context).isNotEmpty()) return
            if (prefs.getBoolean("unsubscribePending", false)) {
                try {
                    if (servicesCode(context) != ConnectionResult.SUCCESS) throw StepRecordingUnavailable()
                    Tasks.await(FitnessLocal.getLocalRecordingClient(context)
                        .unsubscribe(LocalDataType.TYPE_STEP_COUNT_DELTA), 30, TimeUnit.SECONDS)
                    check(prefs.edit().putBoolean("unsubscribePending", false).commit())
                } catch (_: Exception) {
                    schedule(context)
                    return
                }
            }
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        }
        fun servicesCode(context: Context): Int = GoogleApiAvailability.getInstance()
            .isGooglePlayServicesAvailable(context, LocalRecordingClient.LOCAL_RECORDING_CLIENT_STEPS_MIN_VERSION_CODE)

        fun hasPermission(context: Context): Boolean = Build.VERSION.SDK_INT < 29 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACTIVITY_RECOGNITION) == PackageManager.PERMISSION_GRANTED

        fun status(context: Context): Map<String, Any> {
            val code = servicesCode(context)
            return mapOf("available" to (code == ConnectionResult.SUCCESS), "servicesCode" to code,
                "permissionGranted" to hasPermission(context))
        }

        fun enabledOwners(context: Context): List<String> = context
            .getSharedPreferences("step_recording_v1", Context.MODE_PRIVATE).all
            .filter { (key, value) -> key.startsWith("owner:") && value is String && JSONObject(value).optBoolean("enabled") }
            .keys.map { it.removePrefix("owner:") }

        fun schedule(context: Context) {
            // Google collects steps continuously. This only archives its 10-day rolling history.
            val request = PeriodicWorkRequestBuilder<StepRecordingWorker>(6, TimeUnit.HOURS).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}

class StepRecordingWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    override fun doWork(): Result = synchronized(StepRecordingStore.lock) {
        try {
            val owners = StepRecordingStore.enabledOwners(applicationContext)
            if (owners.isEmpty()) StepRecordingStore.cleanupSubscription(applicationContext)
            if (!StepRecordingStore.hasPermission(applicationContext)) return@synchronized Result.success()
            var retry = false
            owners.forEach { owner ->
                try { StepRecordingStore(applicationContext, owner).refresh() }
                catch (_: Exception) { retry = true }
            }
            if (retry && runAttemptCount < 3) Result.retry() else Result.success()
        } catch (_: Exception) {
            if (runAttemptCount < 3) Result.retry() else Result.success()
        }
    }
}
