import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/playback_package.dart';
import 'bounded_http_response.dart';

/// 管理已签名的本地解析包；更新失败不进入播放依赖。SHIXIAOYANG，2026/11/21。
class PlaybackPackageStore {
  static const updateBase =
      'https://137.175.62.3:8443/music-player-api/updates/';
  static final Set<String> _writingDirectories = {};

  final Directory? root;
  final String publicKey;
  final http.Client _client;
  final Uri _base;
  final Future<PlaybackPackage> Function()? _bundledLoader;
  final Future<Directory> Function()? _directoryLoader;
  final Future<void> Function(PlaybackPackage)? _validator;
  final bool Function(Object)? _isPackageFailure;
  final Set<Completer<void>> _activeRequests = {};
  Future<PlaybackPackage>? _ready;
  Future<Directory?>? _directory;
  final Completer<void> _closeSignal = Completer<void>();
  Timer? _directoryTimer;
  Future<bool>? _checking;
  Future<bool>? _rollingBack;
  final Set<Completer<void>> _rollbackCancellations = {};
  Completer<void>? _updateCancellation;
  PlaybackPackage? _current;
  _PackagePointer _pointer = const _PackagePointer();
  bool _closed = false;
  String? updateError;

  /// [root] 保存解析包缓存；[bundledLoader] 提供可信内置包，磁盘失败时仍可启动。
  /// [validator] 在激活更新前检查脚本运行能力，不参与首次本地资源选择。
  PlaybackPackageStore({
    this.root,
    this.publicKey = PlaybackPackageManifest.publicKeyBase64,
    Future<PlaybackPackage> Function()? bundledLoader,
    Future<Directory> Function()? directoryLoader,
    http.Client? client,
    Uri? updateServer,
    Future<void> Function(PlaybackPackage)? validator,
    bool Function(Object)? isPackageFailure,
  }) : _bundledLoader = bundledLoader,
       _directoryLoader = directoryLoader,
       _client = client ?? http.Client(),
       _base = updateServer ?? Uri.parse(updateBase),
       _validator = validator,
       _isPackageFailure = isPackageFailure;

  /// 只初始化本地文件或内置资产，绝不等待更新接口。
  Future<PlaybackPackage> get ready {
    if (_closed) {
      return Future<PlaybackPackage>.error(
        const HttpRequestCancelledException(),
      );
    }
    final active = _current;
    return active == null
        ? (_ready ??= _initialize())
        : Future<PlaybackPackage>.value(active);
  }

  /// 当前已验证的内存快照，读取时不会等待磁盘或网络。
  PlaybackPackage? get current => _current;
  bool get checking => _checking != null;
  int get activeRequestCount => _activeRequests.length;

  void _ensureOpen() {
    if (_closed) throw const HttpRequestCancelledException();
  }

  Future<Directory?> _getDirectory() => _directory ??= _findDirectory();

  Future<Directory?> _findDirectory() async {
    // 平台目录不可用时，内置包仍可在内存中使用。
    _ensureOpen();
    if (root != null) return root!.absolute;
    final completion = Completer<Directory>();
    void receive(Directory directory) {
      if (!completion.isCompleted) completion.complete(directory);
    }

    void failure(Object error, StackTrace stack) {
      if (!completion.isCompleted) completion.completeError(error, stack);
    }

    void expire() {
      failure(TimeoutException('解析包目录查询超时'), StackTrace.current);
    }

    // 显式保存定时器，关闭时立即取消，不让平台迟到结果继续初始化。
    final timer = Timer(const Duration(seconds: 1), expire);
    _directoryTimer = timer;
    try {
      (_directoryLoader?.call() ?? getApplicationSupportDirectory()).then<void>(
        receive,
        onError: failure,
      );
      final support = await awaitWithCancellation(
        completion.future,
        _closeSignal.future,
      );
      _ensureOpen();
      return Directory('${support.path}/playback_packages_v1');
    } on HttpRequestCancelledException {
      rethrow;
    } catch (error) {
      debugPrint('解析包存储目录不可用: ${error.runtimeType}');
      return null;
    } finally {
      timer.cancel();
      _directoryTimer = null;
    }
  }

