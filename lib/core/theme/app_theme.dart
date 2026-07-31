import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'td_platform_theme.dart';

/// Material 3 主题配置
class AppTheme {
  AppTheme._();
  
  static const double borderRadiusSmall = 4;
  static const double borderRadiusMedium = 8;
  static const double borderRadiusLarge = 12;
  static const double borderRadiusXLarge = 16;
  static const double borderRadiusXXLarge = 24;
  
  static const double spacingUnit = 4;
  static const double spacing1 = 4;
  static const double spacing2 = 8;
  static const double spacing3 = 12;
  static const double spacing4 = 16;
  static const double spacing5 = 24;
  static const double spacing6 = 32;
  static const double spacing7 = 48;
  static const double spacing8 = 64;
  
  static const double textSizeXS = 12;
  static const double textSizeSM = 14;
  static const double textSizeBase = 16;
  static const double textSizeLG = 18;
  static const double textSizeXL = 20;
  static const double textSize2XL = 24;
  static const double textSize3XL = 28;
  static const double textSize4XL = 32;
  static const double textSize5XL = 40;
  static const double textSize6XL = 48;

  static const TextTheme _lightTextTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: textSize6XL,
      fontWeight: FontWeight.bold,
      color: AppColors.lightText,
    ),
    displayMedium: TextStyle(
      fontSize: textSize5XL,
      fontWeight: FontWeight.bold,
      color: AppColors.lightText,
    ),
    displaySmall: TextStyle(
      fontSize: textSize4XL,
      fontWeight: FontWeight.bold,
      color: AppColors.lightText,
    ),
    headlineLarge: TextStyle(
      fontSize: textSize3XL,
      fontWeight: FontWeight.w600,
      color: AppColors.lightText,
    ),
    headlineMedium: TextStyle(
      fontSize: textSize2XL,
      fontWeight: FontWeight.w600,
      color: AppColors.lightText,
    ),
    headlineSmall: TextStyle(
      fontSize: textSizeXL,
      fontWeight: FontWeight.w600,
      color: AppColors.lightText,
    ),
    titleLarge: TextStyle(
      fontSize: textSizeLG,
      fontWeight: FontWeight.w600,
      color: AppColors.lightText,
    ),
    titleMedium: TextStyle(
      fontSize: textSizeBase,
      fontWeight: FontWeight.w600,
      color: AppColors.lightText,
    ),
    titleSmall: TextStyle(
      fontSize: textSizeSM,
      fontWeight: FontWeight.w500,
      color: AppColors.lightText,
    ),
    bodyLarge: TextStyle(fontSize: textSizeBase, color: AppColors.lightText),
    bodyMedium: TextStyle(fontSize: textSizeSM, color: AppColors.lightText),
    bodySmall: TextStyle(
      fontSize: textSizeXS,
      color: AppColors.lightTextSecondary,
    ),
  );

  static const TextTheme _darkTextTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: textSize6XL,
      fontWeight: FontWeight.bold,
      color: AppColors.darkText,
    ),
    displayMedium: TextStyle(
      fontSize: textSize5XL,
      fontWeight: FontWeight.bold,
      color: AppColors.darkText,
    ),
    displaySmall: TextStyle(
      fontSize: textSize4XL,
      fontWeight: FontWeight.bold,
      color: AppColors.darkText,
    ),
    headlineLarge: TextStyle(
      fontSize: textSize3XL,
      fontWeight: FontWeight.w600,
      color: AppColors.darkText,
    ),
    headlineMedium: TextStyle(
      fontSize: textSize2XL,
      fontWeight: FontWeight.w600,
      color: AppColors.darkText,
    ),
    headlineSmall: TextStyle(
      fontSize: textSizeXL,
      fontWeight: FontWeight.w600,
      color: AppColors.darkText,
    ),
    titleLarge: TextStyle(
      fontSize: textSizeLG,
      fontWeight: FontWeight.w600,
      color: AppColors.darkText,
    ),
    titleMedium: TextStyle(
      fontSize: textSizeBase,
      fontWeight: FontWeight.w600,
      color: AppColors.darkText,
    ),
    titleSmall: TextStyle(
      fontSize: textSizeSM,
      fontWeight: FontWeight.w500,
      color: AppColors.darkText,
    ),
    bodyLarge: TextStyle(fontSize: textSizeBase, color: AppColors.darkText),
    bodyMedium: TextStyle(fontSize: textSizeSM, color: AppColors.darkText),
    bodySmall: TextStyle(
      fontSize: textSizeXS,
      color: AppColors.darkTextSecondary,
    ),
  );

  /// 全局 SnackBar 主题：浮动圆角气泡，取代默认「底部贴边大黑框」。
  /// 业务侧已逐步迁移到 [AppToast] 顶部气泡；这里作为兜底，让任何残留的
  /// 原生 SnackBar 也呈现一致的浮动圆角气泡观感。
  static SnackBarThemeData _snackBarTheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 6,
      backgroundColor:
          dark ? const Color(0xFF2A2A2E) : const Color(0xFF323236),
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: textSizeSM,
        fontWeight: FontWeight.w500,
      ),
      actionTextColor: AppColors.brandLight,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadiusXLarge),
      ),
    );
  }

  // ---- TDesign 风格组件主题（统一观感，不替换 Material 控件本身）----
  // TDesign token：按钮/输入框圆角 6，对话框圆角 12（radiusExtraLarge）。
  static const double _tdRadiusDefault = 6;
  static const double _tdRadiusDialog = 12;
  static const Size _tdButtonMinSize = Size(0, 48);
  static const EdgeInsets _tdButtonPadding = EdgeInsets.symmetric(horizontal: 24);
  static final RoundedRectangleBorder _tdButtonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(_tdRadiusDefault),
  );
  static const TextStyle _tdButtonText =
      TextStyle(fontSize: textSizeBase, fontWeight: FontWeight.w600);

  /// 实心/凸起按钮（FilledButton / ElevatedButton）：TDesign 实心按钮观感。
  static final FilledButtonThemeData _filledButtonTheme = FilledButtonThemeData(
    style: FilledButton.styleFrom(
      elevation: 0,
      minimumSize: _tdButtonMinSize,
      padding: _tdButtonPadding,
      shape: _tdButtonShape,
      textStyle: _tdButtonText,
    ),
  );
  static final ElevatedButtonThemeData _elevatedButtonTheme =
      ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      elevation: 0,
      minimumSize: _tdButtonMinSize,
      padding: _tdButtonPadding,
      shape: _tdButtonShape,
      textStyle: _tdButtonText,
    ),
  );

  /// 描边按钮：TDesign outline 风格。
  static final OutlinedButtonThemeData _outlinedButtonTheme =
      OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: _tdButtonMinSize,
      padding: _tdButtonPadding,
      shape: _tdButtonShape,
      textStyle: _tdButtonText,
    ),
  );

  /// 文字按钮：TDesign text 风格（字重略轻）。
  static final TextButtonThemeData _textButtonTheme = TextButtonThemeData(
    style: TextButton.styleFrom(
      padding: _tdButtonPadding,
      shape: _tdButtonShape,
      textStyle: const TextStyle(fontSize: textSizeBase, fontWeight: FontWeight.w500),
    ),
  );

  /// 对话框：TDesign 圆角 12 + 标题字重。
  static final DialogThemeData _dialogTheme = DialogThemeData(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_tdRadiusDialog),
    ),
    titleTextStyle: const TextStyle(
      fontSize: textSizeLG,
      fontWeight: FontWeight.w600,
    ),
  );

  /// 输入框：TDesign 填充式 + 圆角 6，聚焦描品牌色。fillColor 随明暗。
  static InputDecorationTheme _inputTheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final fill = dark ? AppColors.darkSurface : AppColors.lightSurface;
    final brand = dark ? AppColors.brandLight : AppColors.brand;
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(_tdRadiusDefault),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecorationTheme(
      filled: true,
      fillColor: fill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: border(Colors.transparent, 0),
      enabledBorder: border(
        dark ? AppColors.darkDivider : AppColors.lightDivider,
        1,
      ),
      focusedBorder: border(brand, 1.5),
    );
  }

  /// 把自定义字体家族名套用到一份 [ThemeData] 的全部文本主题上。
  /// [family] 为空时原样返回（用系统默认字体）。供三端在构建 MaterialApp 时调用。
  static ThemeData withFontFamily(ThemeData base, String? family) {
    if (family == null || family.isEmpty) return base;
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: family),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: family),
    );
  }

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      // TDesign 主题挂到 Material 扩展上，TD 组件随明暗自动取色（见 needMultiTheme）。
      // 移动端尺寸档；桌面端在 _desktopTheme 覆盖为 desktop 档。
      extensions: [tdThemeFor(AppFormFactor.mobile)],
      colorScheme: const ColorScheme.light(
        primary: AppColors.brand,
        onPrimary: Colors.white,
        secondary: AppColors.brandLight,
        onSecondary: Colors.white,
        surface: AppColors.lightSurface,
        onSurface: AppColors.lightText,
        error: AppColors.error,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: AppColors.lightBackground,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadiusLarge),
        ),
        color: AppColors.lightSurface,
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: AppColors.lightBackground,
        foregroundColor: AppColors.lightText,
        titleTextStyle: TextStyle(
          fontSize: textSizeLG,
          fontWeight: FontWeight.w600,
          color: AppColors.lightText,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.lightSurface,
        selectedItemColor: AppColors.brand,
        unselectedItemColor: AppColors.lightTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.lightDivider,
        thickness: 1,
      ),
      textTheme: _lightTextTheme,
      filledButtonTheme: _filledButtonTheme,
      elevatedButtonTheme: _elevatedButtonTheme,
      outlinedButtonTheme: _outlinedButtonTheme,
      textButtonTheme: _textButtonTheme,
      dialogTheme: _dialogTheme,
      inputDecorationTheme: _inputTheme(Brightness.light),
      snackBarTheme: _snackBarTheme(Brightness.light),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.all(const Color(0xFF5B8DEF).withValues(alpha: 0.3)),
        trackColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      extensions: [tdThemeFor(AppFormFactor.mobile, dark: true)],
      colorScheme: const ColorScheme.dark(
        primary: AppColors.brandLight,
        onPrimary: Colors.black,
        secondary: AppColors.brand,
        onSecondary: Colors.white,
        surface: AppColors.darkSurface,
        onSurface: AppColors.darkText,
        error: AppColors.error,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: AppColors.darkBackground,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadiusLarge),
        ),
        color: AppColors.darkSurface,
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: AppColors.darkBackground,
        foregroundColor: AppColors.darkText,
        titleTextStyle: TextStyle(
          fontSize: textSizeLG,
          fontWeight: FontWeight.w600,
          color: AppColors.darkText,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.darkSurface,
        selectedItemColor: AppColors.brandLight,
        unselectedItemColor: AppColors.darkTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.darkDivider,
        thickness: 1,
      ),
      textTheme: _darkTextTheme,
      filledButtonTheme: _filledButtonTheme,
      elevatedButtonTheme: _elevatedButtonTheme,
      outlinedButtonTheme: _outlinedButtonTheme,
      textButtonTheme: _textButtonTheme,
      dialogTheme: _dialogTheme,
      inputDecorationTheme: _inputTheme(Brightness.dark),
      snackBarTheme: _snackBarTheme(Brightness.dark),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.all(const Color(0xFF5B8DEF).withValues(alpha: 0.4)),
        trackColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }
}
