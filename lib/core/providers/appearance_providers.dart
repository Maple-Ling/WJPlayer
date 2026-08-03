import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_preferences.dart';

enum ThemeModeOption { light, dark, system }

enum StartupPageOption { home, servers, resume }

ThemeModeOption parseThemeMode(String? value) {
  return switch (value) {
    'light' => ThemeModeOption.light,
    'dark' => ThemeModeOption.dark,
    _ => ThemeModeOption.system,
  };
}

Locale? parseLocaleTag(String? value) {
  switch (value) {
    case null:
    case '':
    case 'system':
      return null;
    case 'zh':
    case 'zh_CN':
      return const Locale('zh', 'CN');
    case 'en':
      return const Locale('en');
    default:
      final parts = value.split(RegExp('[-_]'));
      if (parts.isEmpty || parts.first.isEmpty) return null;
      return parts.length > 1 ? Locale(parts.first, parts[1]) : Locale(parts.first);
  }
}

String localeToPreferenceTag(Locale? locale) {
  if (locale == null) return 'system';
  return locale.toLanguageTag().replaceAll('-', '_');
}

StartupPageOption parseStartupPage(String? value) {
  return switch (value) {
    'servers' => StartupPageOption.servers,
    'resume' => StartupPageOption.resume,
    _ => StartupPageOption.home,
  };
}

bool _usesEnglishLabels(Locale? locale) => locale?.languageCode == 'en';

String localizedThemeModeLabel(ThemeModeOption mode, {Locale? displayLocale}) {
  final english = _usesEnglishLabels(displayLocale);
  switch (mode) {
    case ThemeModeOption.light:
      return english ? 'Light' : '浅色';
    case ThemeModeOption.dark:
      return english ? 'Dark' : '深色';
    case ThemeModeOption.system:
      return english ? 'Follow system' : '跟随系统';
  }
}

String localizedLocaleLabel(Locale? locale, {Locale? displayLocale}) {
  final english = _usesEnglishLabels(displayLocale);
  if (locale == null) {
    return english ? 'Follow system' : '跟随系统';
  }

  final normalized = locale.toLanguageTag().replaceAll('-', '_');
  switch (normalized) {
    case 'zh':
    case 'zh_CN':
      return english ? 'Simplified Chinese' : '简体中文';
    case 'en':
      return 'English';
    default:
      return normalized;
  }
}

String startupPageLabel(StartupPageOption option, {Locale? displayLocale}) {
  final english = _usesEnglishLabels(displayLocale);
  switch (option) {
    case StartupPageOption.home:
      return english ? 'Home' : '首页';
    case StartupPageOption.servers:
      return english ? 'Servers' : '服务器列表';
    case StartupPageOption.resume:
      return english ? 'Continue watching' : '继续观看';
  }
}

const String resumeRoutePath = '/resume';

String mobileStartupLocationFor(StartupPageOption option) {
  return switch (option) {
    StartupPageOption.home => '/home',
    StartupPageOption.servers => '/',
    StartupPageOption.resume => resumeRoutePath,
  };
}

String desktopStartupLocationFor(StartupPageOption option) {
  return switch (option) {
    StartupPageOption.home => '/',
    StartupPageOption.servers => '/servers',
    StartupPageOption.resume => resumeRoutePath,
  };
}

final themeModeProvider =
    StateNotifierProvider<PreferenceNotifier<ThemeModeOption>, ThemeModeOption>((ref) {
  return PreferenceNotifier<ThemeModeOption>(
    defaultValue: ThemeModeOption.system,
    readValue: (prefs) => parseThemeMode(prefs.getString('wjplayer_theme_mode')),
    writeValue: (prefs, value) async {
      await prefs.setString('wjplayer_theme_mode', value.name);
    },
  );
});

const appearanceAccentColors = <int>[
  0xFF5B8DEF,
  0xFF34A853,
  0xFFFF9500,
  0xFFFF2D55,
  0xFFAF52DE,
  0xFF00A8C6,
];

final accentColorProvider =
    StateNotifierProvider<PreferenceNotifier<Color>, Color>((ref) {
  return PreferenceNotifier<Color>(
    defaultValue: const Color(0xFF5B8DEF),
    readValue: (prefs) => Color(
      prefs.getInt('wjplayer_accent_color') ?? appearanceAccentColors.first,
    ),
    writeValue: (prefs, value) async {
      await prefs.setInt('wjplayer_accent_color', value.value);
    },
  );
});

