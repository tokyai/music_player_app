package com.example.music_player_app

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import android.view.KeyEvent
import androidx.annotation.NonNull
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : AudioServiceActivity() {
    companion object {
        const val CHANNEL = "music_player/floating_capsule"
        const val INSTALL_CHANNEL = "music_player/install"
        const val FAVORITES_FILE_CHANNEL = "music_player/favorites_file"
        const val EXTERNAL_MEDIA_CHANNEL = "music_player/external_media"
        const val AI_TTS_CHANNEL = "music_player/ai_tts"
        const val AI_AUDIO_CHANNEL = "music_player/ai_audio"
        const val AI_MODEL_CHANNEL = "music_player/ai_model"
        const val AI_CAR_AUDIO_CONTROL_CHANNEL = "music_player/ai_car_audio_control"
        const val AI_CAR_AUDIO_STREAM_CHANNEL = "music_player/ai_car_audio_stream"
        const val ZIPFORMER_MODEL = "streaming-zipformer-zh-14M-2023-02-23"
        const val PARAFORMER_MODEL = "streaming-paraformer-bilingual-zh-en"
        const val CAR_AUDIO_SAMPLE_RATE = 16000
        const val CAR_AUDIO_CHANNEL_MASK = 60
        const val CAR_AUDIO_CHANNEL_COUNT = 4
        const val CAR_AUDIO_MIX_DIVISOR = 2
        const val CAR_AUDIO_READ_BYTES = 4096
        // A four-channel 4096-byte packet is about 32 ms at 16 kHz. Keep only
        // a bounded amount of pending audio so a slow Sherpa decode cannot
        // grow the Android main-thread queue without limit.
        const val CAR_AUDIO_MAX_PENDING_CHUNKS = 32
        const val CAR_AUDIO_MAX_BATCH_BYTES = 16 * 1024
        const val REQUEST_IMPORT_FAVORITES = 4101
        const val REQUEST_EXPORT_FAVORITES = 4102
        const val MAX_BACKUP_BYTES = 5 * 1024 * 1024
    }

    private var pendingFileResult: MethodChannel.Result? = null
    private var pendingExportContent: String? = null
    private var foregroundMediaKeyChannel: MethodChannel? = null
    private var floatingCapsuleChannel: MethodChannel? = null
    private var aiTtsChannel: MethodChannel? = null
    private var aiAudioChannel: MethodChannel? = null
    private var aiModelChannel: MethodChannel? = null
    private var aiCarAudioControlChannel: MethodChannel? = null
    private var aiCarAudioEventChannel: EventChannel? = null
    @Volatile private var aiCarAudioRunning = false
    @Volatile private var aiCarAudioSink: EventChannel.EventSink? = null
    @Volatile private var aiCarAudioRecord: AudioRecord? = null
    @Volatile private var aiCarAudioThread: Thread? = null
    private val aiCarAudioHandler = Handler(Looper.getMainLooper())
    private val aiCarAudioQueue = ArrayDeque<ByteArray>()
    private val aiCarAudioQueueLock = Any()
    @Volatile private var aiCarAudioDrainPosted = false
    @Volatile private var aiCarAudioGeneration = 0L
    @Volatile private var aiCarAudioAwaitingAck = false
    private var aiCarAudioChannelCount = CAR_AUDIO_CHANNEL_COUNT
    @Volatile private var aiCarAudioStopFlag: AtomicBoolean? = null
    private var aiCarAudioDroppedChunks = 0L
    private val aiModelPreparationLock = Any()
    private var aiAudioFocusRequest: AudioFocusRequest? = null
    private var aiAudioFocusHeld = false
    private var aiTts: TextToSpeech? = null
    private var aiTtsReady = false
    private var aiTtsInitializing = false
    private val pendingAiTtsInitResults = mutableListOf<MethodChannel.Result>()
    private var pendingAiTtsSpeakResult: MethodChannel.Result? = null
    private var pendingAiTtsUtteranceId: String? = null
    private var foregroundMediaKeysEnabled = false

    private val aiAudioFocusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
        ) {
            // A lost transient request must be abandoned explicitly; otherwise
            // some head units keep the old request in their focus stack.
            abandonAiAudioFocus()
        }
        try {
            aiAudioChannel?.invokeMethod("focusChanged", change)
        } catch (_: Exception) {
        }
    }

    private val aiTtsProgressListener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) = Unit

        override fun onDone(utteranceId: String?) {
            runOnUiThread { finishAiTtsSpeak(utteranceId, true) }
        }

        @Deprecated("Deprecated by Android")
        override fun onError(utteranceId: String?) {
            runOnUiThread { failAiTtsSpeak(utteranceId, "系统语音播报失败") }
        }

        override fun onError(utteranceId: String?, errorCode: Int) {
            runOnUiThread {
                failAiTtsSpeak(utteranceId, "系统语音播报失败（$errorCode）")
            }
        }

        override fun onStop(utteranceId: String?, interrupted: Boolean) {
            runOnUiThread { finishAiTtsSpeak(utteranceId, false) }
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val appContext = applicationContext
        foregroundMediaKeyChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "music_player/foreground_media_keys"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "setEnabled") {
                    foregroundMediaKeysEnabled = call.argument<Boolean>("enabled") == true
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALL_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "installApk") {
                    installApk(
                        call.argument<String>("path"),
                        call.argument<Number>("versionCode")?.toLong(),
                        result
                    )
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FAVORITES_FILE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "importFavorites" -> openFavoriteBackup(result)
                    "exportFavorites" -> createFavoriteBackup(
                        call.argument<String>("content"),
                        call.argument<String>("fileName"),
                        result
                    )
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXTERNAL_MEDIA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "playVideo" -> openExternalVideo(call.argument<String>("url"), result)
                    else -> result.notImplemented()
                }
            }

        aiAudioChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AI_AUDIO_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestFocus" -> result.success(requestAiAudioFocus())
                    "abandonFocus" -> result.success(abandonAiAudioFocus())
                    else -> result.notImplemented()
                }
            }
        }

        aiModelChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AI_MODEL_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> prepareAiModel(
                        call.argument<String>("model") ?: ZIPFORMER_MODEL,
                        result
                    )
                    "memory" -> result.success(aiMemorySnapshot())
                    else -> result.notImplemented()
                }
            }
        }

        aiCarAudioControlChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AI_CAR_AUDIO_CONTROL_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCaptureProfile" -> result.success(getCarAudioCaptureProfile())
                    "ackCaptureBatch" -> {
                        acknowledgeCarAudioBatch()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        aiCarAudioEventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AI_CAR_AUDIO_STREAM_CHANNEL
        ).also { channel ->
            channel.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    startCarArrayCapture(events)
                }

                override fun onCancel(arguments: Any?) {
                    stopCarArrayCapture()
                }
            })
        }

        aiTtsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AI_TTS_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> initializeAiTts(result)
                    "speak" -> speakAiText(call.argument<String>("text"), result)
                    "stop" -> stopAiTts(result)
                    else -> result.notImplemented()
                }
            }
        }

        floatingCapsuleChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(FloatCapsuleManager.hasPermission(appContext))
                    "openPermissionSettings" -> {
                        FloatCapsuleManager.openPermissionSettings(appContext)
                        result.success(null)
                    }
                    "show" -> {
                        val title = call.argument<String>("title") ?: ""
                        val artist = call.argument<String>("artist") ?: ""
                        val coverUrl = call.argument<String>("coverUrl")
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                        runOnUiThread {
                            FloatCapsuleManager.show(
                                appContext, title, artist, coverUrl, isPlaying,
                                onPlayPause = {
                                    invokeCapsuleCallback("onPlayPauseTap")
                                },
                                onTap = {
                                    invokeCapsuleCallback("onCapsuleTap")
                                }
                            )
                        }
                        result.success(null)
                    }
                    "update" -> {
                        val title = call.argument<String>("title") ?: ""
                        val artist = call.argument<String>("artist") ?: ""
                        val coverUrl = call.argument<String>("coverUrl")
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                        runOnUiThread {
                            FloatCapsuleManager.update(title, artist, coverUrl, isPlaying)
                        }
                        result.success(null)
                    }
                    "updatePlayState" -> {
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                        runOnUiThread { FloatCapsuleManager.updatePlayState(isPlaying) }
                        result.success(null)
                    }
                    "hide" -> {
                        runOnUiThread { FloatCapsuleManager.hide() }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (foregroundMediaKeysEnabled) {
            val method = when (event.keyCode) {
                KeyEvent.KEYCODE_MEDIA_NEXT -> "next"
                KeyEvent.KEYCODE_MEDIA_PREVIOUS -> "previous"
                else -> null
            }
            if (method != null) {
                if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    try {
                        foregroundMediaKeyChannel?.invokeMethod(method, null)
                    } catch (_: Exception) {
                    }
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        foregroundMediaKeysEnabled = false
        foregroundMediaKeyChannel?.setMethodCallHandler(null)
        foregroundMediaKeyChannel = null
        floatingCapsuleChannel?.setMethodCallHandler(null)
        floatingCapsuleChannel = null
        stopCarArrayCapture()
        aiCarAudioHandler.removeCallbacksAndMessages(null)
        aiCarAudioEventChannel?.setStreamHandler(null)
        aiCarAudioEventChannel = null
        aiCarAudioControlChannel?.setMethodCallHandler(null)
        aiCarAudioControlChannel = null
        abandonAiAudioFocus()
        aiAudioChannel?.setMethodCallHandler(null)
        aiAudioChannel = null
        aiModelChannel?.setMethodCallHandler(null)
        aiModelChannel = null
        aiTtsChannel?.setMethodCallHandler(null)
        aiTtsChannel = null
        releaseAiTts()
        FloatCapsuleManager.clearCallbacks()
        super.onDestroy()
    }

    /**
     * Requests a short-lived assistant focus while the voice recognizer owns
     * the microphone. This is public Android audio policy and does not select
     * an OEM-only AudioRecord source or alter Bluetooth routing.
     */
    private fun requestAiAudioFocus(): Boolean {
        if (aiAudioFocusHeld) return true
        val manager = getSystemService(AUDIO_SERVICE) as? AudioManager ?: return false
        return try {
            val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val attributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
                val request = AudioFocusRequest.Builder(
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
                )
                    .setAudioAttributes(attributes)
                    .setWillPauseWhenDucked(true)
                    .setOnAudioFocusChangeListener(aiAudioFocusListener)
                    .build()
                aiAudioFocusRequest = request
                manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            } else {
                // Android 7 and older car head units only expose the stream API.
                manager.requestAudioFocus(
                    aiAudioFocusListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
                ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            }
            aiAudioFocusHeld = granted
            if (!granted) aiAudioFocusRequest = null
            granted
        } catch (_: SecurityException) {
            aiAudioFocusRequest = null
            aiAudioFocusHeld = false
            false
        } catch (_: Exception) {
            aiAudioFocusRequest = null
            aiAudioFocusHeld = false
            false
        }
    }

    private fun abandonAiAudioFocus(): Boolean {
        val manager = getSystemService(AUDIO_SERVICE) as? AudioManager ?: return false
        if (!aiAudioFocusHeld && aiAudioFocusRequest == null) return true
        return try {
            val abandoned = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                aiAudioFocusRequest?.let {
                    manager.abandonAudioFocusRequest(it)
                } ?: AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            } else {
                manager.abandonAudioFocus(aiAudioFocusListener)
            }
            aiAudioFocusRequest = null
            aiAudioFocusHeld = false
            abandoned == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } catch (_: Exception) {
            aiAudioFocusRequest = null
            aiAudioFocusHeld = false
            false
        }
    }

    private fun getCarAudioCaptureProfile(): Map<String, Any> {
        val deviceType = getSystemProperty("ro.build.ohos.devicetype")
        // Flyme and ordinary Android head units do not expose the HarmonyOS
        // device property. They still need the same bounded native capture
        // path; otherwise record_android posts one unbounded UI Runnable per
        // PCM packet while a CPU ASR model is decoding.
        val isCarArray = deviceType == "car"
        val audioSource = if (isCarArray) {
            MediaRecorder.AudioSource.VOICE_RECOGNITION
        } else {
            MediaRecorder.AudioSource.MIC
        }
        val channelMask = if (isCarArray) {
            CAR_AUDIO_CHANNEL_MASK
        } else {
            AudioFormat.CHANNEL_IN_STEREO
        }
        val channelCount = if (isCarArray) CAR_AUDIO_CHANNEL_COUNT else 2
        val mixDivisor = if (isCarArray) CAR_AUDIO_MIX_DIVISOR else channelCount
        val minBufferSize = AudioRecord.getMinBufferSize(
            CAR_AUDIO_SAMPLE_RATE,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT
        )
        return mapOf(
            "supported" to (minBufferSize > 0),
            "kind" to if (isCarArray) "carArray" else "standardNative",
            "deviceType" to deviceType,
            "sampleRate" to CAR_AUDIO_SAMPLE_RATE,
            "audioSource" to audioSource,
            "channelMask" to channelMask,
            "channelCount" to channelCount,
            "mixDivisor" to mixDivisor,
            "minBufferSize" to minBufferSize,
            "readBytes" to CAR_AUDIO_READ_BYTES
        )
    }

    private fun aiMemorySnapshot(): Map<String, Any> {
        val memory = Debug.MemoryInfo()
        Debug.getMemoryInfo(memory)
        val manager = getSystemService(ACTIVITY_SERVICE) as? ActivityManager
        val systemMemory = ActivityManager.MemoryInfo()
        manager?.getMemoryInfo(systemMemory)
        return mapOf(
            "totalPssKb" to memory.totalPss.toLong(),
            "nativeHeapKb" to (Debug.getNativeHeapAllocatedSize() / 1024L),
            "javaHeapKb" to (Runtime.getRuntime().totalMemory() -
                Runtime.getRuntime().freeMemory()) / 1024L,
            "availMemKb" to (systemMemory.availMem / 1024L),
            "lowMemory" to systemMemory.lowMemory,
            "memoryClassMb" to (manager?.memoryClass ?: 0),
            "largeMemoryClassMb" to (manager?.largeMemoryClass ?: 0),
            "isLowRamDevice" to (manager?.isLowRamDevice ?: false)
        )
    }

    private fun getSystemProperty(key: String): String {
        return try {
            val properties = Class.forName("android.os.SystemProperties")
            val getter = properties.getMethod(
                "get",
                String::class.java,
                String::class.java
            )
            getter.invoke(null, key, "") as? String ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    @SuppressLint("MissingPermission")
    private fun startCarArrayCapture(events: EventChannel.EventSink) {
        stopCarArrayCapture()
        val profile = getCarAudioCaptureProfile()
        if (profile["supported"] != true) {
            events.error(
                "CAR_ARRAY_UNAVAILABLE",
                "当前设备没有可用的四通道车载麦克风阵列",
                profile
            )
            return
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            events.error("MIC_PERMISSION_DENIED", "麦克风权限未授予", null)
            return
        }

        val audioSource = (profile["audioSource"] as Number).toInt()
        val channelMask = (profile["channelMask"] as Number).toInt()
        val channelCount = (profile["channelCount"] as Number).toInt()
        val readBytes = if (profile["readBytes"] is Number) {
            (profile["readBytes"] as Number).toInt()
        } else {
            CAR_AUDIO_READ_BYTES
        }
        val minBufferSize = (profile["minBufferSize"] as Number).toInt()
        val internalBufferSize = maxOf(minBufferSize * 2, readBytes * 2)
        val recorder = try {
            AudioRecord(
                audioSource,
                CAR_AUDIO_SAMPLE_RATE,
                channelMask,
                AudioFormat.ENCODING_PCM_16BIT,
                internalBufferSize
            )
        } catch (error: Exception) {
            events.error("CAR_ARRAY_CREATE_FAILED", error.message, profile)
            return
        }
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            events.error("CAR_ARRAY_INIT_FAILED", "四通道车载麦克风初始化失败", profile)
            return
        }
        try {
            recorder.startRecording()
        } catch (error: Exception) {
            recorder.release()
            events.error("CAR_ARRAY_START_FAILED", error.message, profile)
            return
        }
        if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            recorder.release()
            events.error("CAR_ARRAY_START_FAILED", "四通道车载麦克风未进入录音状态", profile)
            return
        }

        val stopRequested = AtomicBoolean(false)
        val generation = synchronized(aiCarAudioQueueLock) {
            aiCarAudioQueue.clear()
            aiCarAudioDroppedChunks = 0
            aiCarAudioSink = events
            aiCarAudioRecord = recorder
            aiCarAudioChannelCount = channelCount
            aiCarAudioRunning = true
            aiCarAudioAwaitingAck = false
            aiCarAudioStopFlag = stopRequested
            aiCarAudioGeneration
        }
        events.success(mapOf("event" to "started"))
        val captureThread = Thread {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            val buffer = ByteArray(readBytes)
            try {
                while (aiCarAudioRunning && aiCarAudioRecord === recorder) {
                    val count = recorder.read(buffer, 0, buffer.size)
                    if (count > 0) {
                        enqueueCarAudioChunk(
                            generation,
                            recorder,
                            events,
                            channelCount,
                            buffer,
                            count
                        )
                    } else if (count != 0) {
                        throw IllegalStateException("AudioRecord.read failed: $count")
                    }
                }
            } catch (error: Exception) {
                if (aiCarAudioRunning && aiCarAudioRecord === recorder) {
                    runOnUiThread {
                        if (aiCarAudioSink === events) {
                            events.error("CAR_ARRAY_READ_FAILED", error.message, null)
                        }
                    }
                }
            } finally {
                // The flag belongs to this recorder instance. A new capture
                // may start before this worker exits, so a shared field must
                // not be reused across generations.
                val shouldStopRecorder = stopRequested.compareAndSet(false, true)
                if (shouldStopRecorder) {
                    try {
                        if (recorder.recordingState ==
                            AudioRecord.RECORDSTATE_RECORDING
                        ) {
                            recorder.stop()
                        }
                    } catch (_: Exception) {
                    }
                }
                try {
                    recorder.release()
                } catch (_: Exception) {
                }
                synchronized(aiCarAudioQueueLock) {
                    if (aiCarAudioRecord === recorder &&
                        aiCarAudioGeneration == generation
                    ) {
                        aiCarAudioRecord = null
                        aiCarAudioSink = null
                        aiCarAudioThread = null
                        aiCarAudioRunning = false
                        aiCarAudioAwaitingAck = false
                        aiCarAudioQueue.clear()
                        aiCarAudioDrainPosted = false
                    }
                    if (aiCarAudioStopFlag === stopRequested) {
                        aiCarAudioStopFlag = null
                    }
                }
            }
        }.also { it.name = "ai-car-mic" }
        synchronized(aiCarAudioQueueLock) {
            // Publish the thread before starting it so onCancel/onDestroy can
            // always join the worker instead of racing an untracked thread.
            aiCarAudioThread = captureThread
        }
        captureThread.start()
    }

    private fun stopCarArrayCapture() {
        val recorder: AudioRecord?
        val thread: Thread?
        val stopRequested: AtomicBoolean?
        synchronized(aiCarAudioQueueLock) {
            aiCarAudioRunning = false
            aiCarAudioSink = null
            recorder = aiCarAudioRecord
            aiCarAudioRecord = null
            thread = aiCarAudioThread
            aiCarAudioThread = null
            stopRequested = aiCarAudioStopFlag
            aiCarAudioStopFlag = null
            aiCarAudioGeneration++
            aiCarAudioAwaitingAck = false
            aiCarAudioQueue.clear()
            aiCarAudioDrainPosted = false
        }
        aiCarAudioHandler.removeCallbacksAndMessages(null)
        // stop() is still needed to wake AudioRecord.read(), but the worker's
        // idempotent stop marker guarantees it is the only caller if the
        // worker reaches its finally block at the same time.
        if (recorder != null &&
            stopRequested?.compareAndSet(false, true) == true
        ) {
            try {
                if (recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                    recorder.stop()
                }
            } catch (_: Exception) {
            }
        }
        thread?.interrupt()
        if (thread != null && thread !== Thread.currentThread()) {
            try {
                // AudioRecord.stop() normally wakes read() immediately. A
                // bounded join prevents a new capture from racing an old
                // thread's final stop/release sequence.
                thread.join(500)
                if (thread.isAlive) {
                    Log.e("AiVoice", "capture worker did not stop within 500ms")
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
    }

    /**
     * AudioRecord runs faster than a CPU-only ASR model can decode on some
     * head units. Posting one Runnable per packet would make the main-thread
     * queue (and every packet copy captured by it) grow forever. Keep a small
     * bounded queue and schedule at most one main-thread drain at a time.
     */
    private fun enqueueCarAudioChunk(
        generation: Long,
        recorder: AudioRecord,
        events: EventChannel.EventSink,
        channelCount: Int,
        source: ByteArray,
        count: Int
    ) {
        var shouldPost = false
        synchronized(aiCarAudioQueueLock) {
            if (!aiCarAudioRunning ||
                aiCarAudioGeneration != generation ||
                aiCarAudioRecord !== recorder ||
                aiCarAudioSink !== events
            ) {
                return
            }
            if (aiCarAudioQueue.size >= CAR_AUDIO_MAX_PENDING_CHUNKS) {
                // Drop the oldest packet when the decoder falls behind. This
                // bounds memory and lets recognition catch up to live audio.
                aiCarAudioQueue.removeFirst()
                aiCarAudioDroppedChunks++
                if (aiCarAudioDroppedChunks == 1L ||
                    aiCarAudioDroppedChunks % 100L == 0L
                ) {
                    Log.w(
                        "AiVoice",
                        "audio queue full; dropped=$aiCarAudioDroppedChunks"
                    )
                }
            }
            aiCarAudioQueue.addLast(source.copyOf(count))
            if (!aiCarAudioDrainPosted && !aiCarAudioAwaitingAck) {
                aiCarAudioDrainPosted = true
                shouldPost = true
            }
        }
        if (shouldPost) {
            scheduleCarAudioDrain(generation, recorder, events, channelCount, 0L)
        }
    }

    private fun drainCarAudioChunks(
        generation: Long,
        recorder: AudioRecord,
        events: EventChannel.EventSink,
        channelCount: Int
    ) {
        val chunks = ArrayList<ByteArray>()
        var totalBytes = 0
        synchronized(aiCarAudioQueueLock) {
            if (!aiCarAudioRunning ||
                aiCarAudioGeneration != generation ||
                aiCarAudioRecord !== recorder ||
                aiCarAudioSink !== events
            ) {
                if (aiCarAudioGeneration == generation) {
                    aiCarAudioQueue.clear()
                    aiCarAudioDrainPosted = false
                }
                return
            }
            if (aiCarAudioAwaitingAck) {
                aiCarAudioDrainPosted = false
                return
            }
            while (aiCarAudioQueue.isNotEmpty() &&
                totalBytes + aiCarAudioQueue.first.size <= CAR_AUDIO_MAX_BATCH_BYTES
            ) {
                val chunk = aiCarAudioQueue.removeFirst()
                chunks.add(chunk)
                totalBytes += chunk.size
            }
            aiCarAudioDrainPosted = false
            if (chunks.isNotEmpty()) aiCarAudioAwaitingAck = true
        }

        if (chunks.isNotEmpty()) {
            val payload = if (chunks.size == 1) {
                chunks[0]
            } else {
                ByteArrayOutputStream(totalBytes).also { output ->
                    chunks.forEach(output::write)
                }.toByteArray()
            }
            try {
                events.success(payload)
            } catch (error: Exception) {
                // A detached Flutter engine can race stream cancellation. Do
                // not let a stale EventSink exception terminate the process.
                Log.w("AiVoice", "audio event delivery failed", error)
                var shouldPost = false
                synchronized(aiCarAudioQueueLock) {
                    if (aiCarAudioGeneration == generation &&
                        aiCarAudioRecord === recorder &&
                        aiCarAudioSink === events
                    ) {
                        aiCarAudioAwaitingAck = false
                        if (aiCarAudioRunning &&
                            aiCarAudioQueue.isNotEmpty() &&
                            !aiCarAudioDrainPosted
                        ) {
                            aiCarAudioDrainPosted = true
                            shouldPost = true
                        }
                    }
                }
                if (shouldPost) {
                    scheduleCarAudioDrain(
                        generation,
                        recorder,
                        events,
                        channelCount,
                        0L
                    )
                }
            }
        }
    }

    /**
     * Flutter calls this after its synchronous stream listener has consumed a
     * batch. Keeping one batch in flight prevents platform messages from
     * accumulating when a native ASR decode is slower than real time.
     */
    private fun acknowledgeCarAudioBatch() {
        var generation = 0L
        var recorder: AudioRecord? = null
        var events: EventChannel.EventSink? = null
        var channelCount = CAR_AUDIO_CHANNEL_COUNT
        var shouldPost = false
        synchronized(aiCarAudioQueueLock) {
            if (!aiCarAudioRunning || !aiCarAudioAwaitingAck) return
            aiCarAudioAwaitingAck = false
            recorder = aiCarAudioRecord
            events = aiCarAudioSink
            generation = aiCarAudioGeneration
            channelCount = aiCarAudioChannelCount
            if (recorder != null && events != null &&
                aiCarAudioQueue.isNotEmpty() && !aiCarAudioDrainPosted
            ) {
                aiCarAudioDrainPosted = true
                shouldPost = true
            }
        }
        val nextRecorder = recorder
        val nextEvents = events
        if (shouldPost && nextRecorder != null && nextEvents != null) {
            scheduleCarAudioDrain(
                generation,
                nextRecorder,
                nextEvents,
                channelCount,
                0L
            )
        }
    }

    private fun scheduleCarAudioDrain(
        generation: Long,
        recorder: AudioRecord,
        events: EventChannel.EventSink,
        channelCount: Int,
        delayMs: Long
    ) {
        val posted = aiCarAudioHandler.postDelayed(
            {
                drainCarAudioChunks(
                    generation,
                    recorder,
                    events,
                    channelCount
                )
            },
            delayMs
        )
        if (!posted) {
            synchronized(aiCarAudioQueueLock) {
                if (aiCarAudioGeneration == generation) {
                    aiCarAudioDrainPosted = false
                }
            }
        }
    }

    private fun prepareAiModel(modelId: String, result: MethodChannel.Result) {
        Thread {
            try {
                val paths = synchronized(aiModelPreparationLock) {
                    // Rapidly closing and reopening the assistant can leave a
                    // previous prepare request in flight. Serialize copies so
                    // two requests cannot replace the same ONNX file while a
                    // recognizer is opening it.
                    val modelFiles = when (modelId) {
                        ZIPFORMER_MODEL -> linkedMapOf(
                            "encoder" to "encoder-epoch-99-avg-1.int8.onnx",
                            "decoder" to "decoder-epoch-99-avg-1.onnx",
                            "joiner" to "joiner-epoch-99-avg-1.int8.onnx",
                            "tokens" to "tokens.txt"
                        )
                        PARAFORMER_MODEL -> linkedMapOf(
                            "encoder" to "encoder.int8.onnx",
                            "decoder" to "decoder.int8.onnx",
                            "tokens" to "tokens.txt"
                        )
                        else -> throw IllegalArgumentException("不支持的离线语音模型：$modelId")
                    }
                    val modelVersion = when (modelId) {
                        ZIPFORMER_MODEL -> "$modelId-mixed-precision-v2"
                        else -> "$modelId-int8-v1"
                    }
                    val assetDir = "assets/models/sherpa-onnx-$modelId"
                    val modelDir = File(filesDir, "ai_models/$modelVersion")
                    val marker = File(modelDir, ".ready")
                    if (!marker.isFile ||
                        marker.readText() != modelVersion ||
                        modelFiles.values.any { !File(modelDir, it).isFile }
                    ) {
                        modelDir.mkdirs()
                        modelFiles.values.forEach { fileName ->
                            val assetName = "$assetDir/$fileName"
                            val assetKey = FlutterInjector.instance().flutterLoader()
                                .getLookupKeyForAsset(assetName)
                            val output = File(modelDir, fileName)
                            val temporary = File(modelDir, "$fileName.part")
                            assets.open(assetKey).use { input ->
                                temporary.outputStream().buffered().use { target ->
                                    input.copyTo(target, DEFAULT_BUFFER_SIZE)
                                }
                            }
                            if (output.exists() && !output.delete()) {
                                throw IllegalStateException("无法替换旧语音模型：$fileName")
                            }
                            if (!temporary.renameTo(output)) {
                                throw IllegalStateException("无法保存语音模型：$fileName")
                            }
                        }
                        marker.writeText(modelVersion)
                    }
                    modelFiles.mapValues { (_, fileName) ->
                        File(modelDir, fileName).absolutePath
                    }
                }
                runOnUiThread { result.success(paths) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "ai_model_prepare_failed",
                        error.message ?: "离线语音模型准备失败",
                        null
                    )
                }
            }
        }.start()
    }

    private fun initializeAiTts(result: MethodChannel.Result) {
        if (aiTtsReady && aiTts != null) {
            result.success(true)
            return
        }
        pendingAiTtsInitResults.add(result)
        if (aiTtsInitializing) return
        aiTtsInitializing = true
        try {
            aiTts = TextToSpeech(applicationContext) { status ->
                runOnUiThread {
                    aiTtsInitializing = false
                    aiTtsReady = status == TextToSpeech.SUCCESS && aiTts != null
                    if (aiTtsReady) {
                        // Do not query or replace the default voice here. Some Android 15
                        // TTS engines allocate every installed voice during setLanguage().
                        aiTts?.setOnUtteranceProgressListener(aiTtsProgressListener)
                        try {
                            aiTts?.setSpeechRate(0.96f)
                        } catch (_: Exception) {
                        }
                    }
                    val callbacks = pendingAiTtsInitResults.toList()
                    pendingAiTtsInitResults.clear()
                    callbacks.forEach { callback ->
                        if (aiTtsReady) {
                            callback.success(true)
                        } else {
                            callback.error(
                                "TTS_INIT_FAILED",
                                "系统文字转语音服务初始化失败（$status）",
                                null
                            )
                        }
                    }
                }
            }
        } catch (error: Exception) {
            aiTtsInitializing = false
            aiTtsReady = false
            val callbacks = pendingAiTtsInitResults.toList()
            pendingAiTtsInitResults.clear()
            callbacks.forEach { callback ->
                callback.error(
                    "TTS_INIT_FAILED",
                    error.message ?: "系统文字转语音服务初始化失败",
                    null
                )
            }
        }
    }

    private fun speakAiText(text: String?, result: MethodChannel.Result) {
        val normalized = text?.trim().orEmpty()
        val engine = aiTts
        if (!aiTtsReady || engine == null) {
            result.error("TTS_NOT_READY", "系统文字转语音服务尚未就绪", null)
            return
        }
        if (normalized.isEmpty()) {
            result.success(false)
            return
        }
        try {
            engine.stop()
            finishAiTtsSpeak(pendingAiTtsUtteranceId, false)
            val utteranceId = UUID.randomUUID().toString()
            pendingAiTtsUtteranceId = utteranceId
            pendingAiTtsSpeakResult = result
            val status = engine.speak(
                normalized,
                TextToSpeech.QUEUE_FLUSH,
                null,
                utteranceId
            )
            if (status != TextToSpeech.SUCCESS) {
                failAiTtsSpeak(utteranceId, "系统语音播报启动失败（$status）")
            }
        } catch (error: Exception) {
            failAiTtsSpeak(
                pendingAiTtsUtteranceId,
                error.message ?: "系统语音播报失败"
            )
        }
    }

    private fun stopAiTts(result: MethodChannel.Result) {
        try {
            aiTts?.stop()
        } catch (_: Exception) {
        }
        finishAiTtsSpeak(pendingAiTtsUtteranceId, false)
        result.success(null)
    }

    private fun finishAiTtsSpeak(utteranceId: String?, completed: Boolean) {
        if (utteranceId == null || utteranceId != pendingAiTtsUtteranceId) return
        val callback = pendingAiTtsSpeakResult
        pendingAiTtsSpeakResult = null
        pendingAiTtsUtteranceId = null
        callback?.success(completed)
    }

    private fun failAiTtsSpeak(utteranceId: String?, message: String) {
        if (utteranceId == null || utteranceId != pendingAiTtsUtteranceId) return
        val callback = pendingAiTtsSpeakResult
        pendingAiTtsSpeakResult = null
        pendingAiTtsUtteranceId = null
        callback?.error("TTS_SPEAK_FAILED", message, null)
    }

    private fun releaseAiTts() {
        pendingAiTtsInitResults.clear()
        pendingAiTtsSpeakResult = null
        pendingAiTtsUtteranceId = null
        aiTtsReady = false
        aiTtsInitializing = false
        try {
            aiTts?.stop()
            aiTts?.shutdown()
        } catch (_: Exception) {
        }
        aiTts = null
    }

    private fun invokeCapsuleCallback(method: String) {
        runOnUiThread {
            try {
                floatingCapsuleChannel?.invokeMethod(method, null)
            } catch (_: Exception) {
            }
        }
    }

    private fun openFavoriteBackup(result: MethodChannel.Result) {
        if (pendingFileResult != null) {
            result.error("BUSY", "已有文件操作正在进行", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
        }
        try {
            pendingFileResult = result
            startActivityForResult(intent, REQUEST_IMPORT_FAVORITES)
        } catch (_: Exception) {
            pendingFileResult = null
            result.error("UNSUPPORTED", "系统没有可用的文件选择器", null)
        }
    }

    private fun openExternalVideo(url: String?, result: MethodChannel.Result) {
        val uri = try {
            Uri.parse(url ?: "")
        } catch (_: Exception) {
            null
        }
        if (uri == null || (uri.scheme != "http" && uri.scheme != "https")) {
            result.error("BAD_VIDEO_URL", "MV 播放地址无效", null)
            return
        }

        val videoIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "video/*")
        }
        val browserIntent = Intent(Intent.ACTION_VIEW, uri)
        runOnUiThread {
            try {
                startActivity(videoIntent)
                result.success(true)
            } catch (_: Exception) {
                try {
                    startActivity(browserIntent)
                    result.success(true)
                } catch (_: Exception) {
                    result.success(false)
                }
            }
        }
    }

    private fun createFavoriteBackup(
        content: String?,
        fileName: String?,
        result: MethodChannel.Result
    ) {
        if (pendingFileResult != null) {
            result.error("BUSY", "已有文件操作正在进行", null)
            return
        }
        if (content.isNullOrEmpty()) {
            result.error("EMPTY_BACKUP", "收藏备份内容为空", null)
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(Intent.EXTRA_TITLE, fileName ?: "kuzai-music-backup.json")
        }
        try {
            pendingFileResult = result
            pendingExportContent = content
            startActivityForResult(intent, REQUEST_EXPORT_FAVORITES)
        } catch (_: Exception) {
            pendingFileResult = null
            pendingExportContent = null
            result.error("UNSUPPORTED", "系统没有可用的文件选择器", null)
        }
    }

    @Deprecated("Deprecated in Android, retained for Flutter activity compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_IMPORT_FAVORITES &&
            requestCode != REQUEST_EXPORT_FAVORITES
        ) {
            return
        }

        val callback = pendingFileResult ?: return
        pendingFileResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pendingExportContent = null
            callback.success(null)
            return
        }

        try {
            if (requestCode == REQUEST_IMPORT_FAVORITES) {
                val content = readUtf8WithLimit(uri)
                callback.success(content)
            } else {
                val content = pendingExportContent
                    ?: throw IllegalStateException("收藏备份内容已失效")
                contentResolver.openOutputStream(uri, "wt")
                    ?.bufferedWriter(Charsets.UTF_8)
                    ?.use { it.write(content) }
                    ?: throw IllegalStateException("无法写入所选文件")
                callback.success(true)
            }
        } catch (_: OutOfMemoryError) {
            callback.error("FILE_TOO_LARGE", "文件过大，无法安全读取", null)
        } catch (error: Exception) {
            callback.error("FILE_ERROR", error.message ?: "文件操作失败", null)
        } finally {
            pendingExportContent = null
        }
    }

    private fun readUtf8WithLimit(uri: Uri): String {
        val bytes = contentResolver.openInputStream(uri)?.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8 * 1024)
            var total = 0
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                if (total > MAX_BACKUP_BYTES) {
                    throw IllegalArgumentException("收藏备份不能超过 5 MB")
                }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        } ?: throw IllegalStateException("无法读取所选文件")
        return bytes.toString(Charsets.UTF_8)
    }

    private fun installApk(
        path: String?,
        expectedVersionCode: Long?,
        result: MethodChannel.Result
    ) {
        if (path.isNullOrEmpty()) {
            result.error("BAD_PATH", "APK 路径为空", null)
            return
        }
        if (expectedVersionCode == null || expectedVersionCode <= 0) {
            result.error("BAD_VERSION", "目标版本号无效", null)
            return
        }

        val file = File(path)
        if (!file.isFile) {
            result.error("FILE_NOT_FOUND", "APK 文件不存在", null)
            return
        }

        try {
            val archiveInfo = getArchivePackageInfo(file)
            if (archiveInfo == null || archiveInfo.packageName != packageName) {
                result.error("PACKAGE_MISMATCH", "安装包不是本应用的更新", null)
                return
            }

            val installedInfo = getInstalledPackageInfo()
            val archiveVersion = getLongVersionCode(archiveInfo)
            val installedVersion = getLongVersionCode(installedInfo)
            if (archiveVersion != expectedVersionCode || archiveVersion <= installedVersion) {
                result.error("VERSION_MISMATCH", "安装包版本号不匹配", null)
                return
            }
            if (!hasSameSigners(installedInfo, archiveInfo)) {
                result.error("SIGNATURE_MISMATCH", "安装包签名校验失败", null)
                return
            }

            val uri: Uri = FileProvider.getUriForFile(
                applicationContext,
                "$packageName.fileProvider",
                file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            runOnUiThread {
                try {
                    startActivity(intent)
                    result.success(null)
                } catch (_: Exception) {
                    result.error("NO_INSTALLER", "未找到可用的安装程序", null)
                }
            }
        } catch (e: Exception) {
            result.error("INSTALL_FAIL", e.message ?: "安装失败", null)
        }
    }

    @Suppress("DEPRECATION")
    private fun getArchivePackageInfo(file: File): PackageInfo? {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        return packageManager.getPackageArchiveInfo(file.absolutePath, flags)
    }

    @Suppress("DEPRECATION")
    private fun getInstalledPackageInfo(): PackageInfo {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        return packageManager.getPackageInfo(packageName, flags)
    }

    @Suppress("DEPRECATION")
    private fun getLongVersionCode(info: PackageInfo): Long {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            info.versionCode.toLong()
        }
    }

    @Suppress("DEPRECATION")
    private fun signerCertificates(info: PackageInfo): List<ByteArray> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
                ?.map { it.toByteArray() }
                .orEmpty()
        } else {
            info.signatures?.map { it.toByteArray() }.orEmpty()
        }
    }

    private fun hasSameSigners(installed: PackageInfo, archive: PackageInfo): Boolean {
        val installedSigners = signerCertificates(installed)
        val archiveSigners = signerCertificates(archive)
        return installedSigners.isNotEmpty() &&
            installedSigners.size == archiveSigners.size &&
            installedSigners.all { installedSigner ->
                archiveSigners.any { archiveSigner ->
                    installedSigner.contentEquals(archiveSigner)
                }
            }
    }
}
