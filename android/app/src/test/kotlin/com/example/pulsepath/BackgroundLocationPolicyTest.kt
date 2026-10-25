package com.example.pulsepath

import org.junit.Assert.*
import org.junit.Test

class BackgroundLocationPolicyTest {
    private val now = 1_800_000_000_000L
    @Test fun freshMeasuredLocationIsAccepted() { assertTrue(BackgroundLocationPolicy.valid(56.4,84.9,20.0,now-1_000,now)) }
    @Test fun oldLocationIsRejected() { assertFalse(BackgroundLocationPolicy.valid(56.4,84.9,20.0,now-181_000,now)) }
    @Test fun futureLocationIsRejected() { assertFalse(BackgroundLocationPolicy.valid(56.4,84.9,20.0,now+31_000,now)) }
    @Test fun inaccurateLocationIsRejected() { assertFalse(BackgroundLocationPolicy.valid(56.4,84.9,301.0,now,now)) }
    @Test fun missingAccuracyIsRejected() { assertFalse(BackgroundLocationPolicy.valid(56.4,84.9,-1.0,now,now)) }
    @Test fun invalidCoordinateIsRejected() { assertFalse(BackgroundLocationPolicy.valid(91.0,84.9,20.0,now,now)) }
    @Test fun nanCoordinateIsRejected() { assertFalse(BackgroundLocationPolicy.valid(Double.NaN,84.9,20.0,now,now)) }
    @Test fun infiniteCoordinateIsRejected() { assertFalse(BackgroundLocationPolicy.valid(56.4,Double.POSITIVE_INFINITY,20.0,now,now)) }
}
