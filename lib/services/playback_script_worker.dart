import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_js/quickjs/ffi.dart' as quickjs;

/// 隔离线程入口，只接受已经验证的包快照。SHIXIAOYANG，2026/11/21。
void playbackScriptWorkerMain(Map<String, dynamic> arguments) {
  final worker = _ScriptWorker(arguments);
  worker.start();
}

class _ScriptWorker {
  final Map<String, dynamic> arguments;
  final ReceivePort commands = ReceivePort();
  late final SendPort output = arguments['output'] as SendPort;
  QuickJsRuntime2? _runtime;
  _NativeBudget? _budget;
  StreamSubscription<dynamic>? _subscription;
  Timer? _jobs;
  Map<String, dynamic>? _result;
  bool _invalidInitialization = false;
  bool _closed = false;

  _ScriptWorker(this.arguments);

  void start() {
    // 先完成控制通道握手，主侧可以在初始化中途提出取消。
    output.send({'type': 'ready', 'port': commands.sendPort});
    _subscription = commands.listen(_onCommand);
    try {
      final library = _supportedLibrary();
      if (library == null) {
        _finishError('ENGINE_UNAVAILABLE', '当前平台没有满足预算限制的脚本引擎');
        return;
      }
      // 这里只先执行库固定bootstrap；任何下载脚本都在原生预算设置后执行。
      final runtime = QuickJsRuntime2(stackSize: 256 * 1024, timeout: 0);
      _runtime = runtime;
      _budget = _NativeBudget(library, runtime);
      // 在任何解析包执行前确认设备实际支持CPU中断和内存拒绝，失败只走受控降级。
      _budget!.verifyGuards(runtime);
      // 去掉库自带未跟踪的Timer/日志通道，下载包只拥有明确开放的Host能力。
      JavascriptRuntime
          .channelFunctionsRegistered[runtime.getEngineInstanceId()]!
          .clear();
      runtime.onMessage('KuzaiSync', _sync);
      runtime.onMessage('KuzaiAsync', _async);
      runtime.onMessage('KuzaiResult', _receiveResult);
      if (!_installBridge()) return;
      if (!_evaluate(arguments['script'] as String)) return;
      if (arguments['mode'] == 'validate') {
        if (_invalidInitialization) {
          _finishError('PACKAGE_INVALID', '解析包初始化不能创建异步或外部任务');
          return;
        }
        final value = _evaluateValue('__kuzaiCapabilities()', expectText: true);
        if (value == null) return;
        final capabilities = jsonDecode(value);
        _finish({
          'type': 'result',
          'value': {'capabilities': capabilities},
        });
        return;
      }
      // Promise结果走消息通道，不把native Promise/JS对象传回主isolate。
      final input = arguments['input'] as String;
      final operation = jsonEncode(arguments['operationId']);
      if (!_evaluate('__kuzaiResolve($input, $operation)')) {
        return;
      }
      _flushResult();
      if (!_closed) {
        _jobs = Timer.periodic(const Duration(milliseconds: 10), _pumpJobs);
      }
    } catch (_) {
      _finishError('ENGINE_UNAVAILABLE', '本地脚本引擎初始化失败');
    }
  }

  DynamicLibrary? _supportedLibrary() {
    // 固定版本Windows库缺少内存API；Apple JSC也没有等价硬限，不能无保护执行。
    if (!Platform.isAndroid && !Platform.isLinux && !Platform.isWindows) {
      return null;
    }
    final String path;
    if (Platform.isAndroid) {
      path = 'libfastdev_quickjs_runtime.so';
    } else if (Platform.isWindows) {
      path = 'quickjs_c_bridge.dll';
    } else {
      path =
          Platform.environment['LIBQUICKJSC_TEST_PATH'] ??
          'libquickjs_c_bridge_plugin.so';
    }
    final library = DynamicLibrary.open(path);
    if (!library.providesSymbol('JS_SetMemoryLimit') ||
        !library.providesSymbol('JS_SetInterruptHandler') ||
        !library.providesSymbol('JS_SetHostPromiseRejectionTracker')) {
      return null;
    }
    return library;
  }

