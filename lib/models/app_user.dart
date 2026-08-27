class AppUserProfile {
  static const defaultUserId = 'default';
  static const customAvatarId = 'custom';
  static const maxNameLength = 20;
  static const avatarIds = <String>{
    'logo',
    'person',
    'music',
    'headphones',
    'star',
    'car',
    'album',
    'smile',
  };
  static const avatarColorCount = 8;

  final String id;
  final String name;
  final String avatarId;
  final int avatarColorIndex;
  final String? avatarFileName;

  const AppUserProfile({
    required this.id,
    required this.name,
    required this.avatarId,
    required this.avatarColorIndex,
    this.avatarFileName,
  });

  static const defaultUser = AppUserProfile(
    id: defaultUserId,
    name: '默认用户',
    avatarId: 'logo',
    avatarColorIndex: 0,
  );

  bool get isDefault => id == defaultUserId;

  AppUserProfile copyWith({
    String? name,
    String? avatarId,
    int? avatarColorIndex,
    String? avatarFileName,
    bool clearAvatarFileName = false,
  }) {
    return AppUserProfile(
      id: id,
      name: name ?? this.name,
      avatarId: avatarId ?? this.avatarId,
      avatarColorIndex: avatarColorIndex ?? this.avatarColorIndex,
      avatarFileName: clearAvatarFileName
          ? null
          : avatarFileName ?? this.avatarFileName,
    );
  }

  bool get hasCustomAvatar =>
      avatarId == customAvatarId && avatarFileName != null;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'name': name,
      'avatarId': avatarId,
      'avatarColorIndex': avatarColorIndex,
    };
    if (hasCustomAvatar) json['avatarFileName'] = avatarFileName;
    return json;
  }

  factory AppUserProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final name = normalizeName(json['name']?.toString() ?? '');
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id)) {
      throw const FormatException('用户 ID 无效');
    }
    final rawAvatar = json['avatarId']?.toString();
    final rawAvatarFileName = json['avatarFileName']?.toString();
    final avatarFileName = isValidAvatarFileName(rawAvatarFileName)
        ? rawAvatarFileName
        : null;
    final avatarId = rawAvatar == customAvatarId && avatarFileName != null
        ? customAvatarId
        : avatarIds.contains(rawAvatar)
        ? rawAvatar!
        : 'person';
    final rawColor = json['avatarColorIndex'];
    final color = rawColor is num
        ? rawColor.toInt().clamp(0, avatarColorCount - 1).toInt()
        : 0;
    return AppUserProfile(
      id: id,
      name: name,
      avatarId: avatarId,
      avatarColorIndex: color,
      avatarFileName: avatarId == customAvatarId ? avatarFileName : null,
    );
  }

  static bool isValidAvatarFileName(String? value) {
    if (value == null || value.length > 160) return false;
    return RegExp(
      r'^avatar_[a-zA-Z0-9_-]{1,64}_[a-f0-9]{16,64}\.jpg$',
    ).hasMatch(value);
  }

  static String normalizeName(String value) {
    final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) throw const FormatException('用户名称不能为空');
    if (normalized.length > maxNameLength) {
      throw const FormatException('用户名称不能超过 20 个字');
    }
    return normalized;
  }
}