  Future<PlaybackPackage> _loadBundled() async {
    if (_bundledLoader != null) return _bundledLoader();
    final envelope = await rootBundle.load(
      'assets/playback_sources/manifest.json',
    );
    final bytes = await rootBundle.load('assets/playback_sources/bundle.json');
    return PlaybackPackage.verify(
      envelope.buffer.asUint8List(
        envelope.offsetInBytes,
        envelope.lengthInBytes,
      ),
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      publicKey: publicKey,
    );
  }

  Future<PlaybackPackage> _initialize() async {
    _ensureOpen();
    PlaybackPackage? bundled;
    PlaybackPackage? cached;
    // 内置资产无需先写磁盘，首次离线与低空间均有可用版本。
    try {
      bundled = await _loadBundled();
    } catch (error) {
      debugPrint('内置解析包校验失败: ${error.runtimeType}');
    }
    _ensureOpen();
    final directory = await _getDirectory();
    if (directory != null) {
      try {
        _pointer = await _readPointerOrEmpty(directory);
        cached = await _restore(directory, _pointer);
      } catch (error) {
        debugPrint('本地解析包不可用: ${error.runtimeType}');
      }
    }
    _ensureOpen();
    final selected =
        cached != null &&
            (bundled == null || cached.packageVersion >= bundled.packageVersion)
        ? cached
        : bundled;
    if (selected == null) throw const FormatException('没有可用的本地解析包');
    _current = selected;
    return selected;
  }

  Future<_PackagePointer> _readPointerOrEmpty(Directory directory) async {
    try {
      return await _readPointer(directory);
    } on FormatException {
      return const _PackagePointer();
    } on FileSystemException {
      return const _PackagePointer();
    }
  }

