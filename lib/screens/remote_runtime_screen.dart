import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../providers/player_provider.dart';
import '../providers/user_controller.dart';
import '../providers/theme_controller.dart';
import '../providers/ai_config_controller.dart';
import '../providers/ai_assistant_controller.dart';
import '../providers/search_session.dart';
import '../services/favorite_service.dart';
import '../services/runtime_config.dart';
import '../services/runtime_bundle_store.dart';
import '../services/runtime_http_client.dart';
import '../services/native_runtime_bridge.dart';
import '../services/app_exit_service.dart';
import '../widgets/runtime_status_view.dart';

/// 固定手机框架：仅加载本机已验签的业务文件。SHIXIAOYANG，2026/11/19。
class RemoteRuntimeScreen extends StatefulWidget {
  final ValueListenable<int>? openPlayerRequests;
  const RemoteRuntimeScreen({super.key, this.openPlayerRequests});
  @override
  State<RemoteRuntimeScreen> createState() => _RemoteRuntimeScreenState();
}

class _RemoteRuntimeScreenState extends State<RemoteRuntimeScreen>
    with WidgetsBindingObserver {
  final RuntimeHttpClient _client = RuntimeHttpClient();
  final Set<String> _requests = {};
  WebViewController? _controller;
  RuntimeBundleStore? _store;
  NativeRuntimeBridge? _bridge;
  RuntimeBundle? _bundle;
  RuntimeBundle? _candidate;
  Completer<void> _pageCancel = Completer<void>();
  Timer? _startupDeadline;
  Timer? _ticker;
  String _token = '';
  int _generation = 0;
  bool _started = false;
  bool _ready = false;
  bool _loading = false;
  bool _initializing = false;
  bool _applying = false;
  bool _checking = false;
  bool _checkAgain = false;
  bool _sending = false;
  bool _foreground = true;
  DateTime _applyAfter = DateTime.fromMillisecondsSinceEpoch(0);
  String _status = '正在打开库仔音乐';
  String? _error;
  Map<String, dynamic> _viewState = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.openPlayerRequests?.addListener(_openPlayer);
    _ticker = Timer.periodic(const Duration(milliseconds: 300), _tick);
  }

  void _openPlayer() {
    if (!mounted) return;
    if (_ready) {
      _emit('navigate', {'page': 'player'});
    } else {
      _viewState['route'] = 'player';
    }
  }

  @override
  void didUpdateWidget(RemoteRuntimeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.openPlayerRequests != widget.openPlayerRequests) {
      oldWidget.openPlayerRequests?.removeListener(_openPlayer);
      widget.openPlayerRequests?.addListener(_openPlayer);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _bridge = NativeRuntimeBridge(
      player: context.read<PlayerProvider>(),
      favorites: context.read<FavoriteService>(),
      users: context.read<UserController>(),
      theme: context.read<ThemeController>(),
      client: _client,
      context: context,
      aiConfig: context.read<AiConfigController>(),
      aiAssistant: context.read<AiAssistantController>(),
      search: context.read<SearchSession>(),
      emit: _emit,
    );
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    // 重复点击恢复入口只启动一次初始化，避免交错创建 WebView。
    if (!mounted || _initializing || _loading || _applying) return;
    _initializing = true;
    setState(() {
      _error = null;
      _status = '正在校验本地业务版本';
    });
    try {
      final directory = await getApplicationSupportDirectory();
      if (!mounted) return;
      final store = _store ??= RuntimeBundleStore(
        Directory('${directory.path}/remote_business'),
      );
      await _bridge!.initialize();
      var current = await store.current();
      if (current == null) {
        final manifest = await rootBundle.load('assets/runtime/manifest.json');
        final blob = await rootBundle.load('assets/runtime/bundle.json');
        current = await store.seed(
          manifest.buffer.asUint8List(
            manifest.offsetInBytes,
            manifest.lengthInBytes,
          ),
          blob.buffer.asUint8List(blob.offsetInBytes, blob.lengthInBytes),
        );
      }
      if (!mounted) return;
      if (current == null) throw StateError('没有可用业务版本');
      await _load(current);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _safeError(error);
        _status = '打开失败';
        _loading = false;
      });
    } finally {
      _initializing = false;
    }
  }

  Future<void> _load(RuntimeBundle bundle) async {
    if (!mounted || _loading) return;
    _loading = true;
    final generation = ++_generation;
    _startupDeadline?.cancel();
    _pageCancel.complete();
    _pageCancel = Completer<void>();
    _requests.clear();
    _ready = false;
    _token = base64UrlEncode(
      List<int>.generate(24, (_) => Random.secure().nextInt(256)),
    );
    _bundle = bundle;
    setState(() {
      _error = null;
      _status = '正在启动业务版本 ${bundle.release.version}';
    });
    try {
      await _bridge!.resetPage();
      if (!mounted || generation != _generation) return;
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!mounted || generation != _generation) return;
      await controller.setBackgroundColor(const Color(0xff10141b));
      if (!mounted || generation != _generation) return;
      await controller.addJavaScriptChannel(
        'KuzaiNative',
        onMessageReceived: _onMessage,
      );
      if (!mounted || generation != _generation) return;
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => _allowedUrl(request.url)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (url) {
            if (_allowedUrl(url)) unawaited(_connect(generation));
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) {
              unawaited(_loadFailed(generation));
            }
          },
        ),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _controller = controller;
      });
      _startupDeadline = Timer(
        const Duration(seconds: 15),
        () => unawaited(_loadFailed(generation)),
      );
      await controller.loadFile(bundle.entry.path);
    } catch (error) {
      if (mounted && generation == _generation) await _loadFailed(generation);
    } finally {
      if (generation == _generation) _loading = false;
    }
  }

  bool _allowedUrl(String value) {
    final bundle = _bundle;
    final url = Uri.tryParse(value);
    if (bundle == null ||
        url == null ||
        url.scheme != 'file' ||
        url.hasQuery ||
        url.userInfo.isNotEmpty) {
      return false;
    }
    try {
      return File.fromUri(url.replace(fragment: '')).absolute.path ==
          bundle.entry.absolute.path;
    } catch (_) {
      return false;
    }
  }

  Future<void> _connect(int generation) async {
    if (!mounted || generation != _generation || _controller == null) return;
    final bundle = _bundle!;
    final state = {
      'token': _token,
      'framework': RuntimeConfig.frameworkVersion,
      'version': bundle.release.version,
      'settings': _bridge!.settings,
      'state': _bridge!.state(),
      'restore': _viewState,
      'capabilities': [
        'network',
        'source_probe',
        'lyric_search',
        'lyric_apply',
        'exit',
        'runtime_check',
        'play',
        'control',
        'queue',
        'lyrics',
        'favorite',
        'library',
        'backup',
        'settings',
        'credentials',
        'users',
        'appearance',
        'assistant',
        'assistant_config',
        'video',
        'api',
      ],
    };
    try {
      await _controller!.runJavaScript(
        'window.KuzaiHost && window.KuzaiHost.connect(${jsonEncode(state)})',
      );
    } catch (_) {
      if (mounted && generation == _generation) await _loadFailed(generation);
    }
  }

  void _onMessage(JavaScriptMessage message) {
    if (!mounted || message.message.length > 256 * 1024) return;
    Map<String, dynamic> request;
    try {
      final raw = jsonDecode(message.message);
      if (raw is! Map) return;
      request = Map<String, dynamic>.from(raw);
    } catch (_) {
      return;
    }
    if (request['token'] != _token ||
        request['id'] is! String ||
        request['operation'] is! String) {
      return;
    }
    final id = request['id'] as String;
    if (!RegExp(r'^[a-z0-9_-]{1,32}$').hasMatch(id) || _requests.contains(id)) {
      return;
    }
    if (request['operation'] == 'ready') {
      if (_ready) return;
      _startupDeadline?.cancel();
      setState(() {
        _ready = true;
        _status = '业务版本 ${_bundle!.release.version}';
      });
      unawaited(_check());
      return;
    }
    if (!_ready) return;
    if (_requests.length >= 8) {
      unawaited(
        _reply(id, {
          'error': {'code': 'BUSY', 'message': '请求过多，请稍候'},
        }, _generation),
      );
      return;
    }
    if (request['data'] is! Map) return;
    _requests.add(id);
    unawaited(
      _handle(
        id,
        request['operation'] as String,
        Map<String, dynamic>.from(request['data'] as Map),
        _generation,
      ),
    );
  }

  Future<void> _handle(
    String id,
    String operation,
    Map<String, dynamic> data,
    int generation,
  ) async {
    try {
      Map<String, dynamic> result;
      if (operation == 'runtime_check') {
        await _check();
        result = {'status': _status};
      } else {
        result = await _bridge!.handle(
          operation,
          data,
          cancelSignal: _pageCancel.future,
        );
      }
      if (operation == 'network' && data['proxy'] is String) {
        _checkAgain = _checking;
        if (!_checking) unawaited(_check());
      }
      await _reply(id, {'result': result}, generation);
    } catch (error) {
      await _reply(id, {
        'error': {
          'code': error is RuntimeException ? error.code : 'CAPABILITY_FAILED',
          'message': _safeError(error),
        },
      }, generation);
    } finally {
      if (generation == _generation) _requests.remove(id);
    }
  }

  Future<void> _reply(
    String id,
    Map<String, dynamic> value,
    int generation,
  ) async {
    if (!mounted || generation != _generation || !_ready) return;
    try {
      await _controller?.runJavaScript(
        'window.KuzaiHost.accept(${jsonEncode({'id': id, ...value})})',
      );
    } catch (_) {
      /* WebView 销毁期间不能将迟到响应交给下一页。 */
    }
  }

  void _emit(String event, Map<String, dynamic> value) {
    if (!mounted || !_ready) return;
    unawaited(_emitToPage(event, value, _generation));
  }

  Future<void> _emitToPage(
    String event,
    Map<String, dynamic> value,
    int generation,
  ) async {
    if (!mounted || generation != _generation || !_ready) return;
    try {
      await _controller?.runJavaScript(
        'window.KuzaiHost.event(${jsonEncode({'event': event, 'data': value})})',
      );
    } catch (_) {
      /* 状态发送与卸载竞态时直接停止，不持有重试队列。 */
    }
  }

  void _tick(Timer timer) {
    if (!mounted || !_ready || !_foreground || _sending || _applying) return;
    if (_candidate != null &&
        _requests.isEmpty &&
        _bridge!.canReload &&
        !_loading &&
        DateTime.now().isAfter(_applyAfter)) {
      unawaited(_applyCandidate());
      return;
    }
    unawaited(_pushState());
  }

  Future<void> _pushState() async {
    _sending = true;
    try {
      await _emitToPage('state', {
        'state': _bridge!.state(),
        'runtimeStatus': _status,
      }, _generation);
    } catch (_) {
      /* 用户切换后旧会话不再产生状态。 */
    } finally {
      _sending = false;
    }
  }

  Future<void> _check() async {
    if (!mounted ||
        _checking ||
        _applying ||
        _store == null ||
        _candidate != null) {
      return;
    }
    _checking = true;
    try {
      final bundle = await _store!.check(_client);
      if (!mounted) return;
      _status = '已检查更新，当前版本 ${_bundle?.release.version ?? 0}';
      if (bundle != null && bundle.release.id != _bundle?.release.id) {
        _candidate = bundle;
        _status = '业务更新已准备好';
      }
    } catch (error) {
      if (mounted) _status = '检查更新失败，继续使用本地版本：${_safeError(error)}';
    } finally {
      _checking = false;
      if (_checkAgain && mounted) {
        _checkAgain = false;
        unawaited(_check());
      }
    }
  }

  Future<void> _applyCandidate() async {
    final candidate = _candidate;
    if (candidate == null || _loading || _applying) return;
    // 保存页面状态到重新加载之间禁止再次检查，防止第二次更新清理仍在使用的旧包。
    _applying = true;
    _candidate = null;
    try {
      try {
        final raw = await _controller?.runJavaScriptReturningResult(
          'JSON.stringify(window.KuzaiHost.prepareUpdate())',
        );
        if (!mounted) return;
        dynamic decoded;
        if (raw is String && raw.length <= 64 * 1024) decoded = jsonDecode(raw);
        if (decoded is String) decoded = jsonDecode(decoded);
        if (decoded is Map && decoded['defer'] == true) {
          _candidate = candidate;
          _applyAfter = DateTime.now().add(const Duration(seconds: 3));
          return;
        }
        if (decoded is Map) _viewState = Map<String, dynamic>.from(decoded);
      } catch (_) {
        /* 页面恢复状态损坏时使用已持久化配置重新打开。 */
      }
      if (mounted) await _load(candidate);
    } finally {
      _applying = false;
      if (mounted && _ready && _candidate == null) unawaited(_check());
    }
  }

  Future<void> _loadFailed(int generation) async {
    if (!mounted || generation != _generation || _ready) return;
    final failed = _bundle;
    if (failed == null) return;
    _startupDeadline?.cancel();
    ++_generation;
    _loading = false;
    try {
      final previous = await _store!.rollback(failed.release.id);
      if (!mounted) return;
      if (previous != null) {
        await _load(previous);
        return;
      }
    } catch (_) {
      /* 保留有效数据，使用原生错误页提供恢复入口。 */
    }
    if (mounted) {
      setState(() {
        _controller = null;
        _error = '业务页面启动失败，请重试或恢复内置版本';
        _status = '打开失败';
      });
    }
  }

  static String _safeError(Object error) {
    if (error is RuntimeException) return error.message;
    if (error is FormatException) return error.message;
    if (error is TimeoutException) return '网络超时';
    if (error is FileSystemException) return '本地存储不可用';
    return '服务或系统能力暂不可用';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && _ready) unawaited(_check());
  }

  void _onBack(bool didPop, Object? result) {
    if (didPop || !mounted) return;
    unawaited(_performBack());
  }

  Future<void> _performBack() async {
    try {
      if (_ready && _controller != null) {
        await _controller!.runJavaScript('window.KuzaiHost.back()');
      } else if (mounted) {
        await AppExitService.confirmAndExit(context);
      }
    } catch (error) {
      // 系统返回和页面卸载竞态不能产生未处理异常，也不持有重试队列。
      debugPrint('远程页面返回失败：${error.runtimeType}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onBack,
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              if (_controller != null)
                Positioned.fill(child: WebViewWidget(controller: _controller!)),
              if (!_ready)
                Positioned.fill(
                  child: RuntimeStatusView(
                    status: _status,
                    error: _error,
                    onRetry: () => unawaited(_initialize()),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _releaseBridge() async {
    try {
      await _bridge?.close();
    } catch (error) {
      // 桥接层 finally 仍释放扫描资源；记录类型，避免卸载后的未处理异常。
      debugPrint('远程页面资源释放失败：${error.runtimeType}');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.openPlayerRequests?.removeListener(_openPlayer);
    _startupDeadline?.cancel();
    _ticker?.cancel();
    ++_generation;
    if (!_pageCancel.isCompleted) _pageCancel.complete();
    _store?.close();
    _client.close();
    _requests.clear();
    _controller = null;
    unawaited(_releaseBridge());
    super.dispose();
  }
}
