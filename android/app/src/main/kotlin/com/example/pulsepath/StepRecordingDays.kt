package com.example.pulsepath

import java.time.Instant
import java.time.ZoneId

data class StepDayWindow(val day: String, val start: Long, val end: Long)

/** Calendar boundaries, including 23/25-hour days. Never query an expired partial day. */
object StepRecordingDays {
    /** Rebase a restored archive without counting the active recording twice. */
    fun restoreArchive(completed: Map<String, Long>, session: Map<String, Long>,
        restored: Map<String, Long>): Map<String, Long> = completed.toMutableMap().apply {
        restored.forEach { (day, target) ->
            val current = (this[day] ?: 0L) + (session[day] ?: 0L)
            if (target > current) this[day] = (this[day] ?: 0L) + target - current
        }
    }
    fun windows(since: Long, now: Long, zone: ZoneId): List<StepDayWindow> {
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        val first = maxOf(
            Instant.ofEpochMilli(since).atZone(zone).toLocalDate(), today.minusDays(9),
        )
        val result = mutableListOf<StepDayWindow>()
        var day = first
        while (!day.isAfter(today)) {
            val start = maxOf(since, day.atStartOfDay(zone).toInstant().toEpochMilli())
            val end = minOf(now, day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli())
            if (end > start) result.add(StepDayWindow(day.toString(), start, end))
            day = day.plusDays(1)
        }
        return result
    }

    /** A read is a session total, not a delta. Re-reading must not add steps twice. */
    fun mergeSnapshot(previous: Map<String, Long>, readings: Map<String, Long>): Map<String, Long> =
        previous.toMutableMap().apply {
            readings.forEach { (day, value) -> this[day] = maxOf(this[day] ?: 0L, value.coerceAtLeast(0L)) }
        }

    fun totals(completed: Map<String, Long>, session: Map<String, Long>): Map<String, Long> =
        (completed.keys + session.keys).associateWith { day ->
            (completed[day] ?: 0L) + (session[day] ?: 0L)
        }
}
