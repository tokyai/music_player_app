import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player_app/theme/app_theme.dart';

void main() {
  test('theme construction does not depend on the previous global mode', () {
    AppColors.isDark = false;
    final dark = AppTheme.dark();
    expect(dark.scaffoldBackgroundColor, const Color(0xFF101216));
    expect(dark.colorScheme.surface, const Color(0xFF181B20));

    AppColors.isDark = true;
    final light = AppTheme.light();
    expect(light.scaffoldBackgroundColor, const Color(0xFFF7F8FA));
    expect(light.colorScheme.surface, const Color(0xFFFFFFFF));
  });

  test('shared controls use readable typography and rounded rectangles', () {
    final theme = AppTheme.light();
    final input =
        theme.inputDecorationTheme.enabledBorder as OutlineInputBorder;
    final button =
        theme.filledButtonTheme.style?.shape?.resolve({})
            as RoundedRectangleBorder;
    final card = theme.cardTheme.shape as RoundedRectangleBorder;
    final listTile = theme.listTileTheme.shape as RoundedRectangleBorder;

    expect(input.borderRadius.topLeft.x, AppRadius.control);
    expect((button.borderRadius as BorderRadius).topLeft.x, AppRadius.control);
    expect((card.borderRadius as BorderRadius).topLeft.x, AppRadius.card);
    expect((listTile.borderRadius as BorderRadius).topLeft.x, AppRadius.card);
    expect(theme.textTheme.bodyLarge?.fontSize, greaterThanOrEqualTo(20));
    expect(theme.textTheme.bodyMedium?.fontSize, greaterThanOrEqualTo(18));
  });
}
