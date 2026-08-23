class AppUserProfile {
  static const defaultUserId = 'default';
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

  const AppUserProfile({
    required this.id,
    required this.name,
    required this.avatarId,
    required this.avatarColorIndex,
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
  }) {
    return AppUserProfile(
      id: id,
      name: name ?? this.name,
      avatarId: avatarId ?? this.avatarId,
      avatarColorIndex: avatarColorIndex ?? this.avatarColorIndex,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'avatarId': avatarId,
    'avatarColorIndex': avatarColorIndex,
  };

  factory AppUserProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final name = normalizeName(json['name']?.toString() ?? '');
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id)) {
      throw const FormatException('用户 ID 无效');
    }
    final rawAvatar = json['avatarId']?.toString();
    final avatarId = avatarIds.contains(rawAvatar) ? rawAvatar! : 'person';
    final rawColor = json['avatarColorIndex'];
    final color = rawColor is num
        ? rawColor.toInt().clamp(0, avatarColorCount - 1).toInt()
        : 0;
    return AppUserProfile(
      id: id,
      name: name,
      avatarId: avatarId,
      avatarColorIndex: color,
    );
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
