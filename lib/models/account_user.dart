class AccountUser {
  final String id;
  final String username;
  final String role;
  final String status;
  final String? statusReason;

  const AccountUser({
    required this.id,
    required this.username,
    required this.role,
    required this.status,
    this.statusReason,
  });

  factory AccountUser.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final username = json['username']?.toString() ?? '';
    if (id.isEmpty || username.isEmpty) {
      throw const FormatException('账号信息不完整');
    }
    return AccountUser(
      id: id,
      username: username,
      role: json['role']?.toString() ?? 'user',
      status: json['status']?.toString() ?? 'active',
      statusReason: json['statusReason']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'role': role,
    'status': status,
    'statusReason': statusReason,
  };
}
