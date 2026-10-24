package com.carriez.flutter_hbb

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AnnexBTest {
    @Test
    fun avcSeparatesSpsAndPpsWithNormalizedStartCodes() {
        val data = byteArrayOf(0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0x11,
            0, 0, 1, 0x65, 0x22)
        val sets = requireNotNull(AnnexB.parameterSets(data, false))
        assertEquals(2, sets.size)
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x67, 0x42), sets[0].array())
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x68, 0x11), sets[1].array())
    }

    @Test
    fun hevcCombinesVpsSpsPpsAndExcludesPictureData() {
        val vps = byteArrayOf(0, 0, 0, 1, 0x40, 1, 0x11)
        val sps = byteArrayOf(0, 0, 0, 1, 0x42, 1, 0x22)
        val pps = byteArrayOf(0, 0, 0, 1, 0x44, 1, 0x33)
        val picture = byteArrayOf(0, 0, 1, 0x26, 1, 0x55)
        val sets = requireNotNull(AnnexB.parameterSets(vps + sps + pps + picture, true))
        assertEquals(1, sets.size)
        assertArrayEquals(vps + sps + pps, sets[0].array())
    }

    @Test
    fun missingParameterSetsAndTruncatedStartCodesAreRejected() {
        assertNull(AnnexB.parameterSets(byteArrayOf(), true))
        assertNull(AnnexB.parameterSets(byteArrayOf(0, 0, 1), false))
        assertNull(AnnexB.parameterSets(byteArrayOf(0, 0, 1, 0x67, 0x42), false))
        assertNull(AnnexB.parameterSets(byteArrayOf(0, 0, 1, 0x42, 1), true))
    }
}