  Future<_PackagePointer> _readPointer(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return const _PackagePointer();
    if (type != FileSystemEntityType.directory) {
      throw const FormatException('解析包目录无效');
    }
    final file = File('${directory.path}/active.json');
    if (!await file.exists()) return const _PackagePointer();
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > 8192) {
      throw const FormatException('解析包状态无效');
    }
    return _PackagePointer.fromJson(jsonDecode(await file.readAsString()));
  }

  Future<PlaybackPackage?> _restore(
    Directory directory,
    _PackagePointer pointer,
  ) async {
    // 当前包损坏时先尝试上一版本；只扫描有界的本项目版本目录。
    for (final id in [pointer.currentId, pointer.previousId]) {
      if (id == null) continue;
      final result = await _tryLoad(directory, id);
      if (result != null) return result;
    }
    if (!await directory.exists()) return null;
    final entries = await directory.list(followLinks: false).take(64).toList();
    final ids = <String>[];
    for (final entry in entries) {
      final id = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      if (entry is Directory && _PackagePointer.validId(id)) ids.add(id);
    }
    ids.sort(
      (a, b) => int.parse(b.substring(1)).compareTo(int.parse(a.substring(1))),
    );
    for (final id in ids.take(32)) {
      final result = await _tryLoad(directory, id);
      if (result != null) return result;
    }
    return null;
  }

  Future<PlaybackPackage?> _tryLoad(Directory root, String id) async {
    try {
      final directory = Directory('${root.path}/$id');
      if (!_PackagePointer.validId(id) ||
          await FileSystemEntity.type(directory.path, followLinks: false) !=
              FileSystemEntityType.directory) {
        return null;
      }
      final envelope = File('${directory.path}/manifest.json');
      final bytes = File('${directory.path}/bundle.json');
      if (await FileSystemEntity.type(envelope.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await FileSystemEntity.type(bytes.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await envelope.length() > PlaybackPackageManifest.maxManifestBytes ||
          await bytes.length() > PlaybackPackageManifest.maxPackageBytes) {
        return null;
      }
      final result = await PlaybackPackage.verify(
        await envelope.readAsBytes(),
        await bytes.readAsBytes(),
        publicKey: publicKey,
      );
      return result.manifest.id == id ? result : null;
    } catch (error) {
      debugPrint('缓存解析包校验失败: ${error.runtimeType}');
      return null;
    }
  }

  /// 合并重复更新；网络、签名或试启动失败均继续使用当前本地包。
  Future<bool> checkUpdate() {
    if (_closed) return Future<bool>.value(false);
    return _checking ??= _checkUpdate();
  }

  Future<bool> _checkUpdate() async {
    final cancellation = Completer<void>();
    _updateCancellation = cancellation;
    updateError = null;
    try {
      await ready;
      _ensureOpen();
      final manifest = await PlaybackPackageManifest.verify(
        await _get('manifest.json', PlaybackPackageManifest.maxManifestBytes),
        publicKey: publicKey,
      );
      if (manifest.packageVersion <= _pointer.highestVersion ||
          manifest.packageVersion <= _current!.packageVersion) {
        return false;
      }
      final candidate = PlaybackPackage.fromVerifiedManifest(
        manifest,
        await _get(manifest.packagePath, manifest.bytes),
      );
      // 新脚本先试启动，再落盘和切指针，坏版本不会影响已有运行时。
      try {
        if (_validator != null) {
          await _validate(candidate, cancellation.future);
        }
      } catch (error) {
        // 任务繁忙或引擎暂不可用不是包错误，不能永久屏蔽合法版本。
        final failedPackage =
            _isPackageFailure?.call(error) ?? error is FormatException;
        if (!_closed && failedPackage) {
          await _recordRejected(candidate.packageVersion);
        }
        rethrow;
      }
      _ensureOpen();
      return await _commit(candidate);
    } catch (error) {
      if (!_closed) {
        updateError = '解析包更新失败，继续使用本地版本';
        debugPrint('解析包更新失败: ${error.runtimeType}');
      }
      return false;
    } finally {
      if (!cancellation.isCompleted) cancellation.complete();
      _updateCancellation = null;
      _checking = null;
    }
  }

  Future<void> _validate(
    PlaybackPackage candidate,
    Future<void> cancelSignal,
  ) async {
    if (_validator == null) return;
    final completion = Completer<void>();
    void success() {
      if (!completion.isCompleted) completion.complete();
    }

    void receive(dynamic ignored) {
      success();
    }

    void failure(Object error, StackTrace stack) {
      if (!completion.isCompleted) completion.completeError(error, stack);
    }

    void expire() {
      failure(TimeoutException('解析包试启动超时'), StackTrace.current);
    }

    final timer = Timer(const Duration(seconds: 3), expire);
    try {
      _validator(candidate).then<void>(receive, onError: failure);
      await awaitWithCancellation(completion.future, cancelSignal);
    } finally {
      timer.cancel();
      success();
    }
  }

  /// 运行时确认当前包故障后恢复上一包或内置包，不访问更新服务器。
  Future<bool> rollback(int packageVersion) {
    if (_closed || _current?.packageVersion != packageVersion) {
      return Future<bool>.value(false);
    }
    return _rollingBack ??= _rollback(packageVersion);
  }

  Future<bool> _rollback(int version) async {
    final cancellation = Completer<void>();
    _rollbackCancellations.add(cancellation);
    try {
      final directory = await _getDirectory();
      final candidates = <PlaybackPackage>[];
      if (directory != null) {
        final latest = await _readPointerOrEmpty(directory);
        final previousId = latest.previousId;
        if (previousId != null) {
          final previous = await _tryLoad(directory, previousId);
          if (previous != null && previous.packageVersion != version) {
            candidates.add(previous);
          }
        }
      }
      // 内置版本始终可用作无磁盘兜底，恢复时也先检查运行时兼容性。
      try {
        final bundled = await _loadBundled();
        if (bundled.packageVersion != version) candidates.add(bundled);
      } catch (error) {
        debugPrint('解析包恢复的内置版本不可用: ${error.runtimeType}');
      }
      candidates.sort((a, b) => b.packageVersion.compareTo(a.packageVersion));
      for (final candidate in candidates) {
        try {
          await _validate(candidate, cancellation.future);
        } catch (error) {
          if (_closed) return false;
          continue;
        }
        _ensureOpen();
        if (_current?.packageVersion != version) return false;
        await _recordRejected(version);
        if (directory != null) {
          await _persistRecovery(directory, candidate, version);
        }
        _ensureOpen();
        if (_current?.packageVersion != version) return false;
        _current = candidate;
        return true;
      }
      return false;
    } catch (error) {
      if (!_closed) debugPrint('本地解析包恢复失败: ${error.runtimeType}');
      return false;
    } finally {
      if (!cancellation.isCompleted) cancellation.complete();
      _rollbackCancellations.remove(cancellation);
      _rollingBack = null;
    }
  }

  Future<void> _persistRecovery(
    Directory directory,
    PlaybackPackage candidate,
    int failedVersion,
  ) async {
    final key = directory.absolute.path;
    if (!_writingDirectories.add(key)) return;
    RandomAccessFile? lock;
    try {
      await directory.create(recursive: true);
      lock = await File(
        '${directory.path}/commit.lock',
      ).open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final latest = await _readPointerOrEmpty(directory);
      if (latest.highestVersion > failedVersion &&
          latest.currentId != _current?.manifest.id) {
        return;
      }
      final cached = await _tryLoad(directory, candidate.manifest.id);
      final highest = latest.highestVersion > failedVersion
          ? latest.highestVersion
          : failedVersion;
      final next = _PackagePointer(
        currentId: cached?.manifest.id,
        highestVersion: highest,
      );
      await _writePointer(directory, next);
      _pointer = next;
      await _cleanup(directory, next.keepIds);
    } catch (error) {
      // 磁盘不能写入时，仍允许切到已验证的内存内置包。
      debugPrint('恢复版本未写入磁盘: ${error.runtimeType}');
    } finally {
      try {
        if (lock != null) await lock.close();
      } finally {
        _writingDirectories.remove(key);
      }
    }
  }

  Future<List<int>> _get(String relative, int maximum) async {
    _ensureOpen();
    final endpoint = _base.resolve(relative);
    if (endpoint.origin != _base.origin || relative.contains('..')) {
      throw const FormatException('只能访问固定解析包更新服务');
    }
    final cancellation = Completer<void>();
    _activeRequests.add(cancellation);
    try {
      final request = http.Request('GET', endpoint)..followRedirects = false;
      final response = await sendBoundedHttpRequest(
        _client,
        request,
        maxBytes: maximum,
        timeout: const Duration(seconds: 5),
        totalTimeout: const Duration(seconds: 12),
        cancelSignal: cancellation.future,
      );
      _ensureOpen();
      if (response.statusCode != 200) throw const HttpException('解析包更新接口不可用');
      return response.bodyBytes;
    } finally {
      _activeRequests.remove(cancellation);
      if (!cancellation.isCompleted) cancellation.complete();
    }
  }

  Future<bool> _commit(PlaybackPackage candidate) async {
    final directory = await _getDirectory();
    if (directory == null) throw const FileSystemException('解析包目录不可用');
    await directory.create(recursive: true);
    final key = directory.absolute.path;
    if (!_writingDirectories.add(key)) {
      throw const FileSystemException('解析包提交正在进行');
    }
    RandomAccessFile? lock;
    Directory? staging;
    var pointerSwitched = false;
    var committed = false;
    var destinationCreated = false;
    final destination = Directory('${directory.path}/${candidate.manifest.id}');
    try {
      // 同进程拒绝重叠提交；文件锁保护其他实例，网络从不持有这些锁。
      lock = await File(
        '${directory.path}/commit.lock',
      ).open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final latest = await _readPointerOrEmpty(directory);
      final validDisk = await _restore(directory, latest);
      if (candidate.packageVersion <= latest.highestVersion ||
          candidate.packageVersion <= (validDisk?.packageVersion ?? 0)) {
        return false;
      }
      final keep = latest.keepIds;
      if (validDisk != null) keep.add(validDisk.manifest.id);
      await _cleanup(directory, keep);
      _ensureOpen();
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const FileSystemException('解析包目标版本已经存在');
      }
      staging = await directory.createTemp(
        '.staging-${candidate.manifest.id}-',
      );
      await File(
        '${staging.path}/manifest.json',
      ).writeAsBytes(candidate.manifest.envelopeBytes, flush: true);
      _ensureOpen();
      await File(
        '${staging.path}/bundle.json',
      ).writeAsBytes(candidate.packageBytes, flush: true);
      _ensureOpen();
      await staging.rename(destination.path);
      destinationCreated = true;
      staging = null;
      _ensureOpen();
      final next = _PackagePointer(
        currentId: candidate.manifest.id,
        previousId: validDisk?.manifest.id,
        highestVersion: candidate.packageVersion,
      );
      await _writePointer(directory, next);
      pointerSwitched = true;
      // 关闭恰好发生在原子写入完成时，恢复旧指针后再清理未激活文件。
      if (_closed) {
        await _writePointer(directory, latest, allowClosed: true);
        pointerSwitched = false;
        throw const HttpRequestCancelledException();
      }
      _pointer = next;
      _current = candidate;
      committed = true;
      try {
        await _cleanup(directory, next.keepIds);
      } catch (error) {
        debugPrint('解析包已更新，旧文件清理失败: ${error.runtimeType}');
      }
      return true;
    } finally {
      // 失败只删除本轮暂存/未激活版本，旧有效包和指针保留。
      try {
        if (staging != null && await staging.exists()) {
          await staging.delete(recursive: true);
        }
        if (destinationCreated &&
            !committed &&
            !pointerSwitched &&
            await destination.exists()) {
          await destination.delete(recursive: true);
        }
      } finally {
        try {
          await lock?.close();
        } finally {
          _writingDirectories.remove(key);
        }
      }
    }
  }

  Future<void> _recordRejected(int version) async {
    _ensureOpen();
    // 即使磁盘故障，也在本次会话记住坏版本，避免重复下载和试启动。
    if (version > _pointer.highestVersion) {
      _pointer = _PackagePointer(
        currentId: _pointer.currentId,
        previousId: _pointer.previousId,
        highestVersion: version,
      );
    }
    final directory = await _getDirectory();
    _ensureOpen();
    if (directory == null) return;
    final key = directory.absolute.path;
    if (!_writingDirectories.add(key)) return;
    RandomAccessFile? lock;
    try {
      await directory.create(recursive: true);
      lock = await File(
        '${directory.path}/commit.lock',
      ).open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final latest = await _readPointerOrEmpty(directory);
      if (version > latest.highestVersion) {
        final next = _PackagePointer(
          currentId: latest.currentId,
          previousId: latest.previousId,
          highestVersion: version,
        );
        await _writePointer(directory, next);
        _ensureOpen();
        _pointer = next;
      }
    } catch (error) {
      debugPrint('坏解析包版本记录失败: ${error.runtimeType}');
    } finally {
      try {
        if (lock != null) await lock.close();
      } finally {
        _writingDirectories.remove(key);
      }
    }
  }

  Future<void> _writePointer(
    Directory directory,
    _PackagePointer pointer, {
    bool allowClosed = false,
  }) async {
    if (!allowClosed) _ensureOpen();
    final temporary = File('${directory.path}/active.json.part');
    await temporary.writeAsString(jsonEncode(pointer.toJson()), flush: true);
    if (!allowClosed) _ensureOpen();
    await temporary.rename('${directory.path}/active.json');
  }

  Future<void> _cleanup(Directory directory, Set<String> keep) async {
    final entries = await directory.list(followLinks: false).take(128).toList();
    for (final entry in entries) {
      final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      final owned =
          entry is Directory &&
          (_PackagePointer.validId(name) || name.startsWith('.staging-p'));
      if (owned && !keep.contains(name)) await entry.delete(recursive: true);
    }
  }

  /// 同步取消更新网络和试启动等待，关闭后任何迟到结果不得发布。
  void close() {
    if (_closed) return;
    _closed = true;
    _directoryTimer?.cancel();
    _directoryTimer = null;
    _closeSignal.complete();
    for (final cancellation in _activeRequests) {
      if (!cancellation.isCompleted) cancellation.complete();
    }
    _activeRequests.clear();
    final update = _updateCancellation;
    if (update != null && !update.isCompleted) update.complete();
    for (final rollback in _rollbackCancellations) {
      if (!rollback.isCompleted) rollback.complete();
    }
    _rollbackCancellations.clear();
    _client.close();
  }
}

class _PackagePointer {
  final String? currentId;
  final String? previousId;
  final int highestVersion;
  const _PackagePointer({
    this.currentId,
    this.previousId,
    this.highestVersion = 0,
  });
  Set<String> get keepIds => {
    if (currentId != null) currentId!,
    if (previousId != null) previousId!,
  };
  static bool validId(String id) => RegExp(r'^p[0-9]{6,9}$').hasMatch(id);
  factory _PackagePointer.fromJson(dynamic value) {
    if (value is! Map<String, dynamic> ||
        value['highestVersion'] is! int ||
        (value['highestVersion'] as int) < 0 ||
        (value['highestVersion'] as int) > 999999999) {
      throw const FormatException('解析包状态字段无效');
    }
    for (final name in ['current', 'previous']) {
      final id = value[name];
      if (id != null && (id is! String || !validId(id))) {
        throw const FormatException('解析包状态路径无效');
      }
    }
    return _PackagePointer(
      currentId: value['current'] as String?,
      previousId: value['previous'] as String?,
      highestVersion: value['highestVersion'] as int,
    );
  }
  Map<String, dynamic> toJson() => {
    'current': currentId,
    'previous': previousId,
    'highestVersion': highestVersion,
  };
}
