package com.carriez.flutter_hbb

import java.util.ArrayDeque

internal class SurfaceFrameQueue(private val release: (Int, Boolean) -> Unit) {
    companion object {
        const val MAX_PENDING = 2
    }

    private data class Frame(val index: Int, val timestampNs: Long)
    private val pending = ArrayDeque<Frame>()
    private var inFlight: Long? = null
    val size: Int get() = pending.size
    val waiting: Boolean get() = inFlight != null
    var dropped = 0L
        private set

    fun offer(index: Int, timestampNs: Long) {
        if (pending.size == MAX_PENDING) {
            release(pending.removeFirst().index, false)
            dropped++
        }
        pending.addLast(Frame(index, timestampNs))
        renderNext()
    }

    fun consumed(timestampNs: Long): Boolean {
        if (inFlight != timestampNs) return false
        inFlight = null
        renderNext()
        return true
    }

    private fun renderNext() {
        if (inFlight != null || pending.isEmpty()) return
        val frame = pending.removeFirst()
        inFlight = frame.timestampNs
        release(frame.index, true)
    }

    fun clear() {
        pending.clear()
        inFlight = null
    }
}
