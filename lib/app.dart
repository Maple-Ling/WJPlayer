import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers/app_providers.dart';
import 'core/services/font_service.dart';
import 'core/theme/app_theme.dart';
import 'routes/app_router.dart';
import 'ui/widgets/common/app_update_gate.dart';
import 'ui/widgets/common/tv_focus_widgets.dart';

class WJPlayerApp extends ConsumerWidget {
  const WJPlayerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    // 自定义全局字体：路径非空即套用已加载的字体家族。
    final fontFamily = ref.watch(customAppFontPathProvider).isEmpty
        ? null
        : FontService.appFontFamily;

    final accent = ref.watch(accentColorProvider);
    final lightTheme = AppTheme.withFontFamily(AppTheme.lightTheme, fontFamily).copyWith(
      colorScheme: AppTheme.lightTheme.colorScheme.copyWith(primary: accent, secondary: accent.withValues(alpha: 0.72)),
    );
    final darkTheme = AppTheme.withFontFamily(AppTheme.darkTheme, fontFamily).copyWith(
      colorScheme: AppTheme.darkTheme.colorScheme.copyWith(primary: accent, secondary: accent.withValues(alpha: 0.72)),
    );

    return MaterialApp.router(
      title: '无界影视',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      locale: locale,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en'),
      ],
      themeMode: switch (themeMode) {
        ThemeModeOption.light => ThemeMode.light,
        ThemeModeOption.dark => ThemeMode.dark,
        ThemeModeOption.system => ThemeMode.system,
      },
      routerConfig: router,
      builder: (context, child) => Focus(
        autofocus: true,
        child: TvKeyboardListener(
          child: AppUpdateGate(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
  }
}
