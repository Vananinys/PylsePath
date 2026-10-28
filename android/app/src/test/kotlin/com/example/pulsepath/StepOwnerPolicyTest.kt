package com.example.pulsepath

import org.junit.Assert.*
import org.junit.Test

class StepOwnerPolicyTest {
    @Test fun logoutLeavesNoActiveOwners() {
        assertTrue(StepOwnerPolicy.activeOwners(null, listOf("a", "b")).isEmpty())
        assertTrue(StepOwnerPolicy.activeOwners("", listOf("a", "b")).isEmpty())
    }

    @Test fun workerUpdatesOnlyBoundAccount() {
        assertEquals(listOf("b"), StepOwnerPolicy.activeOwners("b", listOf("a", "b")))
        assertFalse(StepOwnerPolicy.mayUpdate("a", "b"))
    }

    @Test fun delayedQueryNeverExtendsBeyondLogout() {
        assertEquals(100L, StepOwnerPolicy.queryEnd(200L, 150L, 100L))
        assertEquals(90L, StepOwnerPolicy.queryEnd(90L, 150L, 100L))
    }

    @Test fun ordinarySessionUsesRequestedEnd() {
        assertEquals(200L, StepOwnerPolicy.queryEnd(200L, 0L, 0L))
    }
}
