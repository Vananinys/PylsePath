package com.example.pulsepath

import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime

class StepRecordingDaysTest {
    private val zone = ZoneId.of("Asia/Tomsk")
    private fun time(value: String) = ZonedDateTime.parse(value).toInstant().toEpochMilli()

    @Test fun startsAtOptInNotAtMidnight() {
        val start = time("2026-10-21T15:23:00+07:00")
        val end = time("2026-10-21T16:00:00+07:00")
        val result = StepRecordingDays.windows(start, end, zone)
        assertEquals(listOf(StepDayWindow("2026-10-21", start, end)), result)
    }

    @Test fun separatesMidnightAndUsesLocalDates() {
        val result = StepRecordingDays.windows(time("2026-10-21T23:50:00+07:00"), time("2026-10-22T00:10:00+07:00"), zone)
        assertEquals(listOf("2026-10-21", "2026-10-22"), result.map { it.day })
        assertEquals(result[0].end, result[1].start)
    }

    @Test fun honorsShortDayDuringDaylightSavingChange() {
        val result = StepRecordingDays.windows(time("2026-03-29T00:00:00+01:00"), time("2026-03-30T00:00:00+02:00"), ZoneId.of("Europe/Berlin"))
        assertEquals(23L * 60 * 60 * 1000, result.single().end - result.single().start)
    }

    @Test fun honorsLongDayDuringDaylightSavingChange() {
        val result = StepRecordingDays.windows(time("2026-10-25T00:00:00+02:00"), time("2026-10-26T00:00:00+01:00"), ZoneId.of("Europe/Berlin"))
        assertEquals(25L * 60 * 60 * 1000, result.single().end - result.single().start)
    }

    @Test fun neverQueriesExpiredHistoryAsAPartialDay() {
        val result = StepRecordingDays.windows(time("2026-09-01T00:00:00+07:00"), time("2026-10-21T15:00:00+07:00"), zone)
        assertEquals(10, result.size)
        assertEquals("2026-10-12", result.first().day)
    }

    @Test fun futureStartReturnsNoWindows() {
        assertTrue(StepRecordingDays.windows(5000L, 3000L, zone).isEmpty())
    }

    @Test fun repeatedSnapshotsDoNotDoubleCount() {
        val old = mapOf("2026-10-21" to 150L)
        val result = StepRecordingDays.mergeSnapshot(old, old)
        assertEquals(150L, result["2026-10-21"])
    }

    @Test fun delayedEmptyReadDoesNotEraseSavedSteps() {
        val result = StepRecordingDays.mergeSnapshot(mapOf("2026-10-21" to 150L), mapOf("2026-10-21" to 0L))
        assertEquals(150L, result["2026-10-21"])
    }

    @Test fun expiredAndCompletedDaysAreRetained() {
        val result = StepRecordingDays.mergeSnapshot(mapOf("2026-09-01" to 500L), mapOf("2026-10-21" to 300L))
        assertEquals(500L, result["2026-09-01"])
        assertEquals(300L, result["2026-10-21"])
    }

    @Test fun migrationAndEnableSessionsAreAddedExactlyOnce() {
        val migrated = mapOf("2026-10-21" to 1200L)
        val firstSession = mapOf("2026-10-21" to 300L)
        val completed = StepRecordingDays.totals(migrated, firstSession)
        assertEquals(1500L, completed["2026-10-21"])
        assertEquals(1550L, StepRecordingDays.totals(completed, mapOf("2026-10-21" to 50L))["2026-10-21"])
    }

    @Test fun cloudRestoreRebasesCompletedArchiveWithoutDuplicatingSession() {
        val day = "2026-10-22"
        val session = mapOf(day to 300L)
        val completed = StepRecordingDays.restoreArchive(mapOf(day to 100L), session, mapOf(day to 1000L))
        assertEquals(700L, completed[day])
        assertEquals(1000L, StepRecordingDays.totals(completed, session)[day])
        assertEquals(completed, StepRecordingDays.restoreArchive(completed, session, mapOf(day to 1000L)))
        assertEquals(1100L, StepRecordingDays.totals(completed, mapOf(day to 400L))[day])
    }

    @Test fun olderCloudArchiveNeverReducesNativeSteps() {
        val completed = mapOf("2026-10-22" to 1000L)
        assertEquals(completed, StepRecordingDays.restoreArchive(completed, emptyMap(), mapOf("2026-10-22" to 10L)))
    }
}
