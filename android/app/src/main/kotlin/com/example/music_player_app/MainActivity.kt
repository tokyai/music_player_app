package com.example.music_player_app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.KeyEvent
import androidx.annotation.NonNull
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

class MainActivity : AudioServiceActivity() {
    companion object {
        const val CHANNEL = "music_player/floating_capsule"
        const val INSTALL_CHANNEL = "music_player/install"
        const val FAVORITES_FILE_CHANNEL = "music_player/favorites_file"
        const val EXTERNAL_MEDIA_CHANNEL = "music_player/external_media"
        const val AI_TTS_CHANNEL = "music_player/ai_tts"
        const val REQUEST_IMPORT_FAVORITES = 4101
        const val REQUEST_EXPORT_FAVORITES = 4102
        const val MAX_BACKUP_BYTES = 5 * 1024 * 1024
    }

    private var pendingFileResult: MethodChannel.Result? = null
    private var pendingExportContent: String? = null
    private var foregroundMediaKeyChannel: MethodChannel? = null
    private var floatingCapsuleChannel: MethodChannel? = null
    private var aiTtsChannel: MethodChannel? = null
    private var aiTts: TextToSpeech? = null
    private var aiTtsReady = false
    private var aiTtsInitializing = false
    private val pendingAiTtsInitResults = mutableListOf<MethodChannel.Result>()
    private var pendingAiTtsSpeakResult: MethodChannel.Result? = null
    private var pendingAiTtsUtteranceId: String? = null
    private var foregroundMediaKeysEnabled = false

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
        aiTtsChannel?.setMethodCallHandler(null)
        aiTtsChannel = null
        releaseAiTts()
        FloatCapsuleManager.clearCallbacks()
        super.onDestroy()
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
