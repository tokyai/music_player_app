import 'package:flutter/material.dart';
import '../models/song.dart';

/// 全局配色与主题 —— 简洁标准 Material 风格（支持亮/暗双模式）
class AppColors {
  /// 全局亮暗标志（由 AppTheme.light()/dark() 同步），颜色常量随主题变化
  static bool isDark = false;

  /// 让使用静态颜色令牌的组件订阅当前主题，并同步实际亮暗状态。
  ///
  /// 在 build 开头调用后，运行时切换主题会触发组件重建，避免 Material
  /// 默认组件已换色，而自定义容器仍保留上一个主题的颜色。
  static void syncWithTheme(BuildContext context) {
    isDark = Theme.of(context).brightness == Brightness.dark;
  }

  // 主色：标准蓝（Material 默认蓝系），亮暗通用
  static const primary = Color(0xFF2196F3);
  static const primaryDark = Color(0xFF1976D2);

  // 动态色（随 isDark 切换）
  static Color get primarySoft =>
      isDark ? const Color(0xFF1E3A5F) : const Color(0xFFE3F2FD);
  static Color get background =>
      isDark ? const Color(0xFF101216) : const Color(0xFFF7F8FA);
  static Color get surface =>
      isDark ? const Color(0xFF181B20) : const Color(0xFFFFFFFF);
  static Color get surfaceSoft =>
      isDark ? const Color(0xFF252930) : const Color(0xFFEEF1F4);
  static Color get textPrimary =>
      isDark ? const Color(0xFFF1F3F5) : const Color(0xFF20242B);
  static Color get textSecondary =>
      isDark ? const Color(0xFF9AA0A8) : const Color(0xFF646A73);
  static Color get textHint =>
      isDark ? const Color(0xFF6B7075) : const Color(0xFF9AA0A8);
  static Color get cardShadow =>
      isDark ? const Color(0x40000000) : const Color(0x0F000000);
  static Color get outline =>
      isDark ? const Color(0xFF30353D) : const Color(0xFFE3E7EC);
}

/// 全局圆角令牌。圆形播放按钮、头像和状态指示器仍保持圆形，
/// 其余卡片、面板、输入框与按钮统一采用圆角矩形。
class AppRadius {
  static const double control = 16;
  static const double card = 20;
  static const double panel = 24;
  static const double media = 16;
  static const double small = 12;
  static const double pill = 999;
}

/// 平台品牌色
class PlatformColors {
  static const netease = Color(0xFFE84D3D); // 网易云红
  static const qq = Color(0xFF31C27C); // QQ 绿
  static const kugou = Color(0xFF2CA2F9); // 酷狗蓝

  static Color of(MusicPlatform p) {
    switch (p) {
      case MusicPlatform.netease:
        return netease;
      case MusicPlatform.qq:
        return qq;
      case MusicPlatform.kugou:
        return kugou;
    }
  }
}

/// 应用主题（亮/暗双主题；实际生效主题的亮暗标志由 MaterialApp.builder 同步到 AppColors.isDark）
class AppTheme {
  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final background = isDark
        ? const Color(0xFF101216)
        : const Color(0xFFF7F8FA);
    final surface = isDark ? const Color(0xFF181B20) : const Color(0xFFFFFFFF);
    final surfaceSoft = isDark
        ? const Color(0xFF252930)
        : const Color(0xFFEEF1F4);
    final primarySoft = isDark
        ? const Color(0xFF1E3A5F)
        : const Color(0xFFE3F2FD);
    final textPrimary = isDark
        ? const Color(0xFFF1F3F5)
        : const Color(0xFF20242B);
    final textSecondary = isDark
        ? const Color(0xFF9AA0A8)
        : const Color(0xFF646A73);
    final textHint = isDark ? const Color(0xFF6B7075) : const Color(0xFF9AA0A8);
    final outline = isDark ? const Color(0xFF30353D) : const Color(0xFFE3E7EC);
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: brightness,
      primary: AppColors.primary,
    );
    final baseTypography = ThemeData(
      brightness: brightness,
      fontFamily: 'PingFang SC',
    ).textTheme;
    final textTheme = baseTypography.copyWith(
      displaySmall: TextStyle(
        color: textPrimary,
        fontSize: 38,
        height: 1.2,
        fontWeight: FontWeight.w700,
      ),
      headlineSmall: TextStyle(
        color: textPrimary,
        fontSize: 32,
        height: 1.24,
        fontWeight: FontWeight.w700,
      ),
      titleLarge: TextStyle(
        color: textPrimary,
        fontSize: 27,
        height: 1.25,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: TextStyle(
        color: textPrimary,
        fontSize: 22,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(color: textPrimary, fontSize: 20, height: 1.35),
      bodyMedium: TextStyle(color: textSecondary, fontSize: 18, height: 1.35),
      bodySmall: TextStyle(color: textHint, fontSize: 16, height: 1.3),
      labelLarge: TextStyle(
        color: textPrimary,
        fontSize: 19,
        height: 1.2,
        fontWeight: FontWeight.w600,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme.copyWith(
        primary: AppColors.primary,
        secondary: AppColors.primaryDark,
        surface: surface,
        onSurface: textPrimary,
      ),
      scaffoldBackgroundColor: background,
      fontFamily: 'PingFang SC',
      fontFamilyFallback: const [
        'Noto Sans CJK SC',
        'Source Han Sans SC',
        'Roboto',
      ],
      textTheme: textTheme,
      splashFactory: InkRipple.splashFactory,
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: outline),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.panel),
        ),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 26,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: TextStyle(
          color: textSecondary,
          fontSize: 18,
          height: 1.4,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        textStyle: TextStyle(color: textPrimary, fontSize: 18),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 72,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 28,
          fontWeight: FontWeight.w700,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: primarySoft,
        height: 80,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 17,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.primary : textSecondary,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? AppColors.primary : textSecondary,
          );
        }),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: AppColors.primary,
        unselectedLabelColor: textSecondary,
        indicatorColor: AppColors.primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w500,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: TextStyle(color: textHint, fontSize: 19),
        labelStyle: TextStyle(color: textSecondary, fontSize: 18),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 15,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          minimumSize: const Size(52, 50),
          textStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          minimumSize: const Size(52, 50),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(50, 50),
          iconSize: 30,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textSecondary,
        minVerticalPadding: 10,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 21,
          fontWeight: FontWeight.w600,
        ),
        subtitleTextStyle: TextStyle(
          color: textSecondary,
          fontSize: 18,
          height: 1.35,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: surfaceSoft,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: textPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        contentTextStyle: TextStyle(
          color: isDark ? const Color(0xFF20242B) : Colors.white,
          fontSize: 18,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.panel),
          ),
        ),
      ),
    );
  }
}

/// 通用卡片装饰（供各页面复用，颜色随主题动态）
class CardStyle {
  static BoxDecoration softCard() => BoxDecoration(
    color: AppColors.surface,
    borderRadius: BorderRadius.circular(AppRadius.card),
    border: Border.all(color: AppColors.outline),
    boxShadow: [
      BoxShadow(
        color: AppColors.cardShadow,
        blurRadius: 12,
        offset: const Offset(0, 4),
      ),
    ],
  );
}
