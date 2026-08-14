import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/theme/app_theme.dart';

void main() {
  test('theme construction does not depend on the previous global mode', () {
    AppColors.isDark = false;
    final dark = AppTheme.dark();
    expect(dark.scaffoldBackgroundColor, const Color(0xFF121212));
    expect(dark.colorScheme.surface, const Color(0xFF1E1E1E));

    AppColors.isDark = true;
    final light = AppTheme.light();
    expect(light.scaffoldBackgroundColor, const Color(0xFFFFFFFF));
    expect(light.colorScheme.surface, const Color(0xFFFFFFFF));
  });
}