  void _onCommand(dynamic message) {
    if (_closed || message is! Map) return;
    if (message['type'] == 'cancel') {
      _finishError('RESOLVE_CANCELLED', '播放解析已取消');
      return;
    }
    if (message['type'] != 'hostResponse') return;
    final id = message['requestId'];
    if (id is! int) return;
    // 只在native回调结束后的消息事件中调用evaluate，避免FFI重入。
    final response = jsonEncode({
      'value': message['value'],
      'error': message['error'],
    });
    _evaluate('__kuzaiReply($id, $response)');
    _flushResult();
  }

  dynamic _sync(dynamic raw) {
    if (_closed || raw is! Map) return null;
    final kind = raw['kind'];
    final text = raw['text'];
    if (kind == 'now') return DateTime.now().millisecondsSinceEpoch;
    if (kind == 'randomHex') {
      final bytes = raw['bytes'];
      if (bytes is! int || bytes < 1 || bytes > 32) {
        throw const FormatException('随机参数无效');
      }
      final random = Random.secure();
      final result = StringBuffer();
      for (var index = 0; index < bytes; index++) {
        result.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
      }
      return result.toString();
    }
    if (text is! String || utf8.encode(text).length > 512 * 1024) {
      throw const FormatException('摘要输入超过上限');
    }
    if (kind == 'sha256') return sha256.convert(utf8.encode(text)).toString();
    if (kind == 'hmacSha256') {
      final key = raw['key'];
      if (key is! String || utf8.encode(key).length > 4096) {
        throw const FormatException('签名参数无效');
      }
      return Hmac(
        sha256,
        utf8.encode(key),
      ).convert(utf8.encode(text)).toString();
    }
    throw const FormatException('脚本请求了未开放的能力');
  }

  dynamic _async(dynamic raw) {
    if (arguments['mode'] == 'validate') {
      _invalidInitialization = true;
      return null;
    }
    if (!_closed && raw is Map) {
      output.send({'type': 'host', 'command': Map<String, dynamic>.from(raw)});
    }
    return null;
  }

  dynamic _receiveResult(dynamic raw) {
    if (_closed || raw is! Map) return null;
    if (arguments['mode'] == 'validate') {
      _invalidInitialization = true;
      return null;
    }
    _result = Map<String, dynamic>.from(raw);
    return null;
  }

  bool _installBridge() {
    // 这里只执行固定代码，返回整数；第三方wrapper不能接收到任意包对象。
    try {
      _budget!.begin();
      final result = _runtime!.evaluate(playbackScriptBootstrap);
      if (result.isError || _budget!.interrupted) {
        _finishError('ENGINE_UNAVAILABLE', '本地脚本桥接初始化失败');
        return false;
      }
      return true;
    } catch (_) {
      _finishError('ENGINE_UNAVAILABLE', '本地脚本桥接初始化失败');
      return false;
    }
  }

  bool _evaluate(String code) => _evaluateValue(code) != null;

  String? _evaluateValue(String code, {bool expectText = false}) {
    if (_closed) return null;
    try {
      _budget!.begin();
      final result = _runtime!.evaluate(
        playbackScriptGuardedEvaluation(code, expectText: expectText),
      );
      if (_budget!.interrupted) {
        _finishError('PACKAGE_BUDGET', '解析脚本执行超过预算');
        return null;
      }
      final value = result.stringResult;
      if (result.isError ||
          value == 'E' ||
          (expectText ? !value.startsWith('V') : value != 'O')) {
        _finishError('PACKAGE_INVALID', '解析脚本语法或执行结果无效');
        return null;
      }
      return expectText ? value.substring(1) : value;
    } catch (_) {
      _finishError('PACKAGE_FAILED', '解析脚本执行失败');
      return null;
    }
  }

