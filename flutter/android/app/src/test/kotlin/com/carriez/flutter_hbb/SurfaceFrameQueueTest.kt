package com.carriez.flutter_hbb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SurfaceFrameQueueTest {
    @Test
    fun nextSurfaceFrameWaitsForTextureConsumption() {
        val released = mutableListOf<Pair<Int, Boolean>>()
        val queue = SurfaceFrameQueue { index, render -> released.add(index to render) }
        queue.offer(1, 100)
        queue.offer(2, 200)
        assertEquals(listOf(1 to true), released)
        assertFalse(queue.consumed(99))
        assertTrue(queue.consumed(100))
        assertEquals(listOf(1 to true, 2 to true), released)
        assertFalse(queue.consumed(100))
        assertTrue(queue.consumed(200))
    }

    @Test
    fun overloadKeepsNewestFramesAndResetDiscardsOldCodecIndices() {
        val released = mutableListOf<Pair<Int, Boolean>>()
        val queue = SurfaceFrameQueue { index, render -> released.add(index to render) }
        queue.offer(1, 100)
        queue.offer(2, 200)
        queue.offer(3, 300)
        queue.offer(4, 400)
        assertEquals(listOf(1 to true, 2 to false), released)
        assertEquals(1L, queue.dropped)
        queue.consumed(100)
        assertEquals(listOf(1 to true, 2 to false, 3 to true), released)
        queue.clear()
        assertFalse(queue.consumed(300))
        assertEquals(listOf(1 to true, 2 to false, 3 to true), released)
    }
}
