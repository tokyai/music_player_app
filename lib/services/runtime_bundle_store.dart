import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'runtime_config.dart';
import 'runtime_http_client.dart';
import 'runtime_release.dart';

/// 通过签名和文件校验的业务包。SHIXIAOYANG，2026/11/19。
class RuntimeBundle {
  final RuntimeRelease release;
  final File entry;
  const RuntimeBundle(this.release, this.entry);
}

/// 串行更新并原子激活，磁盘只保留当前和上一版本。
class RuntimeBundleStore {
  final Directory root;
  final String? publicKey;
  final Completer<void> _cancel = Completer<void>();
  Future<void> _pending = Future<void>.value();
  Future<RuntimeBundle?>? _checking;
  bool _closed = false;

  RuntimeBundleStore(this.root, {this.publicKey});

  void _ensureOpen() {
    if (_closed) throw const RuntimeException('CANCELLED', '业务包操作已取消');
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final operation = _pending.then((_) {
      _ensureOpen();
      return action();
    });
    // 尾任务只用于排队；实际错误仍返回给调用方。
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<Map<String, dynamic>> _pointer() async {
    final file = File('${root.path}/active.json');
    if (!await file.exists()) return {};
    if (await file.length() > 8192) throw const FormatException('业务包状态损坏');
    final data = jsonDecode(await file.readAsString());
    if (data is! Map ||
        data['maxVersion'] is! int ||
        (data['maxVersion'] as int) < 0) {
      throw const FormatException('业务包状态格式无效');
    }
    for (final key in ['current', 'previous']) {
      if (data[key] != null &&
          (data[key] is! String || !_validId(data[key] as String))) {
        throw const FormatException('业务包状态路径无效');
      }
    }
    _ensureOpen();
    return Map<String, dynamic>.from(data);
  }

  static bool _validId(String id) => RegExp(r'^r[0-9]{6,12}$').hasMatch(id);

  /// 离线启动时重新校验签名及文件；状态损坏时从已签名版本恢复。
  Future<RuntimeBundle?> current() => _serial(_current);

  Future<RuntimeBundle?> _current() async {
    try {
      final pointer = await _pointer();
      if (pointer['current'] is! String) return null;
      try {
        return await _load(pointer['current'] as String);
      } on FormatException {
        return _recover(pointer);
      } on FileSystemException {
        return _recover(pointer);
      }
    } on FormatException {
      return _recover({});
    } on FileSystemException {
      return _recover({});
    }
  }

  Future<RuntimeBundle?> _recover(Map<String, dynamic> pointer) async {
    if (!await root.exists()) return null;
    final entries = await root.list(followLinks: false).take(256).toList();
    final candidates = entries.whereType<Directory>().where((entry) {
      return _validId(path.basename(entry.path));
    }).toList();
    candidates.sort(
      (a, b) => int.parse(
        path.basename(b.path).substring(1),
      ).compareTo(int.parse(path.basename(a.path).substring(1))),
    );
    final failed = pointer['current'];
    var maxVersion = pointer['maxVersion'] as int? ?? 0;
    for (final directory in candidates.take(32)) {
      final id = path.basename(directory.path);
      if (id == failed) continue;
      RuntimeBundle bundle;
      try {
        bundle = await _load(id);
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
      if (bundle.release.version > maxVersion) {
        maxVersion = bundle.release.version;
      }
      await _writePointer({
        'current': id,
        'previous': null,
        'maxVersion': maxVersion,
      });
      await _cleanup({id});
      return bundle;
    }
    return null;
  }

  Future<RuntimeBundle> _load(String id) async {
    if (!_validId(id)) throw const FormatException('缓存版本路径无效');
    final directory = Directory('${root.path}/$id');
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('缓存目录无效');
    }
    final manifest = File('${directory.path}/manifest.json');
    final blob = File('${directory.path}/bundle.json');
    if (await manifest.length() > 64 * 1024 ||
        await blob.length() > RuntimeConfig.maxBundleBytes) {
      throw const FormatException('缓存业务包过大');
    }
    final release = await RuntimeRelease.verify(
      await manifest.readAsBytes(),
      publicKey: publicKey,
    );
    if (release.id != id ||
        release.minimumFramework > RuntimeConfig.frameworkVersion) {
      throw const FormatException('缓存版本不兼容');
    }
    final bytes = await blob.readAsBytes();
    _verifyBytes(release, bytes);
    final files = _decodeFiles(bytes, id);
    for (final item in files.entries) {
      _ensureOpen();
      final file = File('${directory.path}/${item.key}');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() != item.value.length ||
          (await sha256.bind(file.openRead()).first).toString() !=
              sha256.convert(item.value).toString()) {
        throw const FormatException('缓存业务文件校验失败');
      }
    }
    _ensureOpen();
    return RuntimeBundle(release, File('${directory.path}/index.html'));
  }