  void _pumpJobs(Timer _) {
    if (_closed) return;
    try {
      _budget!.begin();
      final jobsSucceeded = _budget!.drainJobs();
      if (_budget!.interrupted) {
        _finishError('PACKAGE_BUDGET', '解析脚本执行超过预算');
        return;
      }
      if (!jobsSucceeded) {
        _finishError('PACKAGE_FAILED', '解析脚本异步任务失败');
        return;
      }
      _flushResult();
    } catch (_) {
      _finishError('PACKAGE_FAILED', '解析脚本执行失败');
    }
  }

  void _flushResult() {
    final result = _result;
    if (_closed || result == null) return;
    final error = result['error'];
    if (error is Map) {
      final code = error['code'];
      final message = error['message'];
      _finishError(
        code is String && RegExp(r'^[A-Z0-9_]{1,64}$').hasMatch(code)
            ? code
            : 'PACKAGE_FAILED',
        message is String && message.length <= 512 ? message : '解析脚本执行失败',
      );
    } else if (result['value'] is Map) {
      _finish({
        'type': 'result',
        'value': Map<String, dynamic>.from(result['value'] as Map),
      });
    } else {
      _finishError('PACKAGE_INVALID', '解析脚本返回了无效结果');
    }
  }

  void _finishError(String code, String message) =>
      _finish({'type': 'error', 'code': code, 'message': message});

  void _finish(Map<String, dynamic> result) {
    if (_closed) return;
    _closed = true;
    _jobs?.cancel();
    unawaited(_subscription?.cancel());
    final runtime = _runtime;
    if (runtime != null) {
      try {
        // 释放native runtime后才释放中断回调，不能留下指向已释放Dart代码的指针。
        runtime.dispose();
      } catch (_) {
        result = {
          'type': 'error',
          'code': 'ENGINE_RELEASE',
          'message': '脚本资源释放失败',
        };
      } finally {
        JavascriptRuntime.channelFunctionsRegistered.remove(
          runtime.getEngineInstanceId(),
        );
        for (final pointer in quickjs.runtimeOpaques.keys.toList()) {
          quickjs.runtimeOpaques.remove(pointer);
        }
      }
    }
    _budget?.close();
    commands.close();
    // 主侧收到结果时，native对象已经完整释放，可以安全结束isolate。
    output.send(result);
  }
}

typedef _InterruptNative = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _SetInterruptNative =
    Void Function(
      Pointer<Void>,
      Pointer<NativeFunction<_InterruptNative>>,
      Pointer<Void>,
    );
typedef _SetMemoryNative = Void Function(Pointer<Void>, UintPtr);
typedef _SetBlockingNative = Void Function(Pointer<Void>, Int32);
typedef _SetRejectionTrackerNative =
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);

class _NativeBudget {
  final Stopwatch clock = Stopwatch()..start();
  late final NativeCallable<_InterruptNative> callback;
  late final void Function(Pointer<Void>, int) _setMemory;
  late final Pointer<Void> _runtimePointer;
  int _deadline = 0;
  bool interrupted = false;

