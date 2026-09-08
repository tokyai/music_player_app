package com.example.music_player_app

import android.content.Context
import android.graphics.BitmapFactory
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.util.PathUtils
import org.jaudiotagger.audio.AudioFileIO
import org.jaudiotagger.tag.FieldKey
import org.jaudiotagger.tag.images.AndroidArtwork
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class DownloadsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var context: Context? = null
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var connectivity: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val main = Handler(Looper.getMainLooper())
    private data class TagJob(
        val id: String,
        val result: MethodChannel.Result,
        val cancelled: AtomicBoolean = AtomicBoolean(false),
        var replied: Boolean = false,
    )
    private var tagJob: TagJob? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        connectivity = context?.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        methods = MethodChannel(binding.binaryMessenger, "music_player/downloads").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "music_player/download_network").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onCancel(null)
        tagJob?.let {
            it.cancelled.set(true)
            if (!it.replied) {
                it.replied = true
                it.result.error("CANCELLED", "Engine detached", null)
            }
        }
        // The worker retains ownership until its copy has been cleaned up.
        // Reattaching this plugin must not start another writer over that file.
        context = null
        connectivity = null
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        methods = null
        events = null
    }

    private fun wifi(): Boolean {
        val manager = connectivity ?: return false
        return try { manager.getNetworkCapabilities(manager.activeNetwork)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true }
            catch (_: SecurityException) { false }
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        onCancel(null)
        sink = eventSink
        eventSink.success(wifi())
        val callback = object : ConnectivityManager.NetworkCallback() {
            private fun changed() { main.post { if (sink === eventSink) eventSink.success(wifi()) } }
            override fun onAvailable(network: Network) { changed() }
            override fun onLost(network: Network) { changed() }
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) { changed() }
        }
        try { connectivity?.registerDefaultNetworkCallback(callback); networkCallback = callback }
        catch (error: RuntimeException) { eventSink.error("NETWORK", error.message, null) }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        networkCallback?.let { try { connectivity?.unregisterNetworkCallback(it) } catch (_: RuntimeException) {} }
        networkCallback = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "wifi" -> result.success(wifi())
            "cancelTags" -> {
                if (tagJob?.id == call.argument<String>("id")) tagJob?.cancelled?.set(true)
                result.success(null)
            }
            "writeTags" -> writeTags(call, result)
            else -> result.notImplemented()
        }
    }

    private fun writeTags(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: run { result.error("DETACHED", "Engine unavailable", null); return }
        if (tagJob != null) { result.error("BUSY", "Tag writer busy", null); return }
        val id = call.argument<String>("id").orEmpty()
        val path = call.argument<String>("path").orEmpty()
        if (!Regex("[a-f0-9]{24}").matches(id)) { result.error("INVALID", "Invalid download id", null); return }
        val job = TagJob(id, result)
        tagJob = job
        try { Thread({
            var output: File? = null
            var failure: Throwable? = null
            try {
                val root = File(PathUtils.getDataDirectory(ctx), "downloads").canonicalFile
                val input = File(path).canonicalFile
                require(input.path.startsWith(root.path + File.separator) && input.parentFile?.name == "staging")
                require(Regex("$id\\.(mp3|flac|m4a|ogg|opus|ape)").matches(input.name))
                require(input.length() in 1..(256L * 1024 * 1024))
                val parent = File(input.parentFile!!.parentFile, "tagged").canonicalFile
                require(parent.path.startsWith(root.path + File.separator))
                check(parent.isDirectory || parent.mkdirs())
                val target = File(parent, input.name)
                require(target.canonicalFile == target.absoluteFile)
                output = target
                input.inputStream().use { source -> output.outputStream().use { target ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        check(!job.cancelled.get())
                        val count = source.read(buffer)
                        if (count < 0) break
                        target.write(buffer, 0, count)
                    }
                } }
                check(!job.cancelled.get())
                val audio = AudioFileIO.read(output)
                check(!job.cancelled.get())
                val tag = audio.tagOrCreateAndSetDefault
                fun field(key: FieldKey, argument: String, limit: Int = 512) {
                    call.argument<String>(argument)?.take(limit)?.takeIf { it.isNotBlank() }?.let { tag.setField(key, it) }
                }
                field(FieldKey.TITLE, "title")
                field(FieldKey.ARTIST, "artist")
                field(FieldKey.ALBUM, "album")
                field(FieldKey.LYRICS, "lyrics", 256 * 1024)
                call.argument<String>("coverPath")?.let { coverPath ->
                    val cover = File(coverPath).canonicalFile
                    require(cover.parentFile == input.parentFile && cover.name == "$id.cover.jpg" && cover.length() in 1..(2L * 1024 * 1024))
                    val options = BitmapFactory.Options().also { it.inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(cover.path, options)
                    require(options.outWidth > 0 && options.outHeight > 0 && options.outWidth.toLong() * options.outHeight <= 16_000_000)
                    val artwork = AndroidArtwork().also {
                        it.binaryData = cover.readBytes(); it.mimeType = options.outMimeType
                        it.width = options.outWidth; it.height = options.outHeight; it.pictureType = 3
                    }
                    tag.setField(artwork)
                }
                check(!job.cancelled.get())
                AudioFileIO.write(audio)
                check(!job.cancelled.get())
            } catch (error: Throwable) { failure = error }
            finally {
                // A timed-out Dart caller can leave; only this worker owns its copy.
                main.post {
                    val cancelled = job.cancelled.get() || context == null
                    if (cancelled || failure != null) { try { output?.delete() } catch (_: Exception) {} }
                    if (tagJob === job) {
                        tagJob = null
                        if (!job.replied && context != null) {
                            job.replied = true
                            if (cancelled || failure != null) result.error("TAGS_UNAVAILABLE", "Tags could not be written", null)
                            else result.success(output?.path)
                        }
                    }
                }
            }
        }, "kuzai-download-tags").start() } catch (_: Throwable) {
            tagJob = null
            result.error("TAGS_UNAVAILABLE", "Unable to start tag writer", null)
        }
    }
}
