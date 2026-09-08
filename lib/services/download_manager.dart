import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/download_entry.dart';
import '../models/song.dart';
import 'bounded_http_response.dart';
import 'user_data_scope.dart';

typedef DownloadResolver =
    Future<SongDetail> Function(
      SongSearchResult song,
      String quality,
      bool Function() cancelled,
      Future<void> cancelSignal,
    );

class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.scope,
    required DownloadResolver resolve,
    Directory? directory,
  }) : _resolve = resolve,
       _directoryOverride = directory {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          final length = int.tryParse(
            response.headers.value('content-length') ?? '',
          );
          if (length != null && length > maxAudioBytes) {
            response.requestOptions.cancelToken?.cancel('too-large');
            handler.reject(
              DioException(
                requestOptions: response.requestOptions,
                error: 'too-large',
              ),
            );
          } else {
            handler.next(response);
          }
        },
      ),
    );
  }
  static const channel = MethodChannel('music_player/downloads');
  static const networkChannel = EventChannel('music_player/download_network');
  static const maxTasks = 100;
  static const maxAudioBytes = 256 * 1024 * 1024;
  static const preferenceKey = 'downloads_v1';
  final UserDataScope scope;
  final DownloadResolver _resolve;
  final Directory? _directoryOverride;
  late final Future<void> ready = _load();
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );
  final List<DownloadEntry> _entries = [];
  List<DownloadEntry> get entries => UnmodifiableListView(_entries);
  bool wifiOnly = true;
  bool wifiConnected = false;
  String? error;
  bool _loadFailed = false;
  bool _loaded = false;
  bool _disposed = false;
  bool _closing = false;
  bool _suspended = false;
  bool _savingSettings = false;
  final Set<String> _removing = {};
  Future<void>? _work;
  Future<void>? _closeFuture;
  Future<void>? _networkReady;
  StreamSubscription<dynamic>? _networkSub;
  CancelToken? _cancel;
  DownloadEntry? _active;
  Completer<void>? _activeDone;
  Future<void>? _persisting;
  bool _persistAgain = false;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _alive => !_disposed && !_closing && !_suspended && !scope.isDeleted;
  void _notify() {
    if (!_disposed && !_closing && !scope.isDeleted) notifyListeners();
  }

  static String _userFolder(UserDataScope scope) =>
      sha256.convert(utf8.encode(scope.userId)).toString().substring(0, 16);
  static Future<void> deleteUserFiles(UserDataScope scope) async {
    if (scope.isDefault) return;
    final base = await getApplicationDocumentsDirectory().timeout(
      const Duration(seconds: 3),
    );
    final root = Directory(p.join(base.path, 'downloads'));
    final folder = Directory(p.join(root.path, _userFolder(scope)));
    if (!await folder.exists()) return;
    final canonicalRoot = await root.resolveSymbolicLinks();
    final canonicalFolder = await folder.resolveSymbolicLinks();
    if (!p.isWithin(canonicalRoot, canonicalFolder)) {
      throw const FileSystemException('用户下载目录无效');
    }
    await folder.delete(recursive: true);
  }

  Future<Directory> _directory() async {
    if (_directoryOverride != null) return _directoryOverride;
    final base = await getApplicationDocumentsDirectory().timeout(
      const Duration(seconds: 3),
    );
    return Directory(p.join(base.path, 'downloads', _userFolder(scope)));
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || _closing || scope.isDeleted) return;
      _loaded = true;
      final raw = prefs.getString(scope.preferenceKey(preferenceKey));
      if (raw == null) return;
      if (raw.length > 1024 * 1024) throw const FormatException('下载索引过大');
      final json = jsonDecode(raw);
      if (json is! Map ||
          json['entries'] is! List ||
          (json['entries'] as List).length > maxTasks ||
          json['wifiOnly'] is! bool) {
        throw const FormatException('下载索引无效');
      }
      final parsed = <DownloadEntry>[];
      final ids = <String>{};
      for (final rawEntry in json['entries'] as List) {
        if (rawEntry is! Map) throw const FormatException('下载记录无效');
        final entry = DownloadEntry.fromJson(
          Map<String, dynamic>.from(rawEntry),
        );
        if (!ids.add(entry.id)) throw const FormatException('下载记录重复');
        if (entry.status == DownloadStatus.queued ||
            entry.status == DownloadStatus.downloading ||
            entry.status == DownloadStatus.processing) {
          entry.status = DownloadStatus.paused;
        }
        parsed.add(entry);
      }
      wifiOnly = json['wifiOnly'] as bool;
      _entries.addAll(parsed);
    } catch (failure) {
      _loadFailed = true;
      error = '下载记录读取失败：$failure';
    } finally {
      _notify();
    }
  }

  Future<void> initializeNetwork() => _networkReady ??= _initializeNetwork();
  Future<void> _initializeNetwork() async {
    try {
      final wifi = await channel
          .invokeMethod<bool>('wifi')
          .timeout(const Duration(seconds: 3));
      if (!_alive) return;
      _setWifi(wifi == true);
      _networkSub = networkChannel.receiveBroadcastStream().distinct().listen(
        (value) => _setWifi(value == true),
        onError: (Object _) => _setWifi(false),
      );
    } on MissingPluginException {
      if (_alive) _setWifi(false);
    } catch (failure) {
      if (_alive) {
        error = '无法检测网络状态';
        _setWifi(false);
      }
    }
  }

  void _setWifi(bool value) {
    if (!_alive) return;
    wifiConnected = value;
    if (wifiOnly &&
        !value &&
        _active != null &&
        (_active!.status == DownloadStatus.downloading ||
            _active!.status == DownloadStatus.processing)) {
      _active!.status = DownloadStatus.queued;
      _cancel?.cancel('wifi');
    }
    _notify();
    _pump();
  }

  Future<void> setWifiOnly(bool value) async {
    await ready;
    if (!_alive) return;
    if (_savingSettings) throw StateError('正在保存下载设置');
    _savingSettings = true;
    final previous = wifiOnly;
    wifiOnly = value;
    try {
      try {
        await _persist();
      } catch (_) {
        wifiOnly = previous;
        rethrow;
      }
      await initializeNetwork();
      if (_alive) _setWifi(wifiConnected);
    } finally {
      _savingSettings = false;
    }
  }

  Future<DownloadEntry> enqueue(SongSearchResult song, String quality) async {
    await ready;
    if (!_alive || _loadFailed) throw StateError(error ?? '下载管理器已关闭');
    if (song.platform == MusicPlatform.local ||
        song.downloadId != null ||
        quality.length > 32 ||
        quality.isEmpty) {
      throw ArgumentError('音频无需下载或音质无效');
    }
    final compact = song.compactForPlaybackPersistence();
    if (jsonEncode(compact.toJson()).length > 8192) {
      throw const FormatException('歌曲元数据过大');
    }
    final id = sha256
        .convert(
          utf8.encode(
            '${song.platform.code}:${song.id}:${song.bilibiliCid ?? 0}:$quality',
          ),
        )
        .toString()
        .substring(0, 24);
    if (_removing.contains(id)) throw StateError('正在移除下载，请稍后重试');
    final previous = _entries.where((entry) => entry.id == id).firstOrNull;
    if (previous != null) {
      if (previous.status == DownloadStatus.failed ||
          previous.status == DownloadStatus.paused) {
        await resume(previous);
      }
      return previous;
    }
    if (_entries.length >= maxTasks) {
      throw StateError('下载任务已达 $maxTasks 条，请先移除不需要的下载');
    }
    final entry = DownloadEntry(id: id, song: compact, quality: quality);
    _entries.add(entry);
    try {
      await _persist();
    } catch (_) {
      _entries.remove(entry);
      rethrow;
    }
    _notify();
    await initializeNetwork();
    _pump();
    return entry;
  }

  Future<void> pause(DownloadEntry entry) async {
    if (!_alive ||
        !_entries.contains(entry) ||
        _removing.contains(entry.id) ||
        entry.status == DownloadStatus.completed) {
      return;
    }
    entry.status = DownloadStatus.paused;
    if (identical(entry, _active)) _cancel?.cancel('paused');
    await _persist();
    _notify();
  }

  Future<void> resume(DownloadEntry entry) async {
    await ready;
    if (!_alive ||
        !_entries.contains(entry) ||
        _removing.contains(entry.id) ||
        entry.status == DownloadStatus.completed ||
        identical(entry, _active)) {
      return;
    }
    entry.status = DownloadStatus.queued;
    entry.error = null;
    await _persist();
    await initializeNetwork();
    _notify();
    _pump();
  }

  Future<void> remove(DownloadEntry entry) async {
    if (!_alive || !_entries.contains(entry)) return;
    if (!_removing.add(entry.id)) return;
    try {
      if (identical(_active, entry)) {
        entry.status = DownloadStatus.paused;
        final done = _activeDone;
        _cancel?.cancel('remove');
        await done?.future;
      }
      if (!_alive) return;
      final previousIndex = _entries.indexOf(entry);
      _entries.remove(entry);
      try {
        await _persist();
      } catch (_) {
        _entries.insert(previousIndex.clamp(0, _entries.length), entry);
        rethrow;
      }
      final folder = await _directory();
      // Remove only names derived from a validated task id, never imported paths.
      for (final name in [
        entry.fileName,
        '${entry.id}.lrc',
        '${entry.id}.cover.jpg',
      ]) {
        if (name == null) continue;
        final file = await _ownedFile(folder, 'media', name);
        if (await file.exists()) await file.delete();
      }
      _notify();
    } finally {
      _removing.remove(entry.id);
    }
  }

  Future<String?> playablePath(String id) async {
    await ready;
    if (!DownloadEntry.idPattern.hasMatch(id) || scope.isDeleted) return null;
    final entry = _entries
        .where(
          (value) => value.id == id && value.status == DownloadStatus.completed,
        )
        .firstOrNull;
    if (entry?.fileName == null) return null;
    final file = await _ownedFile(
      await _directory(),
      'media',
      entry!.fileName!,
    );
    return await file.exists() && await file.length() > 0 ? file.path : null;
  }

  Future<String?> lyricsFor(String id) async {
    if (!DownloadEntry.idPattern.hasMatch(id)) return null;
    final file = await _ownedFile(await _directory(), 'media', '$id.lrc');
    if (!await file.exists() || await file.length() > 256 * 1024) return null;
    return file.readAsString();
  }

  Future<File> _ownedFile(Directory root, String subfolder, String name) async {
    if (p.basename(name) != name ||
        !RegExp(
          r'^[a-f0-9]{24}\.(mp3|flac|m4a|aac|ogg|opus|wav|ape|audio|lrc|cover\.jpg)$',
        ).hasMatch(name)) {
      throw const FormatException('下载文件名无效');
    }
    final parent = Directory(p.join(root.path, subfolder));
    await parent.create(recursive: true);
    final canonicalRoot = await root.resolveSymbolicLinks();
    final canonicalParent = await parent.resolveSymbolicLinks();
    if (!p.isWithin(canonicalRoot, canonicalParent)) {
      throw const FileSystemException('下载目录无效');
    }
    final file = File(p.join(canonicalParent, name));
    if (await file.exists() &&
        !p.isWithin(canonicalRoot, await file.resolveSymbolicLinks())) {
      throw const FileSystemException('下载文件不在应用目录内');
    }
    return file;
  }

  void _pump() {
    if (!_alive || _work != null || (wifiOnly && !wifiConnected)) return;
    final work = _run();
    _work = work;
    unawaited(
      work.then(
        (_) {
          _work = null;
          if (_alive &&
              _entries.any(
                (entry) =>
                    entry.status == DownloadStatus.queued &&
                    !_removing.contains(entry.id),
              ) &&
              (!wifiOnly || wifiConnected)) {
            _pump();
          }
        },
        onError: (Object failure) {
          _work = null;
          if (_alive) {
            error = '下载状态保存失败：$failure';
            _notify();
          }
        },
      ),
    );
  }

  Future<void> _run() async {
    while (_alive && (!wifiOnly || wifiConnected)) {
      final entry = _entries
          .where(
            (value) =>
                value.status == DownloadStatus.queued &&
                !_removing.contains(value.id),
          )
          .firstOrNull;
      if (entry == null) return;
      _active = entry;
      final done = _activeDone = Completer<void>();
      final cancel = _cancel = CancelToken();
      try {
        await _download(entry, cancel);
      } finally {
        _active = null;
        _cancel = null;
        _activeDone = null;
        done.complete();
      }
    }
  }

  Future<void> _download(DownloadEntry entry, CancelToken cancel) async {
    var committed = false;
    File? raw;
    File? cover;
    File? lyricFile;
    File? tagged;
    File? published;
    Timer? timeout;
    StreamSubscription<void>? tagCancellation;
    try {
      entry.status = DownloadStatus.downloading;
      entry.error = null;
      entry.warning = null;
      entry.received = 0;
      entry.total = 0;
      await _persist();
      _notify();
      if (cancel.isCancelled || !_alive) return;
      timeout = Timer(
        const Duration(minutes: 10),
        () => cancel.cancel('timeout'),
      );
      final cancelSignal = cancel.whenCancel.then<void>((_) {});
      final detail = await awaitWithCancellation(
        _resolve(
          entry.song,
          entry.quality,
          () => cancel.isCancelled || !_alive,
          cancelSignal,
        ),
        cancelSignal,
      );
      if (cancel.isCancelled || !_alive) return;
      final uri = Uri.tryParse(detail.url);
      if (uri == null ||
          !const ['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('下载地址无效');
      }
      final root = await _directory();
      final candidate =
          (detail.format ?? p.extension(uri.path).replaceFirst('.', ''))
              .toLowerCase();
      final extension =
          const [
            'mp3',
            'flac',
            'm4a',
            'aac',
            'ogg',
            'opus',
            'wav',
            'ape',
          ].contains(candidate)
          ? candidate
          : 'audio';
      final name = '${entry.id}.$extension';
      raw = await _ownedFile(root, 'staging', name);
      await _dio.download(
        detail.url,
        raw.path,
        cancelToken: cancel,
        options: Options(headers: detail.playbackHeaders),
        onReceiveProgress: (received, total) {
          if (!_alive || cancel.isCancelled) return;
          if (received > maxAudioBytes || total > maxAudioBytes) {
            cancel.cancel('too-large');
            return;
          }
          entry.received = received;
          entry.total = total;
          final now = DateTime.now();
          if (now.difference(_lastProgress).inMilliseconds >= 200) {
            _lastProgress = now;
            _notify();
          }
        },
      );
      if (cancel.isCancelled || !_alive) return;
      final length = await raw.length();
      if (length < 1024 || length > maxAudioBytes) {
        throw const FormatException('音频文件为空或过大');
      }
      entry.status = DownloadStatus.processing;
      _notify();
      String? lyrics = detail.lyric;
      if (lyrics != null &&
          utf8.encode(lyrics).length <= 256 * 1024 &&
          lyrics.isNotEmpty) {
        lyricFile = await _ownedFile(root, 'staging', '${entry.id}.lrc');
        await lyricFile.writeAsString(lyrics, flush: true);
      } else {
        lyrics = null;
      }
      final coverUrl = entry.song.coverUrl;
      if (coverUrl != null && coverUrl.startsWith('https://')) {
        final client = http.Client();
        try {
          final response = await sendBoundedHttpRequest(
            client,
            http.Request('GET', Uri.parse(coverUrl)),
            maxBytes: 2 * 1024 * 1024,
            timeout: const Duration(seconds: 8),
            totalTimeout: const Duration(seconds: 12),
            cancelSignal: cancel.whenCancel.then<void>((_) {}),
          );
          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            cover = await _ownedFile(root, 'staging', '${entry.id}.cover.jpg');
            await cover.writeAsBytes(response.bodyBytes, flush: true);
          }
        } catch (_) {
          entry.warning = '封面未保存';
        } finally {
          client.close();
        }
      }
      if (cancel.isCancelled || !_alive) return;
      if (!kIsWeb &&
          defaultTargetPlatform == TargetPlatform.android &&
          const [
            'mp3',
            'flac',
            'm4a',
            'ogg',
            'opus',
            'ape',
          ].contains(extension)) {
        // Notify the worker immediately; it owns and cleans its tagged copy
        // until the platform reply completes, even during pause or shutdown.
        tagCancellation = cancelSignal.asStream().listen(
          (_) => unawaited(_cancelTags(entry.id)),
        );
        try {
          final path = await channel
              .invokeMethod<String>('writeTags', {
                'id': entry.id,
                'path': raw.path,
                'title': entry.song.name,
                'artist': entry.song.artist,
                'album': entry.song.album,
                'lyrics': lyrics,
                'coverPath': cover?.path,
              })
              .timeout(const Duration(seconds: 30));
          final expected = await _ownedFile(root, 'tagged', name);
          if (path != null &&
              p.equals(p.normalize(path), p.normalize(expected.path)) &&
              await expected.exists()) {
            tagged = expected;
          } else {
            entry.warning = '标签未写入，已保留原音频';
          }
        } catch (_) {
          entry.warning = '标签未写入，已保留原音频';
          await _cancelTags(entry.id);
        }
      }
      if (cancel.isCancelled || !_alive) return;
      published = await _ownedFile(root, 'media', name);
      await (tagged ?? raw).rename(published.path);
      if (cover != null) {
        cover = await cover.rename(
          (await _ownedFile(root, 'media', '${entry.id}.cover.jpg')).path,
        );
      }
      if (lyricFile != null) {
        lyricFile = await lyricFile.rename(
          (await _ownedFile(root, 'media', '${entry.id}.lrc')).path,
        );
      }
      if (!_alive || cancel.isCancelled) return;
      entry.fileName = name;
      entry.status = DownloadStatus.completed;
      await _persist();
      committed = true;
      published = null;
      cover = null;
      lyricFile = null;
    } catch (failure) {
      if (cancel.isCancelled && cancel.cancelError?.error == 'too-large') {
        entry.status = DownloadStatus.failed;
        entry.error = '音频文件超过 256 MB';
      } else if (cancel.isCancelled && cancel.cancelError?.error == 'timeout') {
        entry.status = DownloadStatus.failed;
        entry.error = '下载超时';
      } else if (!cancel.isCancelled && _alive) {
        entry.status = DownloadStatus.failed;
        entry.error = '下载失败，请重试';
        debugPrint('下载失败: $failure');
      }
    } finally {
      timeout?.cancel();
      unawaited(tagCancellation?.cancel());
      if (!committed && (cancel.isCancelled || !_alive)) {
        if (entry.status != DownloadStatus.queued &&
            entry.status != DownloadStatus.failed) {
          entry.status = DownloadStatus.paused;
        }
        await _cancelTags(entry.id);
      }
      for (final file in [raw, cover, lyricFile, tagged, published]) {
        if (file == null) continue;
        try {
          if (await file.exists()) await file.delete();
        } catch (failure) {
          debugPrint('清理下载临时文件失败: $failure');
        }
      }
      await _persist();
      _notify();
    }
  }

  Future<void> _cancelTags(String id) async {
    try {
      await channel
          .invokeMethod<void>('cancelTags', {'id': id})
          .timeout(const Duration(seconds: 3));
    } on MissingPluginException {
      /* No native tag resources exist. */
    } catch (failure) {
      debugPrint('取消标签写入失败: $failure');
    }
  }

  Future<void> _persist() {
    if (scope.isDeleted || _loadFailed || !_loaded) return Future.value();
    _persistAgain = true;
    return _persisting ??= _flush().whenComplete(() => _persisting = null);
  }

  Future<void> _flush() async {
    do {
      _persistAgain = false;
      final prefs = await SharedPreferences.getInstance();
      if (scope.isDeleted) return;
      final value = jsonEncode({
        'version': 1,
        'wifiOnly': wifiOnly,
        'entries': _entries.map((entry) => entry.toJson()).toList(),
      });
      final key = scope.preferenceKey(preferenceKey);
      final previous = prefs.getString(key);
      try {
        if (!await prefs.setString(key, value)) throw StateError('下载状态保存失败');
      } catch (_) {
        try {
          if (previous == null) {
            await prefs.remove(key);
          } else {
            await prefs.setString(key, previous);
          }
        } catch (failure) {
          debugPrint('回退下载索引失败: $failure');
        }
        rethrow;
      }
    } while (_persistAgain);
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> suspend() async {
    _suspended = true;
    for (final entry in _entries) {
      if (entry.status == DownloadStatus.queued ||
          entry.status == DownloadStatus.downloading ||
          entry.status == DownloadStatus.processing) {
        entry.status = DownloadStatus.paused;
      }
    }
    _cancel?.cancel('suspended');
    try {
      await _work;
      await _persist();
    } catch (failure) {
      debugPrint('暂停下载失败: $failure');
    }
    _notify();
  }

  void resumeSession() {
    if (!_closing && !_disposed) _suspended = false;
  }

  Future<void> _close() async {
    _closing = true;
    for (final entry in _entries) {
      if (entry.status == DownloadStatus.queued ||
          entry.status == DownloadStatus.downloading ||
          entry.status == DownloadStatus.processing) {
        entry.status = DownloadStatus.paused;
      }
    }
    _cancel?.cancel('closed');
    try {
      await _networkReady;
      await _networkSub?.cancel().timeout(const Duration(seconds: 3));
    } catch (failure) {
      debugPrint('关闭下载网络监听失败: $failure');
    }
    _networkSub = null;
    try {
      await _work;
      await _persist();
    } catch (failure) {
      debugPrint('关闭下载管理失败: $failure');
    }
    _dio.close(force: true);
    if (!_disposed) {
      _disposed = true;
      super.dispose();
    }
  }

  @override
  void dispose() {
    unawaited(close());
    if (!_disposed) {
      _disposed = true;
      super.dispose();
    }
  }
}
