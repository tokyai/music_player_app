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
import com.ryanheise.audioservice.AudioService
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
        const val APP_LIFECYCLE_CHANNEL = "music_player/app_lifecycle"
        const val ZIPFORMER_MODEL =
            "streaming-zipformer-small-ctc-zh-int8-2025-04-01"
        const val PUNCTUATION_MODEL =
            "punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
        const val HOMOPHONE_REPLACER = "homophone-replacer-zh"
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
    private var appLifecycleChannel: MethodChannel? = null
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
    /**
     * Method-channel work can outlive an Activity (especially while an APK is
     * being recreated for rotation or while Flutter tears down an engine).
     * Every asynchronous callback is tied to this generation so stale native
     * work cannot call a detached Dart messenger.
     */
    private val lifecycleLock = Any()
    @Volatile private var activityAlive = false
    @Volatile private var activityGeneration = 0L
    private data class PendingAiModelResult(
        val generation: Long,
        val result: MethodChannel.Result
    )
    private data class PendingAiTtsInitResult(
        val generation: Long,
        val result: MethodChannel.Result
    )
    private val pendingAiModelResults = mutableListOf<PendingAiModelResult>()
    private var aiAudioFocusRequest: AudioFocusRequest? = null
    private var aiAudioFocusHeld = false
    private var aiAudioFocusAllowsDucking = false
    private var aiTts: TextToSpeech? = null
    private var aiTtsReady = false
    private var aiTtsInitializing = false
    private var aiTtsInitializingGeneration: Long? = null
    private val pendingAiTtsInitResults = mutableListOf<PendingAiTtsInitResult>()
    private var pendingAiTtsSpeakResult: MethodChannel.Result? = null
    private var pendingAiTtsUtteranceId: String? = null
    private var pendingAiTtsSpeakGeneration: Long? = null
    private var foregroundMediaKeysEnabled = false
    private val completeExitRequested = AtomicBoolean(false)

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
            postIfActivityAlive { finishAiTtsSpeak(utteranceId, true) }
        }

        @Deprecated("Deprecated by Android")
        override fun onError(utteranceId: String?) {
            postIfActivityAlive {
                failAiTtsSpeak(utteranceId, "系统语音播报失败")
            }
        }

        override fun onError(utteranceId: String?, errorCode: Int) {
            postIfActivityAlive {
                failAiTtsSpeak(utteranceId, "系统语音播报失败（$errorCode）")
            }
        }

        override fun onStop(utteranceId: String?, interrupted: Boolean) {
            postIfActivityAlive { finishAiTtsSpeak(utteranceId, false) }
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val staleModelResults = synchronized(lifecycleLock) {
            activityGeneration++
            activityAlive = true
            pendingAiModelResults.toList().also { pendingAiModelResults.clear() }
        }
        staleModelResults.forEach {
            safelyResultError(it.result, "ENGINE_REPLACED", "Flutter 引擎已重新建立")
        }
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
                    "requestFocus" -> result.success(
                        requestAiAudioFocus(
                            call.argument<Boolean>("allowDucking") == true
                        )
                    )
                    "abandonFocus" -> result.success(abandonAiAudioFocus())
                    else -> result.notImplemented()
                }
            }
        }

        appLifecycleChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_LIFECYCLE_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "exit" -> requestCompleteExit(result)
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
                    try {
                        startCarArrayCapture(events)
                    } catch (_: OutOfMemoryError) {
                        stopCarArrayCapture()
                        safelySendCarAudioError(
                            events,
                            "CAR_ARRAY_START_OOM",
                            "车机内存不足，无法启动录音",
                            null
                        )
                    } catch (error: Exception) {
                        // OEM AudioRecord implementations occasionally throw
                        // outside the normal constructor/start checks. Keep
                        // that failure on the recoverable stream boundary.
                        stopCarArrayCapture()
                        safelySendCarAudioError(
                            events,
                            "CAR_ARRAY_START_FAILED",
                            error.message ?: "车机麦克风启动失败",
                            null
                        )
                    }
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
                        result.success(FloatCapsuleManager.openPermissionSettings(appContext))
                    }
                    "show" -> {
                        val title = call.argument<String>("title") ?: ""
                        val artist = call.argument<String>("artist") ?: ""
                        val coverUrl = call.argument<String>("coverUrl")
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                        runOnUiThread {
                            val shown = FloatCapsuleManager.show(
                                appContext,
                                title,
                                artist,
                                coverUrl,
                                isPlaying,
                                onPlayPause = { invokeCapsuleCallback("onPlayPauseTap") },
                                onTap = { invokeCapsuleCallback("onCapsuleTap") }
                            )
                            try {
                                result.success(shown)
                            } catch (error: Exception) {
                                Log.w("FloatCapsule", "Unable to return overlay result", error)
                            }
                        }
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
        val staleModelResults = synchronized(lifecycleLock) {
            activityAlive = false
            activityGeneration++
            pendingAiModelResults.toList().also { pendingAiModelResults.clear() }
        }
        staleModelResults.forEach {
            safelyResultError(it.result, "ACTIVITY_DESTROYED", "页面已关闭，模型准备已取消")
        }
        val staleFileResult = pendingFileResult
        pendingFileResult = null
        pendingExportContent = null
        safelyResultError(staleFileResult, "ACTIVITY_DESTROYED", "页面已关闭，文件操作已取消")
        foregroundMediaKeysEnabled = false
        foregroundMediaKeyChannel?.setMethodCallHandler(null)
        foregroundMediaKeyChannel = null
        appLifecycleChannel?.setMethodCallHandler(null)
        appLifecycleChannel = null
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

    private fun requestCompleteExit(result: MethodChannel.Result) {
        if (!completeExitRequested.compareAndSet(false, true)) {
            result.success(true)
            return
        }

        try {
            FloatCapsuleManager.hide()
        } catch (error: Exception) {
            Log.w("AppExit", "failed to hide floating mini window", error)
        }
        try {
            stopService(Intent(applicationContext, AudioService::class.java))
        } catch (error: Exception) {
            Log.w("AppExit", "failed to stop audio service", error)
        }

        // Return to Dart before destroying the engine. A separate handler is
        // used because onDestroy clears callbacks owned by the AI audio path.
        result.success(true)
        Handler(Looper.getMainLooper()).post {
            try {
                finishAndRemoveTask()
            } catch (error: Exception) {
                Log.w("AppExit", "failed to remove app task", error)
                finish()
            }
            Handler(Looper.getMainLooper()).postDelayed({
                Process.killProcess(Process.myPid())
            }, 200L)
        }
    }

    private fun postIfActivityAlive(
        expectedGeneration: Long? = null,
        action: () -> Unit
    ) {
        val posted = aiCarAudioHandler.post {
            if (!activityAlive ||
                (expectedGeneration != null &&
                    expectedGeneration != activityGeneration)
            ) {
                return@post
            }
            try {
                action()
            } catch (error: Exception) {
                Log.w("AiLifecycle", "stale Flutter callback rejected", error)
            }
        }
        if (!posted) {
            Log.w("AiLifecycle", "main looper rejected native callback")
        }
    }

    private fun safelySendCarAudioError(
        events: EventChannel.EventSink,
        code: String,
        message: String?,
        details: Any?
    ) {
        try {
            events.error(code, message, details)
        } catch (error: Exception) {
            Log.w("AiVoice", "audio error delivery failed: $code", error)
        }
    }

    private fun safelySendCarAudioSuccess(
        events: EventChannel.EventSink,
        value: Any?
    ): Boolean = try {
        events.success(value)
        true
    } catch (error: Exception) {
        Log.w("AiVoice", "audio event delivery failed", error)
        false
    }

    private fun failCarAudioDelivery(
        generation: Long,
        recorder: AudioRecord,
        events: EventChannel.EventSink
    ) {
        synchronized(aiCarAudioQueueLock) {
            if (aiCarAudioGeneration != generation ||
                aiCarAudioRecord !== recorder ||
                aiCarAudioSink !== events
            ) {
                return
            }
            // A detached messenger cannot ACK another batch. Stop producing
            // PCM immediately instead of retaining a recorder and audio focus
            // until a later Activity teardown happens to clean it up.
            aiCarAudioRunning = false
            aiCarAudioSink = null
            aiCarAudioAwaitingAck = false
            aiCarAudioQueue.clear()
            aiCarAudioDrainPosted = false
        }
        try {
            if (recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                recorder.stop()
            }
        } catch (_: Exception) {
        }
    }

    private fun safelyResultSuccess(result: MethodChannel.Result?, value: Any?) {
        if (result == null) return
        try {
            result.success(value)
        } catch (error: Exception) {
            Log.w("AiLifecycle", "method result delivery failed", error)
        }
    }

    private fun safelyResultError(
        result: MethodChannel.Result?,
        code: String,
        message: String?
    ) {
        if (result == null) return
        try {
            result.error(code, message, null)
        } catch (error: Exception) {
            Log.w("AiLifecycle", "method error delivery failed: $code", error)
        }
    }

    private fun currentActivityGeneration(): Long? = synchronized(lifecycleLock) {
        if (activityAlive) activityGeneration else null
    }

    private fun takePendingAiModelResult(
        generation: Long,
        result: MethodChannel.Result
    ): Boolean = synchronized(lifecycleLock) {
        if (!activityAlive || activityGeneration != generation) return@synchronized false
        val index = pendingAiModelResults.indexOfFirst {
            it.generation == generation && it.result === result
        }
        if (index < 0) return@synchronized false
        pendingAiModelResults.removeAt(index)
        true
    }

    /**
     * Requests a short-lived assistant focus while the voice recognizer owns
     * the microphone. This is public Android audio policy and does not select
     * an OEM-only AudioRecord source or alter Bluetooth routing.
     */
    private fun requestAiAudioFocus(allowDucking: Boolean): Boolean {
        if (aiAudioFocusHeld && aiAudioFocusAllowsDucking == allowDucking) return true
        if (aiAudioFocusHeld || aiAudioFocusRequest != null) abandonAiAudioFocus()
        val manager = getSystemService(AUDIO_SERVICE) as? AudioManager ?: return false
        return try {
            val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val attributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
                val request = AudioFocusRequest.Builder(
                    if (allowDucking) {
                        AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                    } else {
                        AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
                    }
                )
                    .setAudioAttributes(attributes)
                    .setWillPauseWhenDucked(!allowDucking)
                    .setOnAudioFocusChangeListener(aiAudioFocusListener)
                    .build()
                aiAudioFocusRequest = request
                manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            } else {
                // Android 7 and older car head units only expose the stream API.
                manager.requestAudioFocus(
                    aiAudioFocusListener,
                    AudioManager.STREAM_MUSIC,
                    if (allowDucking) {
                        AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                    } else {
                        AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
                    }
                ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            }
            aiAudioFocusHeld = granted
            aiAudioFocusAllowsDucking = granted && allowDucking
            if (!granted) aiAudioFocusRequest = null
            granted
        } catch (_: SecurityException) {
            aiAudioFocusRequest = null
            aiAudioFocusHeld = false
            aiAudioFocusAllowsDucking = false
            false
        } catch (_: Exception) {
            aiAudioFocusRequest = null
            aiAudioFocusHeld = false
            aiAudioFocusAllowsDucking = false
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
            aiAudioFocusAllowsDucking = false
            abandoned == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } catch (_: Exception) {
            aiAudioFocusRequest = null
            aiAudioFocusHeld = false
            aiAudioFocusAllowsDucking = false
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
        val minBufferSize = try {
            AudioRecord.getMinBufferSize(
                CAR_AUDIO_SAMPLE_RATE,
                channelMask,
                AudioFormat.ENCODING_PCM_16BIT
            )
        } catch (error: Exception) {
            // Some Flyme builds throw for an OEM-only channel mask instead of
            // returning ERROR_BAD_VALUE. Report an unavailable profile so the
            // Dart side can fall back or show a recoverable error.
            Log.w("AiVoice", "audio capture profile is unsupported", error)
            -1
        }
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
        if (!activityAlive) {
            safelySendCarAudioError(events, "ACTIVITY_DESTROYED", "页面已关闭，录音已取消", null)
            return
        }
        val profile = getCarAudioCaptureProfile()
        if (profile["supported"] != true) {
            safelySendCarAudioError(
                events,
                "CAR_ARRAY_UNAVAILABLE",
                "当前设备没有可用的四通道车载麦克风阵列",
                profile
            )
            return
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            safelySendCarAudioError(events, "MIC_PERMISSION_DENIED", "麦克风权限未授予", null)
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
        } catch (_: OutOfMemoryError) {
            safelySendCarAudioError(
                events,
                "CAR_ARRAY_CREATE_FAILED",
                "车机内存不足，无法创建录音缓冲区",
                profile
            )
            return
        } catch (error: Exception) {
            safelySendCarAudioError(events, "CAR_ARRAY_CREATE_FAILED", error.message, profile)
            return
        }
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            releaseCarAudioRecorder(recorder)
            safelySendCarAudioError(
                events,
                "CAR_ARRAY_INIT_FAILED",
                "四通道车载麦克风初始化失败",
                profile
            )
            return
        }
        try {
            recorder.startRecording()
        } catch (_: OutOfMemoryError) {
            releaseCarAudioRecorder(recorder)
            safelySendCarAudioError(
                events,
                "CAR_ARRAY_START_FAILED",
                "车机内存不足，无法启动录音",
                profile
            )
            return
        } catch (error: Exception) {
            releaseCarAudioRecorder(recorder)
            safelySendCarAudioError(events, "CAR_ARRAY_START_FAILED", error.message, profile)
            return
        }
        if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            releaseCarAudioRecorder(recorder)
            safelySendCarAudioError(
                events,
                "CAR_ARRAY_START_FAILED",
                "四通道车载麦克风未进入录音状态",
                profile
            )
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
        if (!safelySendCarAudioSuccess(events, mapOf("event" to "started"))) {
            stopCarArrayCapture()
            return
        }
        val captureThread = Thread {
            try {
                // Device-specific audio drivers can reject the requested
                // priority or buffer allocation. Keep those failures inside
                // the same cleanup boundary as AudioRecord.read().
                Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
                val buffer = ByteArray(readBytes)
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
            } catch (_: OutOfMemoryError) {
                if (aiCarAudioRunning && aiCarAudioRecord === recorder) {
                    postIfActivityAlive {
                        if (aiCarAudioSink === events) {
                            safelySendCarAudioError(
                                events,
                                "CAR_ARRAY_READ_FAILED",
                                "车机内存不足，录音线程已停止",
                                null
                            )
                        }
                    }
                }
            } catch (error: Exception) {
                if (aiCarAudioRunning && aiCarAudioRecord === recorder) {
                    postIfActivityAlive {
                        if (aiCarAudioSink === events) {
                            safelySendCarAudioError(
                                events,
                                "CAR_ARRAY_READ_FAILED",
                                error.message,
                                null
                            )
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
                releaseCarAudioRecorder(recorder)
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
        try {
            captureThread.start()
        } catch (_: OutOfMemoryError) {
            stopCarArrayCapture()
            safelySendCarAudioError(
                events,
                "CAR_ARRAY_START_FAILED",
                "车机内存不足，无法启动录音线程",
                profile
            )
        }
    }

    private fun releaseCarAudioRecorder(recorder: AudioRecord?) {
        if (recorder == null) return
        try {
            recorder.release()
        } catch (error: Exception) {
            Log.w("AiVoice", "AudioRecord release failed", error)
        }
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
                failCarAudioDelivery(generation, recorder, events)
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
                try {
                    drainCarAudioChunks(
                        generation,
                        recorder,
                        events,
                        channelCount
                    )
                } catch (_: OutOfMemoryError) {
                    // Combining PCM batches allocates on the main thread;
                    // stop the capture instead of letting an allocation
                    // failure terminate the Activity.
                    Log.e("AiVoice", "audio batch delivery out of memory")
                    failCarAudioDelivery(generation, recorder, events)
                    safelySendCarAudioError(
                        events,
                        "CAR_ARRAY_DELIVERY_OOM",
                        "车机内存不足，录音已停止",
                        null
                    )
                } catch (error: Exception) {
                    Log.w("AiVoice", "audio batch drain failed", error)
                    failCarAudioDelivery(generation, recorder, events)
                    safelySendCarAudioError(
                        events,
                        "CAR_ARRAY_DELIVERY_FAILED",
                        error.message ?: "车机录音传输失败",
                        null
                    )
                }
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
        val generation = currentActivityGeneration()
        if (generation == null) {
            safelyResultError(result, "ACTIVITY_DESTROYED", "页面已关闭，模型准备已取消")
            return
        }
        synchronized(lifecycleLock) {
            if (!activityAlive || activityGeneration != generation) {
                safelyResultError(result, "ACTIVITY_DESTROYED", "页面已关闭，模型准备已取消")
                return
            }
            pendingAiModelResults.add(PendingAiModelResult(generation, result))
        }
        val worker = Thread {
            var preparationDirectory: File? = null
            try {
                val paths = synchronized(aiModelPreparationLock) {
                    // Rapidly closing and reopening the assistant can leave a
                    // previous prepare request in flight. Serialize copies so
                    // two requests cannot replace the same ONNX file while a
                    // recognizer is opening it.
                    val modelFiles = when (modelId) {
                        ZIPFORMER_MODEL -> linkedMapOf(
                            "model" to "model.int8.onnx",
                            "tokens" to "tokens.txt"
                        )
                        PUNCTUATION_MODEL -> linkedMapOf(
                            "model" to "model.int8.onnx"
                        )
                        HOMOPHONE_REPLACER -> linkedMapOf(
                            "lexicon" to "lexicon.txt",
                            "rules" to "replace.fst"
                        )
                        else -> throw IllegalArgumentException("不支持的离线语音模型：$modelId")
                    }
                    val modelVersion = when (modelId) {
                        ZIPFORMER_MODEL -> "$modelId-int8-v1"
                        PUNCTUATION_MODEL -> "$modelId-v1"
                        HOMOPHONE_REPLACER -> "$modelId-v1"
                        else -> "$modelId-int8-v1"
                    }
                    val assetDir = "assets/models/sherpa-onnx-$modelId"
                    val modelDir = File(filesDir, "ai_models/$modelVersion")
                    preparationDirectory = modelDir
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
                postIfActivityAlive(generation) {
                    if (takePendingAiModelResult(generation, result)) {
                        safelyResultSuccess(result, paths)
                    }
                }
            } catch (_: OutOfMemoryError) {
                // Asset copies and native recognizer construction can exceed
                // the Java heap on low-memory car builds. Remove only
                // incomplete copies so a later retry can start cleanly.
                preparationDirectory?.listFiles()
                    ?.filter { it.name.endsWith(".part") }
                    ?.forEach { it.delete() }
                postIfActivityAlive(generation) {
                    if (takePendingAiModelResult(generation, result)) {
                        safelyResultError(
                            result,
                            "ai_model_prepare_oom",
                            "车机内存不足，无法加载离线语音模型"
                        )
                    }
                }
            } catch (error: Exception) {
                postIfActivityAlive(generation) {
                    if (takePendingAiModelResult(generation, result)) {
                        safelyResultError(
                            result,
                            "ai_model_prepare_failed",
                            error.message ?: "离线语音模型准备失败"
                        )
                    }
                }
            }
        }.also { it.name = "ai-model-prepare" }
        try {
            worker.start()
        } catch (_: OutOfMemoryError) {
            if (takePendingAiModelResult(generation, result)) {
                safelyResultError(
                    result,
                    "ai_model_prepare_oom",
                    "车机内存不足，无法启动离线语音模型准备线程"
                )
            }
        } catch (error: Exception) {
            if (takePendingAiModelResult(generation, result)) {
                safelyResultError(
                    result,
                    "ai_model_prepare_failed",
                    error.message ?: "无法启动离线语音模型准备线程"
                )
            }
        }
    }

    private fun initializeAiTts(result: MethodChannel.Result) {
        val generation = currentActivityGeneration()
        if (generation == null) {
            safelyResultError(result, "ACTIVITY_DESTROYED", "页面已关闭，语音服务初始化已取消")
            return
        }
        if (aiTtsReady && aiTts != null) {
            safelyResultSuccess(result, true)
            return
        }
        pendingAiTtsInitResults.add(PendingAiTtsInitResult(generation, result))
        if (aiTtsInitializing && aiTtsInitializingGeneration == generation) return
        aiTtsInitializing = true
        aiTtsInitializingGeneration = generation
        try {
            aiTts = TextToSpeech(applicationContext) { status ->
                postIfActivityAlive(generation) {
                    if (aiTtsInitializingGeneration != generation) return@postIfActivityAlive
                    aiTtsInitializing = false
                    aiTtsInitializingGeneration = null
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
                    completeAiTtsInit(
                        generation,
                        aiTtsReady,
                        "系统文字转语音服务初始化失败（$status）"
                    )
                }
            }
        } catch (_: OutOfMemoryError) {
            if (aiTtsInitializingGeneration == generation) {
                aiTtsInitializing = false
                aiTtsInitializingGeneration = null
                aiTtsReady = false
                try {
                    aiTts?.shutdown()
                } catch (_: Exception) {
                }
                aiTts = null
                completeAiTtsInit(
                    generation,
                    false,
                    "车机内存不足，系统语音播报已停用"
                )
            }
        } catch (error: Exception) {
            if (aiTtsInitializingGeneration == generation) {
                aiTtsInitializing = false
                aiTtsInitializingGeneration = null
                aiTtsReady = false
                completeAiTtsInit(
                    generation,
                    false,
                    error.message ?: "系统文字转语音服务初始化失败"
                )
            }
        }
    }

    private fun completeAiTtsInit(
        generation: Long,
        ready: Boolean,
        failureMessage: String
    ) {
        if (!activityAlive || activityGeneration != generation) return
        val callbacks = pendingAiTtsInitResults
            .filter { it.generation == generation }
        pendingAiTtsInitResults.removeAll { it.generation == generation }
        callbacks.forEach { callback ->
            if (ready) {
                safelyResultSuccess(callback.result, true)
            } else {
                safelyResultError(callback.result, "TTS_INIT_FAILED", failureMessage)
            }
        }
    }

    private fun speakAiText(text: String?, result: MethodChannel.Result) {
        val generation = currentActivityGeneration()
        if (generation == null) {
            safelyResultError(result, "ACTIVITY_DESTROYED", "页面已关闭，语音播报已取消")
            return
        }
        val normalized = text?.trim().orEmpty()
        val engine = aiTts
        if (!aiTtsReady || engine == null) {
            safelyResultError(result, "TTS_NOT_READY", "系统文字转语音服务尚未就绪")
            return
        }
        if (normalized.isEmpty()) {
            safelyResultSuccess(result, false)
            return
        }
        try {
            engine.stop()
            finishAiTtsSpeak(pendingAiTtsUtteranceId, false)
            val utteranceId = UUID.randomUUID().toString()
            pendingAiTtsUtteranceId = utteranceId
            pendingAiTtsSpeakResult = result
            pendingAiTtsSpeakGeneration = generation
            val status = engine.speak(
                normalized,
                TextToSpeech.QUEUE_FLUSH,
                null,
                utteranceId
            )
            if (status != TextToSpeech.SUCCESS) {
                failAiTtsSpeak(utteranceId, "系统语音播报启动失败（$status）")
            }
        } catch (_: OutOfMemoryError) {
            failAiTtsSpeak(
                pendingAiTtsUtteranceId,
                "车机内存不足，系统语音播报已停止"
            )
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
        safelyResultSuccess(result, null)
    }

    private fun finishAiTtsSpeak(utteranceId: String?, completed: Boolean) {
        if (utteranceId == null || utteranceId != pendingAiTtsUtteranceId) return
        val generation = pendingAiTtsSpeakGeneration
        if (generation == null || !activityAlive || generation != activityGeneration) return
        val callback = pendingAiTtsSpeakResult
        pendingAiTtsSpeakResult = null
        pendingAiTtsUtteranceId = null
        pendingAiTtsSpeakGeneration = null
        safelyResultSuccess(callback, completed)
    }

    private fun failAiTtsSpeak(utteranceId: String?, message: String) {
        if (utteranceId == null || utteranceId != pendingAiTtsUtteranceId) return
        val generation = pendingAiTtsSpeakGeneration
        if (generation == null || !activityAlive || generation != activityGeneration) return
        val callback = pendingAiTtsSpeakResult
        pendingAiTtsSpeakResult = null
        pendingAiTtsUtteranceId = null
        pendingAiTtsSpeakGeneration = null
        safelyResultError(callback, "TTS_SPEAK_FAILED", message)
    }

    private fun releaseAiTts() {
        val initCallbacks = pendingAiTtsInitResults.toList()
        pendingAiTtsInitResults.clear()
        val speakCallback = pendingAiTtsSpeakResult
        pendingAiTtsSpeakResult = null
        pendingAiTtsUtteranceId = null
        pendingAiTtsSpeakGeneration = null
        aiTtsReady = false
        aiTtsInitializing = false
        aiTtsInitializingGeneration = null
        initCallbacks.forEach {
            safelyResultError(it.result, "ACTIVITY_DESTROYED", "页面已关闭，语音服务初始化已取消")
        }
        safelyResultError(speakCallback, "ACTIVITY_DESTROYED", "页面已关闭，语音播报已取消")
        try {
            aiTts?.stop()
            aiTts?.shutdown()
        } catch (_: Exception) {
        }
        aiTts = null
    }

    private fun invokeCapsuleCallback(method: String) {
        postIfActivityAlive {
            try {
                floatingCapsuleChannel?.invokeMethod(method, null)
            } catch (_: Exception) {
            }
        }
    }

    private fun openFavoriteBackup(result: MethodChannel.Result) {
        if (pendingFileResult != null) {
            safelyResultError(result, "BUSY", "已有文件操作正在进行")
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
            safelyResultError(result, "UNSUPPORTED", "系统没有可用的文件选择器")
        }
    }

    private fun openExternalVideo(url: String?, result: MethodChannel.Result) {
        val uri = try {
            Uri.parse(url ?: "")
        } catch (_: Exception) {
            null
        }
        if (uri == null || (uri.scheme != "http" && uri.scheme != "https")) {
            safelyResultError(result, "BAD_VIDEO_URL", "MV 播放地址无效")
            return
        }

        val videoIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "video/*")
        }
        val browserIntent = Intent(Intent.ACTION_VIEW, uri)
        val generation = currentActivityGeneration()
        if (generation == null) {
            safelyResultError(result, "ACTIVITY_DESTROYED", "页面已关闭，MV 打开已取消")
            return
        }
        postIfActivityAlive(generation) {
            try {
                startActivity(videoIntent)
                safelyResultSuccess(result, true)
            } catch (_: Exception) {
                try {
                    startActivity(browserIntent)
                    safelyResultSuccess(result, true)
                } catch (_: Exception) {
                    safelyResultSuccess(result, false)
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
            safelyResultError(result, "BUSY", "已有文件操作正在进行")
            return
        }
        if (content.isNullOrEmpty()) {
            safelyResultError(result, "EMPTY_BACKUP", "收藏备份内容为空")
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
            safelyResultError(result, "UNSUPPORTED", "系统没有可用的文件选择器")
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
            safelyResultSuccess(callback, null)
            return
        }

        try {
            if (requestCode == REQUEST_IMPORT_FAVORITES) {
                val content = readUtf8WithLimit(uri)
                safelyResultSuccess(callback, content)
            } else {
                val content = pendingExportContent
                    ?: throw IllegalStateException("收藏备份内容已失效")
                contentResolver.openOutputStream(uri, "wt")
                    ?.bufferedWriter(Charsets.UTF_8)
                    ?.use { it.write(content) }
                    ?: throw IllegalStateException("无法写入所选文件")
                safelyResultSuccess(callback, true)
            }
        } catch (_: OutOfMemoryError) {
            safelyResultError(callback, "FILE_TOO_LARGE", "文件过大，无法安全读取")
        } catch (error: Exception) {
            safelyResultError(callback, "FILE_ERROR", error.message ?: "文件操作失败")
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
            safelyResultError(result, "BAD_PATH", "APK 路径为空")
            return
        }
        if (expectedVersionCode == null || expectedVersionCode <= 0) {
            safelyResultError(result, "BAD_VERSION", "目标版本号无效")
            return
        }

        val file = File(path)
        if (!file.isFile) {
            safelyResultError(result, "FILE_NOT_FOUND", "APK 文件不存在")
            return
        }

        try {
            val archiveInfo = getArchivePackageInfo(file)
            if (archiveInfo == null || archiveInfo.packageName != packageName) {
                safelyResultError(result, "PACKAGE_MISMATCH", "安装包不是本应用的更新")
                return
            }

            val installedInfo = getInstalledPackageInfo()
            val archiveVersion = getLongVersionCode(archiveInfo)
            val installedVersion = getLongVersionCode(installedInfo)
            if (archiveVersion != expectedVersionCode || archiveVersion <= installedVersion) {
                safelyResultError(result, "VERSION_MISMATCH", "安装包版本号不匹配")
                return
            }
            if (!hasSameSigners(installedInfo, archiveInfo)) {
                safelyResultError(result, "SIGNATURE_MISMATCH", "安装包签名校验失败")
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
            val generation = currentActivityGeneration()
            if (generation == null) {
                safelyResultError(result, "ACTIVITY_DESTROYED", "页面已关闭，安装已取消")
                return
            }
            postIfActivityAlive(generation) {
                try {
                    startActivity(intent)
                    safelyResultSuccess(result, null)
                } catch (_: Exception) {
                    safelyResultError(result, "NO_INSTALLER", "未找到可用的安装程序")
                }
            }
        } catch (e: Exception) {
            safelyResultError(result, "INSTALL_FAIL", e.message ?: "安装失败")
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
