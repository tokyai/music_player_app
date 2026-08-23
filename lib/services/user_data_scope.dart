import 'dart:collection';

import '../models/app_user.dart';

/// Immutable storage namespace captured by every user-owned service.
class UserDataScope {
  static const _prefix = 'kuzai_user_data_v1.';
  static const defaultScope = UserDataScope(AppUserProfile.defaultUserId);
  static final LinkedHashSet<String> _deletedUserIds = LinkedHashSet();
  static const _maxDeletedUserIds = 64;

  final String userId;

  const UserDataScope(this.userId);

  bool get isDefault => userId == AppUserProfile.defaultUserId;
  bool get isDeleted => !isDefault && _deletedUserIds.contains(userId);

  static void markDeleted(String userId) {
    if (userId == AppUserProfile.defaultUserId) return;
    _deletedUserIds
      ..remove(userId)
      ..add(userId);
    while (_deletedUserIds.length > _maxDeletedUserIds) {
      _deletedUserIds.remove(_deletedUserIds.first);
    }
  }

  String preferenceKey(String legacyKey) {
    return isDefault ? legacyKey : '$_prefix$userId.$legacyKey';
  }

  String secureStorageKey(String legacyKey) {
    return isDefault ? legacyKey : '$_prefix$userId.$legacyKey';
  }

  String get preferencePrefix => '$_prefix$userId.';

  bool ownsPreferenceKey(String key) =>
      !isDefault && key.startsWith(preferencePrefix);

  String get audioCacheRelativePath =>
      isDefault ? 'audio_cache' : 'audio_cache_users/$userId';

  @override
  bool operator ==(Object other) =>
      other is UserDataScope && other.userId == userId;

  @override
  int get hashCode => userId.hashCode;
}
