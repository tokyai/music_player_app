package com.example.music_player_app

import android.content.ContentUris
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Read-only MediaStore scanning: one bounded query at a time, off the UI thread. */
class LocalMusicPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: android.content.Context? = null
    private val main = Handler(Looper.getMainLooper())
    private data class Query(val id: Long, val signal: CancellationSignal, val result: MethodChannel.Result)
    private var active: Query? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "music_player/local_music").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        active?.let { it.signal.cancel(); it.result.error("CANCELLED", "Audio scan detached", null) }
        active = null
        main.removeCallbacksAndMessages(null)
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> result.success(mapOf("sdk" to Build.VERSION.SDK_INT))
            "cancel" -> {
                if (active?.id == call.argument<Number>("requestId")?.toLong()) active?.signal?.cancel()
                result.success(null)
            }
            "scan" -> scan(call, result)
            else -> result.notImplemented()
        }
    }

    private fun scan(call: MethodCall, result: MethodChannel.Result) {
        val resolver = context?.contentResolver ?: run { result.error("DETACHED", "Engine unavailable", null); return }
        if (active != null) { result.error("BUSY", "Audio scan is busy", null); return }
        val requestId = call.argument<Number>("requestId")?.toLong() ?: 0L
        val afterId = call.argument<Number>("afterId")?.toLong() ?: 0L
        if (requestId <= 0 || afterId < 0) { result.error("INVALID", "Invalid scan cursor", null); return }
        val query = Query(requestId, CancellationSignal(), result)
        active = query
        try { Thread({
            var response: Map<String, Any>? = null
            var failure: Throwable? = null
            try {
                val columns = arrayOf(MediaStore.Audio.Media._ID, MediaStore.Audio.Media.TITLE,
                    MediaStore.Audio.Media.ARTIST, MediaStore.Audio.Media.ALBUM, MediaStore.Audio.Media.DURATION)
                resolver.query(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, columns,
                    "${MediaStore.Audio.Media._ID} > ? AND ${MediaStore.Audio.Media.IS_MUSIC} != 0 AND ${MediaStore.Audio.Media.DURATION} > 0",
                    arrayOf(afterId.toString()), "${MediaStore.Audio.Media._ID} ASC", query.signal).use { cursor ->
                    val songs = ArrayList<Map<String, Any>>(200)
                    var lastId = afterId
                    var hasMore = false
                    if (cursor != null) {
                        while (cursor.moveToNext()) {
                            query.signal.throwIfCanceled()
                            if (songs.size == 200) { hasMore = true; break }
                            lastId = cursor.getLong(0)
                            fun text(index: Int, fallback: String): String = cursor.getString(index)?.take(512)
                                ?.takeIf { it.isNotBlank() && it != "<unknown>" } ?: fallback
                            songs.add(mapOf("platform" to "local",
                                "id" to ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, lastId).toString(),
                                "name" to text(1, "Unknown song"), "artist" to text(2, "Unknown artist"),
                                "album" to text(3, ""), "duration" to cursor.getLong(4) / 1000))
                        }
                    }
                    response = mapOf("songs" to songs, "afterId" to lastId, "hasMore" to hasMore)
                }
            } catch (error: Throwable) {
                failure = error
            } finally {
                main.post {
                    if (active === query && context != null) {
                        active = null
                        when {
                            query.signal.isCanceled -> result.error("CANCELLED", "Audio scan cancelled", null)
                            failure is SecurityException -> result.error("PERMISSION", "Audio permission denied", null)
                            failure != null -> result.error("SCAN_FAILED", failure.message, null)
                            else -> result.success(response)
                        }
                    }
                }
            }
        }, "kuzai-media-scan").start() } catch (error: Throwable) {
            active = null
            result.error("SCAN_FAILED", "Unable to start audio scan", null)
        }
    }
}