  /// 合并重复检查，下载有界且取消后不激活。
  Future<RuntimeBundle?> check(RuntimeHttpClient client) {
    final existing = _checking;
    if (existing != null) return existing;
    final operation = _finishCheck(client);
    _checking = operation;
    return operation;
  }

  Future<RuntimeBundle?> _finishCheck(RuntimeHttpClient client) async {
    try {
      return await _serial(() => _check(client));
    } finally {
      _checking = null;
    }
  }

  Future<RuntimeBundle?> _check(RuntimeHttpClient client) async {
    await root.create(recursive: true);
    final response = await client.get(
      'manifest.json',
      cancelSignal: _cancel.future,
    );
    if (response.statusCode != 200) {
      throw const RuntimeException('UPDATE_OFFLINE', '更新服务器不可用');
    }
    final release = await RuntimeRelease.verify(
      response.bodyBytes,
      publicKey: publicKey,
    );
    _ensureOpen();
    final current = await _current();
    final pointer = await _pointer();
    if (release.version <= (pointer['maxVersion'] as int? ?? 0)) return current;
    _compatible(release);
    final blob = await client.get(
      release.bundlePath,
      maxBytes: release.bundleBytes,
      cancelSignal: _cancel.future,
    );
    if (blob.statusCode != 200) {
      throw const RuntimeException('BUNDLE_DOWNLOAD_FAILED', '业务包下载失败');
    }
    return _install(release, blob.bodyBytes, pointer);
  }

  /// 首次安装使用框架内置的签名业务包，网络故障不会覆盖有效缓存。
  Future<RuntimeBundle?> seed(List<int> envelope, List<int> bytes) =>
      _serial(() async {
        final current = await _current();
        if (current != null) return current;
        final release = await RuntimeRelease.verify(
          envelope,
          publicKey: publicKey,
        );
        _compatible(release);
        Map<String, dynamic> pointer;
        try {
          pointer = await _pointer();
        } on FormatException {
          pointer = {};
        }
        return _install(release, bytes, {
          'current': null,
          'previous': null,
          'maxVersion': pointer['maxVersion'] ?? 0,
        });
      });

  static void _compatible(RuntimeRelease release) {
    if (release.minimumFramework > RuntimeConfig.frameworkVersion) {
      throw const RuntimeException(
        'FRAMEWORK_UPDATE_REQUIRED',
        '此业务版本需要更新原生框架',
      );
    }
  }

