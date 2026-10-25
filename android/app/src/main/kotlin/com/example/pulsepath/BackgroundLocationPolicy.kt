package com.example.pulsepath

object BackgroundLocationPolicy {
    const val INTERVAL_MS = 60_000L
    const val MIN_INTERVAL_MS = 30_000L
    const val DISTANCE_METERS = 20f
    const val MAX_AGE_MS = 180_000L

    fun valid(latitude: Double, longitude: Double, accuracy: Double, recordedAt: Long, now: Long): Boolean =
        latitude.isFinite() && latitude in -90.0..90.0 &&
        longitude.isFinite() && longitude in -180.0..180.0 &&
        accuracy.isFinite() && accuracy in 0.0..300.0 &&
        recordedAt >= now - MAX_AGE_MS && recordedAt <= now + 30_000L
}
