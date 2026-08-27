import 'dart:io';

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../services/user_avatar_storage.dart';

class AppUserAvatar extends StatelessWidget {
  const AppUserAvatar({super.key, required this.user, required this.size});

  final AppUserProfile user;
  final double size;

  static const _colors = <Color>[
    Color(0xFF356859),
    Color(0xFFB64242),
    Color(0xFF2F5E8E),
    Color(0xFF7A4B87),
    Color(0xFF8A5A2B),
    Color(0xFF39727D),
    Color(0xFF5D6178),
    Color(0xFF8A4965),
  ];

  @override
  Widget build(BuildContext context) {
    if (user.hasCustomAvatar) {
      return _CustomUserAvatar(user: user, size: size);
    }
    if (user.avatarId == 'logo') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.asset(
          'assets/images/app_logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    }
    final color =
        _colors[user.avatarColorIndex.clamp(0, _colors.length - 1).toInt()];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Icon(
        _iconFor(user.avatarId),
        size: size * 0.54,
        color: Colors.white,
      ),
    );
  }

  static IconData _iconFor(String id) => switch (id) {
    'music' => Icons.music_note_rounded,
    'headphones' => Icons.headphones_rounded,
    'star' => Icons.star_rounded,
    'car' => Icons.directions_car_filled_rounded,
    'album' => Icons.album_rounded,
    'smile' => Icons.sentiment_satisfied_alt_rounded,
    _ => Icons.person_rounded,
  };
}

class _CustomUserAvatar extends StatefulWidget {
  const _CustomUserAvatar({required this.user, required this.size});

  final AppUserProfile user;
  final double size;

  @override
  State<_CustomUserAvatar> createState() => _CustomUserAvatarState();
}

class _CustomUserAvatarState extends State<_CustomUserAvatar> {
  late Future<File?> _file;

  @override
  void initState() {
    super.initState();
    _file = UserAvatarStorage.shared.resolve(widget.user.avatarFileName);
  }

  @override
  void didUpdateWidget(covariant _CustomUserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.avatarFileName != widget.user.avatarFileName) {
      _file = UserAvatarStorage.shared.resolve(widget.user.avatarFileName);
    }
  }

  @override
  Widget build(BuildContext context) {
    final decodeSize = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(32, UserAvatarStorage.maxAvatarDimension)
        .toInt();
    return ClipOval(
      child: SizedBox.square(
        dimension: widget.size,
        child: FutureBuilder<File?>(
          future: _file,
          builder: (context, snapshot) {
            final file = snapshot.data;
            if (file == null) return _fallback();
            return Image.file(
              file,
              key: ValueKey('user-custom-avatar-${widget.user.id}'),
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
              cacheWidth: decodeSize,
              cacheHeight: decodeSize,
              filterQuality: FilterQuality.low,
              errorBuilder: (_, _, _) => _fallback(),
            );
          },
        ),
      ),
    );
  }

  Widget _fallback() => ColoredBox(
    color: const Color(0xFF5D6178),
    child: Icon(
      Icons.person_rounded,
      size: widget.size * 0.54,
      color: Colors.white,
    ),
  );
}