  Future<RuntimeBundle> _install(
    RuntimeRelease release,
    List<int> bytes,
    Map<String, dynamic> pointer,
  ) async {
    _verifyBytes(release, bytes);
    final files = _decodeFiles(bytes, release.id);
    _ensureOpen();
    await root.create(recursive: true);
    final keep = {
      pointer['current'],
      pointer['previous'],
    }.whereType<String>().toSet();
    await _cleanup(keep);
    final destination = Directory('${root.path}/${release.id}');
    final staging = Directory('${root.path}/.staging-${release.id}');
    if (await destination.exists() && !keep.contains(release.id)) {
      await destination.delete(recursive: true);
    }
    await staging.create();
    try {
      // 所有文件写完并落盘，再一次性切换版本；旧包一直保留到此处。
      for (final item in files.entries) {
        _ensureOpen();
        final file = File('${staging.path}/${item.key}');
        await file.parent.create(recursive: true);
        _ensureOpen();
        await file.writeAsBytes(item.value, flush: true);
      }
      await File(
        '${staging.path}/manifest.json',
      ).writeAsBytes(release.envelopeBytes, flush: true);
      _ensureOpen();
      await File(
        '${staging.path}/bundle.json',
      ).writeAsBytes(bytes, flush: true);
      _ensureOpen();
      await staging.rename(destination.path);
      _ensureOpen();
      final highWater = pointer['maxVersion'] as int? ?? 0;
      await _writePointer({
        'current': release.id,
        'previous': pointer['current'],
        'maxVersion': release.version > highWater ? release.version : highWater,
      });
      await _cleanup({
        release.id,
        if (pointer['current'] is String) pointer['current'] as String,
      });
      return RuntimeBundle(release, File('${destination.path}/index.html'));
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// 页面启动失败后回到上一版本；高水位阻止反复安装同一个坏包。
  Future<RuntimeBundle?> rollback(String failedId) => _serial(() async {
    final pointer = await _pointer();
    if (pointer['current'] != failedId) return _current();
    final previousId = pointer['previous'];
    if (previousId is! String) {
      await _writePointer({
        'current': null,
        'previous': null,
        'maxVersion': pointer['maxVersion'],
      });
      await _cleanup({});
      return null;
    }
    final previous = await _load(previousId);
    await _writePointer({
      'current': previousId,
      'previous': null,
      'maxVersion': pointer['maxVersion'],
    });
    await _cleanup({previousId});
    return previous;
  });

  Future<void> _writePointer(Map<String, dynamic> value) async {
    _ensureOpen();
    final temporary = File('${root.path}/active.json.part');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    _ensureOpen();
    await temporary.rename('${root.path}/active.json');
  }

  Future<void> _cleanup(Set<String> keep) async {
    if (!await root.exists()) return;
    await for (final entry in root.list(followLinks: false)) {
      _ensureOpen();
      final name = path.basename(entry.path);
      final temporary =
          name.startsWith('.staging-') || name == 'active.json.part';
      if (!temporary && (!_validId(name) || keep.contains(name))) continue;
      // 不跟随链接；删除目标始终是沙箱根目录的直接子项。
      await entry.delete(recursive: entry is Directory);
    }
  }

  static void _verifyBytes(RuntimeRelease release, List<int> bytes) {
    if (bytes.length != release.bundleBytes ||
        sha256.convert(bytes).toString() != release.bundleSha256) {
      throw const FormatException('业务包摘要校验失败');
    }
  }

  static Map<String, List<int>> _decodeFiles(List<int> bytes, String id) {
    final bundle = jsonDecode(utf8.decode(bytes));
    if (bundle is! Map || bundle['id'] != id || bundle['files'] is! List) {
      throw const FormatException('业务包格式无效');
    }
    final rows = bundle['files'] as List;
    if (rows.isEmpty || rows.length > 128) {
      throw const FormatException('业务文件数量无效');
    }
    final result = <String, List<int>>{};
    var total = 0;
    for (final row in rows) {
      if (row is! Map || row['path'] is! String || row['data'] is! String) {
        throw const FormatException('业务文件字段无效');
      }
      final name = row['path'] as String;
      final segments = name.split('/');
      if (!RegExp(r'^[A-Za-z0-9_./-]{1,128}$').hasMatch(name) ||
          name.startsWith('/') ||
          segments.contains('..') ||
          segments.contains('.') ||
          segments.contains('') ||
          name == 'manifest.json' ||
          name == 'bundle.json' ||
          result.containsKey(name)) {
        throw const FormatException('业务文件路径无效');
      }
      final decoded = base64Decode(row['data'] as String);
      total += decoded.length;
      if (decoded.length > 2 * 1024 * 1024 || total > 8 * 1024 * 1024) {
        throw const FormatException('业务文件超过大小限制');
      }
      result[name] = decoded;
    }
    // 禁止文件同时作为另一文件的父目录，避免写入一半才出现结构冲突。
    for (final name in result.keys) {
      final segments = name.split('/');
      for (var index = 1; index < segments.length; index++) {
        if (result.containsKey(segments.take(index).join('/'))) {
          throw const FormatException('业务文件路径冲突');
        }
      }
    }
    if (!result.containsKey('index.html')) {
      throw const FormatException('业务包缺少入口');
    }
    return result;
  }

  /// 释放更新请求，取消后不再提交文件或状态。
  void close() {
    if (_closed) return;
    _closed = true;
    _cancel.complete();
  }
}
