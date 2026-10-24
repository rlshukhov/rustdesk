package com.carriez.flutter_hbb

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface
import androidx.annotation.Keep
import ffi.FFI
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class AndroidTextureDecoder(private val engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "rustdesk/android_texture")
    private val targets = mutableMapOf<String, Target>()

    init {
        channel.setMethodCallHandler { call, result ->
            val session = call.argument<String>("session")
            if (session == null) {
                result.error("arguments", "Missing session", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "create" -> {
                    if (Build.VERSION.SDK_INT < 29) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    targets.remove(session)?.let {
                        FFI.registerAndroidTexture(session, null)
                        it.close()
                    }
                    val entry = engine.renderer.createSurfaceTexture()
                    val target = Target(session, entry) { event -> channel.invokeMethod("state", event) }
                    if (FFI.registerAndroidTexture(session, target)) {
                        targets[session] = target
                        result.success(entry.id())
                    } else {
                        target.close()
                        result.error("session", "Rust session is unavailable", null)
                    }
                }
                "dispose" -> {
                    val target = targets[session]
                    if (target != null && target.id == call.argument<Number>("texture")?.toLong()) {
                        FFI.registerAndroidTexture(session, null)
                        targets.remove(session)?.close()
                    }
                    result.success(null)
                }
                "stats" -> {
                    val target = targets[session]
                    if (target == null || target.id != call.argument<Number>("texture")?.toLong()) {
                        result.success(null)
                    } else {
                        target.readStats { result.success(it) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        targets.forEach { (session, target) ->
            FFI.registerAndroidTexture(session, null)
            target.close()
        }
        targets.clear()
    }

    @Keep
    class Target(
        private val session: String,
        private val entry: TextureRegistry.SurfaceTextureEntry,
        private val event: (Map<String, Any>) -> Unit
    ) {
        private data class AccessUnit(val data: ByteArray, val pts: Long, val queuedNs: Long = System.nanoTime())
        private val worker = HandlerThread("RustDesk-MediaCodec").apply { start() }
        private val handler = Handler(worker.looper)
        private val main = Handler(Looper.getMainLooper())
        private val surface = Surface(entry.surfaceTexture())
        private val closed = AtomicBoolean(false)
        private val failed = AtomicBoolean(false)
        private val submitted = AtomicLong()
        private val decoded = AtomicLong()
        private val consumed = AtomicLong()
        private var lastStatsLogNs = 0L
        private val pending = ArrayDeque<AccessUnit>()
        private val inputs = ArrayDeque<Int>()
        private var codec: MediaCodec? = null
        @Volatile private var codecName = ""
        @Volatile private var failureReason = ""
        private var width = 0
        private var height = 0
        private var hevc = false
        @Volatile private var announced = false
        val id: Long get() = entry.id()
        private val output = SurfaceFrameQueue { index, render ->
            val decoder = codec ?: throw IllegalStateException("Output codec unavailable")
            decoder.releaseOutputBuffer(index, render)
            if (render && !announced) {
                announced = true
                announce("texture")
            }
        }

        init {
            entry.setOnFrameConsumedListener {
                if (closed.get() || failed.get() || !announced) return@setOnFrameConsumedListener
                val timestamp = entry.surfaceTexture().timestamp
                handler.post {
                    if (closed.get() || failed.get()) return@post
                    try {
                        if (output.consumed(timestamp)) {
                            consumed.incrementAndGet()
                            FFI.onAndroidTextureFrame(session)
                        }
                    } catch (e: Exception) { fail(e) }
                }
            }
        }

        @Keep
        fun queueFrame(data: ByteBuffer, width: Int, height: Int, hevc: Boolean, key: Boolean, pts: Long): Int {
            if (closed.get() || failed.get()) return -1
            val bytes = ByteArray(data.remaining())
            data.get(bytes)
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(if (key) 1500 else 250)
            while (!closed.get() && !failed.get()) {
                val task = FutureTask {
                    if (closed.get() || failed.get()) return@FutureTask -1
                    try {
                        if (codec == null || this.width != width || this.height != height || this.hevc != hevc) {
                            if (!key) return@FutureTask 0
                            configure(bytes, width, height, hevc)
                        }
                        if (pending.size >= 4) return@FutureTask 1
                        pending.addLast(AccessUnit(bytes, pts))
                        submitted.incrementAndGet()
                        feed()
                        0
                    } catch (e: Exception) {
                        fail(e)
                        -1
                    }
                }
                if (!handler.post(task)) return -1
                try {
                    val result = task.get((deadline - System.nanoTime()).coerceAtLeast(0), TimeUnit.NANOSECONDS)
                    if (result != 1) return result
                    if (System.nanoTime() >= deadline) throw TimeoutException("Decoder input stayed full")
                    // Wait on the submitting Rust thread so codec callbacks can drain the worker queue.
                    Thread.sleep(2)
                } catch (e: Exception) {
                    task.cancel(false)
                    fail(e)
                    return -1
                }
            }
            return -1
        }

        private fun configure(data: ByteArray, width: Int, height: Int, hevc: Boolean) {
            check(width > 0 && height > 0)
            releaseCodec()
            val csd = AnnexB.parameterSets(data, hevc)
                ?: throw IllegalArgumentException("Key frame has no complete Annex-B parameter sets")
            val mime = if (hevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
            val format = MediaFormat.createVideoFormat(mime, width, height)
            csd.forEachIndexed { index, buffer -> format.setByteBuffer("csd-$index", buffer) }
            val info = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull {
                !it.isEncoder && it.isHardwareAccelerated && it.supportedTypes.any { type -> type == mime } &&
                    it.getCapabilitiesForType(mime).isFormatSupported(format)
            } ?: throw IllegalStateException("No hardware decoder for $mime at ${width}x$height")
            if (Build.VERSION.SDK_INT >= 30 && info.getCapabilitiesForType(mime)
                    .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            this.width = width
            this.height = height
            this.hevc = hevc
            entry.surfaceTexture().setDefaultBufferSize(width, height)
            val decoder = MediaCodec.createByCodecName(info.name)
            codec = decoder
            codecName = info.name
            decoder.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(decoder: MediaCodec, index: Int) {
                    if (decoder !== codec || failed.get() || closed.get()) return
                    inputs.addLast(index)
                    try { feed() } catch (e: Exception) { fail(e) }
                }

                override fun onOutputBufferAvailable(decoder: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    if (decoder !== codec || failed.get() || closed.get()) return
                    try {
                        val render = info.flags and (MediaCodec.BUFFER_FLAG_CODEC_CONFIG or MediaCodec.BUFFER_FLAG_END_OF_STREAM) == 0
                        if (render) {
                            decoded.incrementAndGet()
                            output.offer(index, info.presentationTimeUs * 1000)
                        } else {
                            decoder.releaseOutputBuffer(index, false)
                        }
                    } catch (e: Exception) { fail(e) }
                }

                override fun onOutputFormatChanged(decoder: MediaCodec, format: MediaFormat) {
                    if (decoder === codec) Log.i("AndroidTextureDecoder", "Output format: $format")
                }

                override fun onError(decoder: MediaCodec, error: MediaCodec.CodecException) {
                    if (decoder === codec) fail(error)
                }
            }, handler)
            decoder.configure(format, surface, null, 0)
            decoder.start()
            Log.i("AndroidTextureDecoder", "Hardware surface decoder: ${info.name}, ${width}x$height")
        }

        private fun feed() {
            val decoder = codec ?: return
            while (pending.isNotEmpty() && inputs.isNotEmpty()) {
                val unit = pending.removeFirst()
                val index = inputs.removeFirst()
                val input = decoder.getInputBuffer(index) ?: throw IllegalStateException("Missing decoder input")
                check(input.capacity() >= unit.data.size) { "Compressed frame exceeds codec input capacity" }
                input.clear()
                input.put(unit.data)
                decoder.queueInputBuffer(index, 0, unit.data.size, unit.pts, 0)
            }
        }

        @Keep
        fun reset() {
            handler.post {
                releaseCodec()
                announce("software")
            }
        }

        private fun releaseCodec() {
            val old = codec
            codec = null
            pending.clear()
            inputs.clear()
            output.clear()
            announced = false
            if (old != null) {
                try { old.stop() } catch (e: Exception) { Log.w("AndroidTextureDecoder", "Decoder stop failed", e) }
                try { old.release() } catch (e: Exception) { Log.w("AndroidTextureDecoder", "Decoder release failed", e) }
            }
        }

        private fun fail(error: Exception) {
            if (failed.compareAndSet(false, true)) {
                failureReason = error.message ?: error.javaClass.simpleName
                Log.w("AndroidTextureDecoder", "Switching to software decoding", error)
                announce("software")
                handler.post { releaseCodec() }
                FFI.onAndroidTextureError(session)
            }
        }

        private fun announce(state: String) {
            val payload = mapOf("session" to session, "state" to state, "width" to width,
                "height" to height, "texture" to entry.id(), "codec" to codecName)
            main.post { if (!closed.get()) event(payload) }
        }

        private fun stats(): Map<String, Any> {
            val now = System.nanoTime()
            val age = pending.peekFirst()?.let { (now - it.queuedNs) / 1_000_000 } ?: 0L
            return mapOf("texture" to id, "codec" to codecName, "submitted" to submitted.get(),
                "decoded" to decoded.get(), "consumed" to consumed.get(), "failed" to failed.get(),
                "active" to (codec != null && announced && !failed.get()), "reason" to failureReason,
                "rustQueue" to FFI.androidVideoQueueSize(session), "codecQueue" to pending.size,
                "codecQueueLimit" to 4, "queueAgeMs" to age, "sampleTimeNs" to now,
                "surfaceQueue" to output.size, "surfaceQueueLimit" to SurfaceFrameQueue.MAX_PENDING,
                "surfaceInFlight" to output.waiting, "surfaceDropped" to output.dropped)
        }

        fun readStats(reply: (Map<String, Any>?) -> Unit) {
            if (!handler.post {
                val snapshot = stats()
                val now = snapshot["sampleTimeNs"] as Long
                if (Log.isLoggable("RustDeskTextureStats", Log.DEBUG) &&
                    now - lastStatsLogNs >= TimeUnit.SECONDS.toNanos(1)) {
                    lastStatsLogNs = now
                    Log.d("RustDeskTextureStats", snapshot.toString())
                }
                main.post { reply(snapshot) }
            }) {
                reply(null)
            }
        }

        fun close() {
            if (!closed.compareAndSet(false, true)) return
            handler.post {
                releaseCodec()
                surface.release()
                Log.i("AndroidTextureDecoder", "Texture decoder closed")
                main.post { entry.release() }
                worker.quitSafely()
            }
        }
    }
}
