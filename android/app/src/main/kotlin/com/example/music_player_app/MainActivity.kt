package com.example.music_player_app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.annotation.NonNull
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    companion object {
        const val CHANNEL = "music_player/floating_capsule"
        const val INSTALL_CHANNEL = "music_player/install"
        const val FAVORITES_FILE_CHANNEL = "music_player/favorites_file"
        const val REQUEST_IMPORT_FAVORITES = 4101
        const val REQUEST_EXPORT_FAVORITES = 4102
    }

    private var pendingFileResult: MethodChannel.Result? = null
    private var pendingExportContent: String? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val appContext = applicationContext

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
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
                                    runOnUiThread {
                                        MethodChannel(
                                            flutterEngine.dartExecutor.binaryMessenger, CHANNEL
                                        ).invokeMethod("onPlayPauseTap", null)
                                    }
                                },
                                onTap = {
                                    runOnUiThread {
                                        MethodChannel(
                                            flutterEngine.dartExecutor.binaryMessenger, CHANNEL
                                        ).invokeMethod("onCapsuleTap", null)
                                    }
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
        } catch (_: ActivityNotFoundException) {
            pendingFileResult = null
            result.error("UNSUPPORTED", "系统没有可用的文件选择器", null)
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
            putExtra(Intent.EXTRA_TITLE, fileName ?: "kuzai-music-favorites.json")
        }
        try {
            pendingFileResult = result
            pendingExportContent = content
            startActivityForResult(intent, REQUEST_EXPORT_FAVORITES)
        } catch (_: ActivityNotFoundException) {
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
                val content = contentResolver.openInputStream(uri)
                    ?.bufferedReader(Charsets.UTF_8)
                    ?.use { it.readText() }
                    ?: throw IllegalStateException("无法读取所选文件")
                if (content.length > 5 * 1024 * 1024) {
                    throw IllegalArgumentException("收藏备份不能超过 5 MB")
                }
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
        } catch (error: Exception) {
            callback.error("FILE_ERROR", error.message ?: "文件操作失败", null)
        } finally {
            pendingExportContent = null
        }
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
                } catch (_: ActivityNotFoundException) {
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
