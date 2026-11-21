import 'dart:async';

import 'package:http/http.dart' as http;

import '../models/playback_package.dart';
import '../models/remote_playback.dart';
import '../models/song.dart';
import 'bounded_http_response.dart';
import 'playback_package_store.dart';
import 'playback_script_runtime.dart';

/// 本地解析包入口；网络更新不进入播放依赖。SHIXIAOYANG，2026/11/21。
class PlaybackResolverService {
  late final PlaybackPackageStore _store;
  late final PlaybackScriptRuntime _runtime;
  final Set<Completer<void>> _activeRequests = {};
  bool _closed = false;

  /// 更新客户端与上游请求独立，解析只使用本地已验证包。
  PlaybackResolverService({
    PlaybackPackageStore? packageStore,
    PlaybackScriptRuntime? scriptRuntime,
    http.Client? updateClient,
  }) {
    _runtime = scriptRuntime ?? PlaybackScriptRuntime();
    _store =
        packageStore ??
        PlaybackPackageStore(
          client: updateClient,
          validator: _runtime.validate,
          isPackageFailure: _isPackageFailure,
        );
  }

  bool _isPackageFailure(Object error) =>
      error is FormatException ||
      (error is PlaybackScriptException && error.code.startsWith('PACKAGE_'));

  int get activeRequestCount => _activeRequests.length;
  int? get packageVersion => _store.current?.packageVersion;
  bool get checkingUpdate => _store.checking;
  String? get updateError => _store.updateError;

  /// 读取本地有效包能力；更新接口挂起时也能完成，不发网络请求。
  Future<PlaybackSourceCatalog> loadSources({
    Future<void>? cancelSignal,
  }) async {
    _ensureOpen();
    final package = await _localPackage(cancelSignal);
    _ensureOpen();
    return package.capabilities;
  }

  /// 后台检查更新，失败继续使用当前包，不抛给正常播放流程。
  Future<bool> checkUpdate() async {
    if (_closed) return false;
    return _store.checkUpdate();
  }

  Future<PlaybackPackage> _localPackage(Future<void>? cancelSignal) async {
    final request = _store.ready;
    return cancelSignal == null
        ? await request
        : await awaitWithCancellation(request, cancelSignal);
  }

  void _ensureOpen() {
    if (_closed) throw const HttpRequestCancelledException();
  }

  /// 捕获包快照解析；更新切换不改变进行中操作的代码和凭据。
  Future<SongDetail> resolve(
    Map<String, dynamic> parameters, {
    Future<void>? cancelSignal,
  }) async {
    _ensureOpen();
    // 不排队累积重复任务，当前操作结束就释放取消记录。
    if (_activeRequests.length >= 4) {
      throw const PlaybackResolutionException('REQUEST_BUSY', '音源请求繁忙，请稍后重试');
    }
    final cancellation = Completer<void>();
    _activeRequests.add(cancellation);
    StreamSubscription<void>? owner;
    void cancel() {
      if (!cancellation.isCompleted) cancellation.complete();
    }

    if (cancelSignal != null) {
      // 所有者异常退出也按取消处理，不能产生未捕获的异步错误。
      owner = cancelSignal.asStream().listen(
        (_) => cancel(),
        onError: (Object _, StackTrace __) => cancel(),
      );
    }
    try {
      final package = await _localPackage(cancellation.future);
      _ensureOpen();
      var usedPackage = package;
      Map<String, dynamic> result;
      try {
        result = await _runtime.resolve(
          package,
          parameters,
          cancelSignal: cancellation.future,
        );
      } on PlaybackScriptException catch (error) {
        // 代码故障才回退解析包，上游网络/授权错误不能误判为坏版本。
        if (!error.code.startsWith('PACKAGE_')) rethrow;
        await _store.rollback(package.packageVersion);
        final previous = _store.current;
        if (previous == null ||
            previous.packageVersion == package.packageVersion) {
          rethrow;
        }
        usedPackage = previous;
        result = await _runtime.resolve(
          previous,
          parameters,
          cancelSignal: cancellation.future,
        );
      }
      if (_closed || cancellation.isCompleted) {
        throw const HttpRequestCancelledException();
      }
      return _detail(result, parameters, usedPackage);
    } on HttpRequestCancelledException {
      rethrow;
    } on PlaybackScriptException catch (error) {
      throw PlaybackResolutionException(error.code, error.message);
    } on FormatException {
      throw const PlaybackResolutionException('PACKAGE_INVALID', '本地解析包不可用');
    } finally {
      _activeRequests.remove(cancellation);
      cancel();
      if (owner != null) unawaited(owner.cancel());
    }
  }

