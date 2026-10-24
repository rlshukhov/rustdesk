package com.carriez.flutter_hbb

import java.nio.ByteBuffer

internal object AnnexB {
    fun parameterSets(data: ByteArray, hevc: Boolean): List<ByteBuffer>? {
        val units = mutableListOf<Pair<Int, Int>>()
        var index = 0
        while (index + 3 <= data.size) {
            val prefix = when {
                index + 4 <= data.size && data[index] == 0.toByte() &&
                    data[index + 1] == 0.toByte() && data[index + 2] == 0.toByte() &&
                    data[index + 3] == 1.toByte() -> 4
                data[index] == 0.toByte() && data[index + 1] == 0.toByte() &&
                    data[index + 2] == 1.toByte() -> 3
                else -> 0
            }
            if (prefix == 0) {
                index++
            } else {
                units.add(index to prefix)
                index += prefix
            }
        }
        val required = if (hevc) listOf(32, 33, 34) else listOf(7, 8)
        val sets = mutableMapOf<Int, ByteArray>()
        for (i in units.indices) {
            val (start, prefix) = units[i]
            val end = if (i + 1 < units.size) units[i + 1].first else data.size
            if (start + prefix >= end) continue
            val header = data[start + prefix].toInt() and 0xff
            val type = if (hevc) (header shr 1) and 0x3f else header and 0x1f
            if (type in required) {
                sets[type] = byteArrayOf(0, 0, 0, 1) + data.copyOfRange(start + prefix, end)
            }
        }
        if (!required.all { sets.containsKey(it) }) return null
        return if (hevc) {
            listOf(ByteBuffer.wrap(required.fold(byteArrayOf()) { result, type -> result + sets.getValue(type) }))
        } else {
            required.map { ByteBuffer.wrap(sets.getValue(it)) }
        }
    }
}
