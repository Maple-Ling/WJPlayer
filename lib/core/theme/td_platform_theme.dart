import 'package:tdesign_flutter/tdesign_flutter.dart';

/// 三端各自的尺寸档：用同一套 TDesign 组件，但每端喂每端的尺寸。
/// 移动=基准(TDesign 本就移动优先)、PC=信息密度高略收、TV=10 尺远距放大。
enum AppFormFactor { mobile, desktop, tv }

extension AppFormFactorScale on AppFormFactor {
  double get scale => switch (this) {
        AppFormFactor.mobile => 1.0,
        AppFormFactor.desktop => 0.92,
        AppFormFactor.tv => 1.6,
      };
}

/// 按端缩放 TDesign 的关键尺寸 token（字体/圆角/间距），其余 token 继承默认。
/// TD 组件(TDCell/TDButton/TDSwitch 等)从 `TDTheme.of(context)` 读这些 token 取尺寸，
/// 故只覆盖这几个关键 token，同一套组件即按端呈现不同尺寸。
/// 合并语义见库内 `_copyMap`：未覆盖的 key 走默认主题。
TDThemeData tdThemeFor(AppFormFactor ff, {bool dark = false}) {
  final base = dark
      ? (TDThemeData.defaultData().dark ?? TDThemeData.defaultData())
      : TDThemeData.defaultData();
  final s = ff.scale;
  if (s == 1.0) return base;

  Font? scaled(Font? src) => src == null
      ? null
      : Font(
          size: (src.size * s).round(),
          lineHeight: (src.height * s).round(),
          fontWeight: src.fontWeight,
        );

  final fonts = <String, Font>{};
  for (final key in const [
    'fontBodySmall',
    'fontBodyMedium',
    'fontBodyLarge',
    'fontBodyExtraLarge',
    'fontTitleSmall',
    'fontTitleMedium',
    'fontTitleLarge',
    'fontTitleExtraLarge',
  ]) {
    final f = scaled(base.fontMap[key]);
    if (f != null) fonts[key] = f;
  }

  // TDesign 圆角/间距 token 的基准值（spec：radiusSmall/Default/Large/ExtraLarge=3/6/9/12）。
  final radius = <String, double>{
    'radiusSmall': 3 * s,
    'radiusDefault': 6 * s,
    'radiusLarge': 9 * s,
    'radiusExtraLarge': 12 * s,
  };
  final spacer = <String, double>{
    for (final v in const [4, 8, 12, 16, 24, 32, 40, 48]) 'spacer$v': v * s,
  };

  return base.copyWith(
    name: base.name,
    fontMap: fonts,
    radiusMap: radius,
    marginMap: spacer,
  ) as TDThemeData;
}