  /// 校验本地脚本结果后才交给播放器，拒绝过期或不可播放的地址。
  static SongDetail _detail(
    Map<String, dynamic> json,
    Map<String, dynamic> input,
    PlaybackPackage package,
  ) {
    if (json['protocolVersion'] != 1) {
      throw const PlaybackResolutionException('INVALID_RESULT', '本地解析结果协议无效');
    }
    final url = json['url'];
    final id = json['providerId'];
    final name = json['providerName'];
    if (url is! String ||
        url.length > 8192 ||
        id is! String ||
        !PlaybackSource.isValidId(id) ||
        id == 'automatic' ||
        name is! String ||
        name.isEmpty ||
        name.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const PlaybackResolutionException('INVALID_RESULT', '本地解析返回了无效结果');
    }
    // 正在解析的旧包仍可返回已移除的旧源，校验必须使用本次包快照。
    final provider = package.capabilities.sourceFor(PlaybackSource.fromId(id));
    if (provider == null || !provider.platforms.contains(input['platform'])) {
      throw const PlaybackResolutionException(
        'INVALID_RESULT',
        '本地解析返回了未支持的音源',
      );
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const PlaybackResolutionException('INVALID_AUDIO_URL', '音频地址无效');
    }
    final rawFormat = json['format'];
    if (rawFormat != null && rawFormat is! String) {
      throw const PlaybackResolutionException('INVALID_FORMAT', '音频格式无效');
    }
    final format = (rawFormat as String?)?.toLowerCase();
    if (const ['mgg', 'mflac', 'cenc'].contains(format)) {
      throw const PlaybackResolutionException('ENCRYPTED_AUDIO', '音源返回了加密音频');
    }
    if (format != null && !RegExp(r'^[a-z0-9]{1,12}$').hasMatch(format)) {
      throw const PlaybackResolutionException('INVALID_FORMAT', '音频格式无效');
    }
    final expiry = json['expiresAt'];
    if (expiry != null &&
        (expiry is! int ||
            expiry > 8640000000000000 ||
            expiry <= DateTime.now().millisecondsSinceEpoch)) {
      throw const PlaybackResolutionException('EXPIRED_URL', '音频地址已过期，请重试');
    }
    // 元数据沿用队列，脚本只提供音频结果，不更新页面或用户设置。
    return SongDetail(
      name: input['name'] as String? ?? '',
      artist: input['artist'] as String? ?? '',
      album: input['album'] as String? ?? '',
      url: url,
      format: format,
      playbackHeaders: _headers(json['playbackHeaders']),
      playbackSource: provider.source,
      playbackExpiresAt: expiry is int
          ? DateTime.fromMillisecondsSinceEpoch(expiry)
          : null,
    );
  }

  static Map<String, String> _headers(dynamic raw) {
    if (raw == null) return const {};
    if (raw is! Map || raw.length > 16) {
      throw const PlaybackResolutionException('INVALID_HEADERS', '音频请求头无效');
    }
    final result = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String ||
          !RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(key) ||
          const [
            'host',
            'connection',
            'content-length',
            'transfer-encoding',
          ].contains(key.toLowerCase()) ||
          value is! String ||
          value.length > 4096 ||
          RegExp(r'[^\x20-\x7e]').hasMatch(value)) {
        throw const PlaybackResolutionException('INVALID_HEADERS', '音频请求头无效');
      }
      result[key] = value;
    }
    return Map.unmodifiable(result);
  }

  /// 关闭解析和更新所有者，取消信号只存在于进行中的操作集合。
  void close() {
    if (_closed) return;
    _closed = true;
    for (final request in _activeRequests) {
      if (!request.isCompleted) request.complete();
    }
    _activeRequests.clear();
    _runtime.close();
    _store.close();
  }
}

class PlaybackResolutionException implements Exception {
  final String code;
  final String message;
  const PlaybackResolutionException(this.code, this.message);
  @override
  String toString() => '[$code] $message';
}
