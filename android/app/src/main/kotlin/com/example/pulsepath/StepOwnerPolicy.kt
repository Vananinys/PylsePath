package com.example.pulsepath

/** Pure boundaries shared by foreground requests and the background worker. */
internal object StepOwnerPolicy {
    fun mayUpdate(owner: String, currentOwner: String?): Boolean =
        currentOwner != null && currentOwner.isNotEmpty() && owner == currentOwner

    fun activeOwners(currentOwner: String?, enabled: List<String>): List<String> =
        enabled.filter { mayUpdate(it, currentOwner) }

    fun queryEnd(requestedEnd: Long, suspendedAt: Long, ownerCutoff: Long): Long =
        listOf(requestedEnd, suspendedAt, ownerCutoff).filter { it > 0 }.minOrNull() ?: requestedEnd
}
