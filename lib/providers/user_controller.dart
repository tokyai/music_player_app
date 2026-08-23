import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';
import '../services/audio_cache_service.dart';
import '../services/user_avatar_storage.dart';
import '../services/user_data_scope.dart';

class UserController extends ChangeNotifier {
  static const maxUsers = 8;
  static const _profilesKey = 'kuzai_users_v1';
  static const _activeUserKey = 'kuzai_active_user_v1';
  static const _aiSecretKey = 'ai_assistant_api_key';

  final List<AppUserProfile> _users = [];
  final Random _random = Random.secure();
  final UserAvatarStorage _avatarStorage;
  String _activeUserId = AppUserProfile.defaultUserId;
  bool _switching = false;
  bool _disposed = false;
  Future<void> Function(String userId)? _sessionSwitcher;

  UserController({UserAvatarStorage? avatarStorage})
    : _avatarStorage = avatarStorage ?? UserAvatarStorage.shared {
    ready = _load();
  }

  late final Future<void> ready;

  List<AppUserProfile> get users => List.unmodifiable(_users);
  bool get switching => _switching;
  String get activeUserId => _activeUserId;
  UserDataScope get activeScope => UserDataScope(_activeUserId);

  AppUserProfile get activeUser => userById(_activeUserId);

  AppUserProfile userById(String id) {
    for (final user in _users) {
      if (user.id == id) return user;
    }
    return _users.firstWhere(
      (user) => user.isDefault,
      orElse: () => AppUserProfile.defaultUser,
    );
  }

  void attachSessionSwitcher(Future<void> Function(String userId) switcher) {
    _sessionSwitcher = switcher;
  }

  void detachSessionSwitcher() {
    _sessionSwitcher = null;
  }

  Future<AppUserProfile> createUser({
    required String name,
    required String avatarId,
    required int avatarColorIndex,
    Uint8List? customAvatarBytes,
  }) async {
    await ready;
    if (_disposed) throw StateError('用户管理已释放');
    if (_users.length >= maxUsers) throw StateError('最多可创建 $maxUsers 个用户');
    final normalizedName = AppUserProfile.normalizeName(name);
    _ensureUniqueName(normalizedName);
    final id = _newUserId();
    String? avatarFileName;
    late final AppUserProfile profile;
    try {
      if (customAvatarBytes != null) {
        avatarFileName = await _avatarStorage.save(id, customAvatarBytes);
      }
      if (_disposed) throw StateError('用户管理已释放');
      profile = AppUserProfile(
        id: id,
        name: normalizedName,
        avatarId: avatarFileName != null
            ? AppUserProfile.customAvatarId
            : _builtInAvatarId(avatarId),
        avatarColorIndex: avatarColorIndex
            .clamp(0, AppUserProfile.avatarColorCount - 1)
            .toInt(),
        avatarFileName: avatarFileName,
      );
      final next = [..._users, profile];
      await _persistUsers(next);
      _users
        ..clear()
        ..addAll(next);
    } catch (_) {
      await _tryDeleteAvatar(avatarFileName);
      rethrow;
    }
    _notify();
    return profile;
  }

  Future<void> updateUser(
    String id, {
    required String name,
    required String avatarId,
    required int avatarColorIndex,
    Uint8List? customAvatarBytes,
  }) async {
    await ready;
    if (_disposed) throw StateError('用户管理已释放');
    final index = _users.indexWhere((user) => user.id == id);
    if (index < 0) throw StateError('用户不存在');
    final normalizedName = AppUserProfile.normalizeName(name);
    _ensureUniqueName(normalizedName, exceptId: id);
    final previous = _users[index];
    String? newAvatarFileName;
    late final AppUserProfile updated;
    try {
      if (customAvatarBytes != null) {
        newAvatarFileName = await _avatarStorage.save(id, customAvatarBytes);
      }
      if (_disposed) throw StateError('用户管理已释放');
      final preserveCustomAvatar =
          newAvatarFileName == null &&
          avatarId == AppUserProfile.customAvatarId &&
          previous.hasCustomAvatar;
      final selectedAvatarFileName =
          newAvatarFileName ??
          (preserveCustomAvatar ? previous.avatarFileName : null);
      updated = previous.copyWith(
        name: normalizedName,
        avatarId: selectedAvatarFileName != null
            ? AppUserProfile.customAvatarId
            : _builtInAvatarId(avatarId),
        avatarColorIndex: avatarColorIndex
            .clamp(0, AppUserProfile.avatarColorCount - 1)
            .toInt(),
        avatarFileName: selectedAvatarFileName,
        clearAvatarFileName: selectedAvatarFileName == null,
      );
      final next = [..._users]..[index] = updated;
      await _persistUsers(next);
    } catch (_) {
      await _tryDeleteAvatar(newAvatarFileName);
      rethrow;
    }
    _users[index] = updated;
    _notify();
    if (previous.avatarFileName != updated.avatarFileName) {
      await _tryDeleteAvatar(previous.avatarFileName);
    }
  }

  Future<void> switchUser(String id) async {
    await ready;
    if (_disposed || id == _activeUserId) return;
    if (!_users.any((user) => user.id == id)) throw StateError('用户不存在');
    if (_switching) throw StateError('正在切换用户，请稍候');
    _switching = true;
    _notify();
    try {
      final switcher = _sessionSwitcher;
      if (switcher == null) {
        await activatePreparedUser(id);
      } else {
        await switcher(id);
      }
    } finally {
      _switching = false;
      _notify();
    }
  }

