package com.example.pulsepath

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONObject
import java.time.LocalDate
import java.text.NumberFormat

/** Reads only the current account archive; never starts a sensor or a Flutter engine. */
class StepsWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        render(context, manager, ids)
    }
    companion object {
        fun updateAll(context: Context) {
            try {
                val manager = AppWidgetManager.getInstance(context)
                render(context, manager, manager.getAppWidgetIds(ComponentName(context, StepsWidgetProvider::class.java)))
            } catch (error: RuntimeException) {
                // Launcher failures must never interrupt archiving the user's steps.
                android.util.Log.w("StepsWidget", "Cannot update launcher widget", error)
            }
        }
        private fun render(context: Context, manager: AppWidgetManager, ids: IntArray) {
            if (ids.isEmpty()) return
            val prefs = context.getSharedPreferences("step_recording_v1", Context.MODE_PRIVATE)
            val owner = prefs.getString("currentOwner", "") ?: ""
            val state = try { JSONObject(prefs.getString("owner:$owner", null) ?: "{}") } catch (_: Exception) { JSONObject() }
            val day = LocalDate.now().toString()
            val total = if (owner.isEmpty()) 0L else StepRecordingDays.totals(
                readDays(state.optJSONObject("completed")), readDays(state.optJSONObject("session"))
            )[day] ?: 0L
            val active = owner.isNotEmpty() && state.optBoolean("enabled")
            val time = state.optLong("lastSyncedAt")
            val status = if (owner.isEmpty()) "Откройте PulsePath" else if (!active) "Шагомер выключен" else if (time > 0) "Обновлено " + java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(java.util.Date(time)) else "Откройте для обновления"
            val launch = PendingIntent.getActivity(context, 604, Intent(context, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            ids.forEach { id ->
                val views = RemoteViews(context.packageName, R.layout.steps_widget)
                views.setTextViewText(R.id.steps_value, NumberFormat.getIntegerInstance().format(total))
                views.setTextViewText(R.id.steps_status, status)
                views.setTextViewText(R.id.steps_day, "ШАГИ · " + java.time.format.DateTimeFormatter.ofPattern("d MMM", java.util.Locale.getDefault()).format(LocalDate.now()))
                views.setOnClickPendingIntent(R.id.steps_widget_root, launch)
                manager.updateAppWidget(id, views)
            }
        }
        private fun readDays(days: JSONObject?): Map<String, Long> = days?.keys()?.asSequence()?.associateWith { days.optLong(it).coerceAtLeast(0L) } ?: emptyMap()
    }
}