  _NativeBudget(DynamicLibrary library, QuickJsRuntime2 runtime) {
    final pointers = quickjs.runtimeOpaques.keys.toList();
    if (pointers.length != 1) throw StateError('解析worker的runtime身份不唯一');
    final pointer = pointers.single.cast<Void>();
    _runtimePointer = pointer;
    // 使用官方C API，是因为固定库的Dart wrapper缺少同名memory导出且旧timeout没有启动时钟。
    final setMemory = library
        .lookupFunction<_SetMemoryNative, void Function(Pointer<Void>, int)>(
          'JS_SetMemoryLimit',
        );
    _setMemory = setMemory;
    final setInterrupt = library
        .lookupFunction<
          _SetInterruptNative,
          void Function(
            Pointer<Void>,
            Pointer<NativeFunction<_InterruptNative>>,
            Pointer<Void>,
          )
        >('JS_SetInterruptHandler');
    callback = NativeCallable<_InterruptNative>.isolateLocal(
      _interrupt,
      exceptionalReturn: 1,
    );
    setMemory(pointer, 16 * 1024 * 1024);
    setInterrupt(pointer, callback.nativeFunction, nullptr);
    // 禁止库先把任意Promise拒绝值转换成Dart；只由可信桥接发送有界错误文本。
    final setRejectionTracker = library
        .lookupFunction<
          _SetRejectionTrackerNative,
          void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)
        >('JS_SetHostPromiseRejectionTracker');
    setRejectionTracker(pointer, nullptr, nullptr);
    // 禁止Atomics.wait一类原生阻塞，它们不能只靠JS字节码中断处理。
    if (library.providesSymbol('JS_SetCanBlock')) {
      final setBlocking = library
          .lookupFunction<
            _SetBlockingNative,
            void Function(Pointer<Void>, int)
          >('JS_SetCanBlock');
      setBlocking(pointer, 0);
    }
    begin();
  }

  int _interrupt(Pointer<Void> _, Pointer<Void> __) {
    if (clock.elapsedMicroseconds > _deadline) {
      interrupted = true;
      return 1;
    }
    return 0;
  }

  void verifyGuards(QuickJsRuntime2 runtime) {
    // 50ms固定循环必须被真正中断，不能把Dart Future超时当作native已经停止。
    begin(microseconds: 50000);
    final loop = runtime.evaluate('while(true){}');
    if (!loop.isError || !interrupted) throw StateError('原生中断预算未生效');
    begin();
    _setMemory(_runtimePointer, 2 * 1024 * 1024);
    try {
      // 临时函数不返回ArrayBuffer或JSRef；即使限制失效也仅短暂申请4MiB。
      final memory = runtime.evaluate(
        '(function(){new ArrayBuffer(4*1024*1024);return 1;})()',
      );
      final allocationFailed = RegExp(
        r'out.of.memory|allocation failed',
        caseSensitive: false,
      ).hasMatch(memory.stringResult);
      if (!memory.isError || !allocationFailed) throw StateError('原生内存预算未生效');
    } finally {
      _setMemory(_runtimePointer, 16 * 1024 * 1024);
    }
    begin();
    final primitive = runtime.evaluate('1+2');
    if (primitive.isError || primitive.stringResult != '3') {
      throw StateError('原生引擎自检后不可用');
    }
  }

  void begin({int microseconds = 300000}) {
    interrupted = false;
    _deadline = clock.elapsedMicroseconds + microseconds;
  }

  bool drainJobs() {
    // C wrapper只返回状态码；不能调用库dispatch，它会展开任意异常对象。
    while (true) {
      final status = quickjs.jsExecutePendingJob(
        _runtimePointer.cast<quickjs.JSRuntime>(),
      );
      if (status <= 0) return status == 0;
      if (interrupted) return false;
    }
  }

  void close() => callback.close();
}

/// 生成只允许固定结果或有界文本跨FFI的执行表达式，SHIXIAOYANG，2026/11/21。
String playbackScriptGuardedEvaluation(
  String code, {
  bool expectText = false,
}) => '__kuzaiGuardedEval(${jsonEncode(code)}, $expectText)';

