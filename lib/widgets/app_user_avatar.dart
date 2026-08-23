import 'package:flutter/material.dart';

import '../models/app_user.dart';

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
