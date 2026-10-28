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
open class StepsWidgetProvider : AppWidgetProvider() {
    protected open val widgetLayout = R.layout.steps_widget
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        render(context, manager, ids, widgetLayout)
    }
    companion object {
        fun updateAll(context: Context) {
            try {
                val manager = AppWidgetManager.getInstance(context)
                val variants = listOf(
                    StepsWidgetProvider::class.java to R.layout.steps_widget,
                    MiniStepsWidgetProvider::class.java to R.layout.steps_widget_mini,
                    StripStepsWidgetProvider::class.java to R.layout.steps_widget_strip,
                    WeekStepsWidgetProvider::class.java to R.layout.steps_widget_week,
                )
                variants.forEach { (provider, layout) ->
                    render(context, manager, manager.getAppWidgetIds(ComponentName(context, provider)), layout)
                }
            } catch (error: RuntimeException) {
                // Launcher failures must never interrupt archiving the user's steps.
                android.util.Log.w("StepsWidget", "Cannot update launcher widget", error)
            }
        }
        private fun render(context: Context, manager: AppWidgetManager, ids: IntArray, layout: Int) {
            if (ids.isEmpty()) return
            val prefs = context.getSharedPreferences("step_recording_v1", Context.MODE_PRIVATE)
            val owner = prefs.getString("currentOwner", "") ?: ""
            val state = try { JSONObject(prefs.getString("owner:$owner", null) ?: "{}") } catch (_: Exception) { JSONObject() }
            val day = LocalDate.now().toString()
            val total = if (owner.isEmpty()) 0L else StepRecordingDays.totals(
                readDays(state.optJSONObject("completed")), readDays(state.optJSONObject("session"))
            )[day] ?: 0L
            val days = if (owner.isEmpty()) emptyMap() else StepRecordingDays.totals(
                readDays(state.optJSONObject("completed")), readDays(state.optJSONObject("session"))
            )
            val active = owner.isNotEmpty() && state.optBoolean("enabled")
            val time = state.optLong("lastSyncedAt")
            val status = if (owner.isEmpty()) "Откройте PulsePath" else if (!active) "Шагомер выключен" else if (time > 0) "Обновлено " + java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(java.util.Date(time)) else "Откройте для обновления"
            val launch = PendingIntent.getActivity(context, 604, Intent(context, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            ids.forEach { id ->
                val views = RemoteViews(context.packageName, layout)
                views.setTextViewText(R.id.steps_value, NumberFormat.getIntegerInstance().format(total))
                views.setTextViewText(R.id.steps_status, status)
                views.setTextViewText(R.id.steps_day, "ШАГИ · " + java.time.format.DateTimeFormatter.ofPattern("d MMM", java.util.Locale.getDefault()).format(LocalDate.now()))
                if (layout == R.layout.steps_widget_mini) {
                    views.setTextViewText(R.id.steps_day, if (active) "ШАГИ" else "ВЫКЛ.")
                }
                views.setContentDescription(R.id.steps_widget_root, "PulsePath. $total шагов за сегодня. $status")
                if (layout == R.layout.steps_widget_week) {
                    val dates = (6 downTo 0).map { LocalDate.now().minusDays(it.toLong()) }
                    val counts = dates.map { days[it.toString()] ?: 0L }
                    val peak = (counts.maxOrNull() ?: 0L).coerceAtLeast(1L)
                    val labels = intArrayOf(R.id.week_day_0, R.id.week_day_1, R.id.week_day_2, R.id.week_day_3, R.id.week_day_4, R.id.week_day_5, R.id.week_day_6)
                    val bars = intArrayOf(R.id.week_bar_0, R.id.week_bar_1, R.id.week_bar_2, R.id.week_bar_3, R.id.week_bar_4, R.id.week_bar_5, R.id.week_bar_6)
                    dates.indices.forEach { index ->
                        val caption = java.time.format.DateTimeFormatter.ofPattern("EE", java.util.Locale.getDefault()).format(dates[index])
                        views.setTextViewText(labels[index], "$caption\n${NumberFormat.getIntegerInstance().format(counts[index])}")
                        views.setProgressBar(bars[index], 100, (counts[index] * 100 / peak).toInt(), false)
                    }
                    views.setTextViewText(R.id.week_total, "За 7 дней · ${NumberFormat.getIntegerInstance().format(counts.sum())} шагов")
                }
                views.setOnClickPendingIntent(R.id.steps_widget_root, launch)
                manager.updateAppWidget(id, views)
            }
        }
        private fun readDays(days: JSONObject?): Map<String, Long> = days?.keys()?.asSequence()?.associateWith { days.optLong(it).coerceAtLeast(0L) } ?: emptyMap()
    }
}

class MiniStepsWidgetProvider : StepsWidgetProvider() {
    override val widgetLayout = R.layout.steps_widget_mini
}

class StripStepsWidgetProvider : StepsWidgetProvider() {
    override val widgetLayout = R.layout.steps_widget_strip
}

class WeekStepsWidgetProvider : StepsWidgetProvider() {
    override val widgetLayout = R.layout.steps_widget_week
}