/// 生产与测试共同使用的可信桥接，SHIXIAOYANG，2026/11/21。
const playbackScriptBootstrap = r'''
(function(){
  // 捕获可信内建函数和唯一native入口，包不能替换它们或直接送对象进FFI。
  const nativeSend = sendMessage;
  const encode = JSON.stringify;
  const indirectEval = eval;
  const PromiseConstructor = Promise;
  const resolvePromise = Promise.resolve.bind(Promise);
  const followPromise = Function.prototype.call.bind(Promise.prototype.then);
  const define = Object.defineProperty;
  const freeze = Object.freeze;
  const ErrorConstructor = Error;
  // 原生OOM/中断仍可能产生内建Error，禁止包替换它们的toString桥接行为。
  const errors = [Error,EvalError,RangeError,ReferenceError,SyntaxError,TypeError,URIError];
  if (typeof InternalError === 'function') errors.push(InternalError);
  for (const constructor of errors) { freeze(constructor.prototype); freeze(constructor); }
  const maxTextChars = 128 * 1024;
  const waiting = new Map();
  let nextRequest = 1;

  function publish(name, value) {
    define(globalThis,name,{value:value,writable:false,configurable:false});
  }
  function boundedSend(channel, value, maximum) {
    const text = encode(value);
    if (typeof text !== 'string' || text.length > maximum) throw new ErrorConstructor('解析桥接内容超过上限');
    return nativeSend(channel,text);
  }
  function guardedEval(code, expectText) {
    try {
      const value = indirectEval(code);
      if (!expectText) return 'O';
      if (typeof value !== 'string' || value.length > maxTextChars) return 'E';
      return 'V' + value;
    } catch (_) {
      // 不读取异常对象，throw稀疏数组等值也不能触发Dart端递归转换。
      return 'E';
    }
  }
  function failure(error) {
    let code = 'PACKAGE_FAILED';
    let message = '解析脚本执行失败';
    try {
      if (error && typeof error.code === 'string' && /^[A-Z0-9_]{1,64}$/.test(error.code)) code = error.code;
      if (error && typeof error.message === 'string' && error.message.length <= 512) message = error.message;
    } catch (_) {}
    boundedSend('KuzaiResult',{error:{code:code,message:message}},2048);
  }
  function complete(value) {
    try { boundedSend('KuzaiResult',{value:value},maxTextChars); }
    catch (_) { failure(null); }
  }
  function resolve(input, operation) {
    try { followPromise(resolvePromise(KuzaiSources.resolve(input,operation)),complete,failure); }
    catch (error) { failure(error); }
  }
  function capabilities() {
    // stringify在JS内运行，getCapabilities返回或抛出任何对象都由guard处理。
    return encode(KuzaiSources.getCapabilities());
  }
  function asynchronous(kind, scope, options, milliseconds) {
    if (waiting.size >= 32) throw new ErrorConstructor('解析任务超过上限');
    const id = nextRequest++;
    return new PromiseConstructor(function(resolve,reject) {
      waiting.set(id,{resolve:resolve,reject:reject});
      try { boundedSend('KuzaiAsync',{kind:kind,scope:scope,requestId:id,options:options,milliseconds:milliseconds},1024*1024); }
      catch (_) { waiting.delete(id); reject(new ErrorConstructor('解析请求内容无效')); }
    });
  }
  function reply(id, reply) {
    const entry = waiting.get(id);
    if (!entry) return;
    waiting.delete(id);
    if (reply.error) {
      const error = new ErrorConstructor(reply.error.message);
      error.code = reply.error.code;
      entry.reject(error);
    } else entry.resolve(reply.value);
  }
  publish('__kuzaiGuardedEval',guardedEval);
  publish('__kuzaiCapabilities',capabilities);
  publish('__kuzaiResolve',resolve);
  publish('__kuzaiReply',reply);
  publish('KuzaiHost',freeze({
    sha256:function(text){return boundedSend('KuzaiSync',{kind:'sha256',text:text},1024*1024);},
    hmacSha256:function(key,text){return boundedSend('KuzaiSync',{kind:'hmacSha256',key:key,text:text},1024*1024);},
    randomHex:function(bytes){return boundedSend('KuzaiSync',{kind:'randomHex',bytes:bytes},1024);},
    now:function(){return boundedSend('KuzaiSync',{kind:'now'},1024);},
    request:function(scope,options){return asynchronous('request',scope,options);},
    delay:function(scope,milliseconds){return asynchronous('delay',scope,null,milliseconds);},
    cancel:function(scope){boundedSend('KuzaiAsync',{kind:'cancel',scope:scope},1024);}
  }));
  delete globalThis.sendMessage;
  globalThis.fetch = undefined;
  globalThis.XMLHttpRequest = undefined;
  globalThis.setTimeout = undefined;
  globalThis.setInterval = undefined;
  globalThis.require = undefined;
  globalThis.Atomics = undefined;
  globalThis.SharedArrayBuffer = undefined;
  globalThis.WebAssembly = undefined;
  globalThis.console = {log:function(){},warn:function(){},error:function(){}};
})();
1;
''';