  /// Called by the app session host only after the target providers are ready.
  Future<void> activatePreparedUser(String id) async {
    if (!_users.any((user) => user.id == id)) throw StateError('用户不存在');
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(_activeUserKey, id);
    if (!saved) throw StateError('保存当前用户失败');
    _activeUserId = id;
    _notify();
  }

  Future<void> deleteUser(String id) async {
    await ready;
    if (_disposed) throw StateError('用户管理已释放');
    final profile = userById(id);
    if (profile.id != id) return;
    if (profile.isDefault) throw StateError('默认用户不能删除');
    if (_activeUserId == id) {
      await switchUser(AppUserProfile.defaultUserId);
    }
    if (_activeUserId == id) throw StateError('请先切换到其他用户');

    final next = _users.where((user) => user.id != id).toList(growable: false);
    await _persistUsers(next);
    _users
      ..clear()
      ..addAll(next);
    _notify();
    UserDataScope.markDeleted(id);
    try {
      await _deleteUserData(UserDataScope(id));
    } finally {
      await _tryDeleteUserAvatars(id);
    }
  }

  Future<void> _load() async {
    final loaded = <AppUserProfile>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_profilesKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final value in decoded.take(maxUsers)) {
            if (value is! Map) continue;
            try {
              final user = AppUserProfile.fromJson(
                Map<String, dynamic>.from(value),
              );
              if (loaded.any((current) => current.id == user.id)) continue;
              loaded.add(user);
            } on FormatException {
              // Keep the remaining valid users available.
            }
          }
        }
      }
      final defaultIndex = loaded.indexWhere((user) => user.isDefault);
      if (defaultIndex < 0) {
        loaded.insert(0, AppUserProfile.defaultUser);
      } else if (defaultIndex > 0) {
        final defaultUser = loaded.removeAt(defaultIndex);
        loaded.insert(0, defaultUser);
      }
      _users
        ..clear()
        ..addAll(loaded.take(maxUsers));
      final requested = prefs.getString(_activeUserKey);
      _activeUserId = _users.any((user) => user.id == requested)
          ? requested!
          : AppUserProfile.defaultUserId;
      try {
        await _persistUsers(_users);
        await prefs.setString(_activeUserKey, _activeUserId);
      } catch (error, stackTrace) {
        // A temporary write failure must not discard a list that was read
        // successfully. The next mutation will retry persistence.
        debugPrint('规范化用户列表失败: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    } catch (error, stackTrace) {
      debugPrint('加载用户列表失败: $error');
      debugPrintStack(stackTrace: stackTrace);
      _users
        ..clear()
        ..add(AppUserProfile.defaultUser);
      _activeUserId = AppUserProfile.defaultUserId;
    }
    _notify();
  }

  Future<void> _persistUsers(Iterable<AppUserProfile> users) async {
    final encoded = jsonEncode(users.map((user) => user.toJson()).toList());
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(_profilesKey, encoded);
    if (!saved) throw StateError('保存用户列表失败');
  }

  Future<void> _deleteUserData(UserDataScope scope) async {
    await _deleteScopedPreferences(scope);
    await _deleteScopedSecret(scope);
    await AudioCacheService.deleteUserCache(scope);
    // Repeat the cheap key cleanup after queued cache and plugin operations
    // have drained, covering a write that was already in flight at deletion.
    await _deleteScopedPreferences(scope);
    await _deleteScopedSecret(scope);
  }

  Future<void> _deleteScopedPreferences(UserDataScope scope) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs
          .getKeys()
          .where(scope.ownsPreferenceKey)
          .toList(growable: false);
      for (final key in keys) {
        await prefs.remove(key);
      }
    } catch (error, stackTrace) {
      debugPrint('清理用户偏好失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _deleteScopedSecret(UserDataScope scope) async {
    try {
      await const FlutterSecureStorage().delete(
        key: scope.secureStorageKey(_aiSecretKey),
      );
    } catch (error, stackTrace) {
      debugPrint('清理用户安全配置失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _ensureUniqueName(String name, {String? exceptId}) {
    final normalized = name.toLowerCase();
    if (_users.any(
      (user) => user.id != exceptId && user.name.toLowerCase() == normalized,
    )) {
      throw StateError('用户名称已存在');
    }
  }

  static String _builtInAvatarId(String avatarId) =>
      AppUserProfile.avatarIds.contains(avatarId) ? avatarId : 'person';

  Future<void> _tryDeleteAvatar(String? fileName) async {
    if (fileName == null) return;
    try {
      await _avatarStorage.delete(fileName);
    } catch (error, stackTrace) {
      debugPrint('清理用户头像失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _tryDeleteUserAvatars(String userId) async {
    try {
      await _avatarStorage.deleteAllForUser(userId);
    } catch (error, stackTrace) {
      debugPrint('清理用户头像目录失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  String _newUserId() {
    while (true) {
      final id =
          'u_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 32).toRadixString(16)}';
      if (!_users.any((user) => user.id == id)) return id;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionSwitcher = null;
    super.dispose();
  }
}