/// App 全局自定义字体文件路径（空 = 用系统默认字体）。
/// 实际字体由 FontService 在启动时按此路径加载，key 与 FontService.appFontPathKey 一致。
final customAppFontPathProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '',
    readValue: (prefs) => prefs.getString('wjplayer_custom_app_font_path'),
    writeValue: (prefs, value) async {
      if (value.isEmpty) {
        await prefs.remove('wjplayer_custom_app_font_path');
      } else {
        await prefs.setString('wjplayer_custom_app_font_path', value);
      }
    },
  );
});

final localeProvider = StateNotifierProvider<PreferenceNotifier<Locale?>, Locale?>((ref) {
  return PreferenceNotifier<Locale?>(
    defaultValue: null,
    readValue: (prefs) => parseLocaleTag(prefs.getString('wjplayer_locale')),
    writeValue: (prefs, value) async {
      if (value == null) {
        await prefs.remove('wjplayer_locale');
      } else {
        await prefs.setString('wjplayer_locale', localeToPreferenceTag(value));
      }
    },
  );
});

final startupPageProvider =
    StateNotifierProvider<PreferenceNotifier<StartupPageOption>, StartupPageOption>((ref) {
  return PreferenceNotifier<StartupPageOption>(
    defaultValue: StartupPageOption.home,
    readValue: (prefs) => parseStartupPage(prefs.getString('wjplayer_startup_page')),
    writeValue: (prefs, value) async {
      await prefs.setString('wjplayer_startup_page', value.name);
    },
  );
});

final hideDailyRecommendationsProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('wjplayer_hide_daily_recommendations'),
    writeValue: (prefs, value) async {
      await prefs.setBool('wjplayer_hide_daily_recommendations', value);
    },
  );
});

final useVideoBackgroundProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('wjplayer_use_video_background'),
    writeValue: (prefs, value) async {
      await prefs.setBool('wjplayer_use_video_background', value);
    },
  );
});

/// TV 播放页「选集」底栏卡片是否用缩略图（true）还是纯集数卡（false）。默认缩略图。
final tvEpisodeCardThumbnailProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('wjplayer_tv_episode_card_thumbnail'),
    writeValue: (prefs, value) async {
      await prefs.setBool('wjplayer_tv_episode_card_thumbnail', value);
    },
  );
});

/// TV 播放页是否常驻底部进度条（控制栏隐藏时也显示一条加粗进度条）。默认关。
final tvPinnedProgressBarProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('wjplayer_tv_pinned_progress'),
    writeValue: (prefs, value) async {
      await prefs.setBool('wjplayer_tv_pinned_progress', value);
    },
  );
});

/// 自定义壁纸图片路径（空 = 不使用壁纸，走主题背景色）。
/// 仅支持静态图片；用户裁剪后的图写入 App 支持目录，这里只存路径。
final customWallpaperPathProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '',
    readValue: (prefs) => prefs.getString('wjplayer_custom_wallpaper_path'),
    writeValue: (prefs, value) async {
      if (value.isEmpty) {
        await prefs.remove('wjplayer_custom_wallpaper_path');
      } else {
        await prefs.setString('wjplayer_custom_wallpaper_path', value);
      }
    },
  );
});

final hiddenLibrariesProvider =
    StateNotifierProvider<HiddenLibrariesNotifier, Set<String>>((ref) {
  return HiddenLibrariesNotifier();
});

class HiddenLibrariesNotifier extends StateNotifier<Set<String>> {
  HiddenLibrariesNotifier() : super(_load());

  static const _prefKey = 'wjplayer_hidden_libraries';

  static Set<String> _load() {
    try {
      return AppPreferencesStore.instance.getStringList(_prefKey)?.toSet() ??
          <String>{};
    } catch (_) {
      return <String>{};
    }
  }

  void _persist() {
    try {
      AppPreferencesStore.instance.setStringList(_prefKey, state.toList());
    } catch (_) {
      // 持久化失败不影响内存中的屏蔽状态。
    }
  }

  void toggle(String libraryId) {
    if (state.contains(libraryId)) {
      state = Set.from(state)..remove(libraryId);
    } else {
      state = Set.from(state)..add(libraryId);
    }
    _persist();
  }

  void clear() {
    state = {};
    _persist();
  }
}
