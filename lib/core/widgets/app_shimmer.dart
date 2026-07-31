import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';
import '../theme/app_motion.dart';

/// 共享加载态组件（三端复用）。

/// 骨架块：纯色圆角容器 + 持续 shimmer 扫光。
///
/// 替代“静态灰块”骨架，让加载等待不再是死板的占位，而是有呼吸感的微动效。
/// shimmer 只扫一层渐变高光，开销低；颜色取自主题，自动适配深/浅色。
class ShimmerBox extends StatelessWidget {
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? margin;

  const ShimmerBox({
    super.key,
    this.width,
    this.height,
    this.borderRadius,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surfaceContainerHighest;
    final highlight = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: 0.06),
      base,
    );

    return Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        color: base,
        borderRadius: borderRadius ?? BorderRadius.circular(12),
      ),
    ).animate(onPlay: (c) => c.repeat()).shimmer(
          duration: const Duration(milliseconds: 1200),
          color: highlight,
        );
  }
}

/// 统一加载指示器：淡入的 TDesign 环形 loading（[TDCircleIndicator]）。
///
/// 直接替换裸 `CircularProgressIndicator`，避免 spinner“突然出现”，
/// 并统一为 TDesign 观感。任意 px 尺寸（TV 大屏也够大）；配色默认取主题主色
/// （不强推 TD 蓝，与 App 一致）。
class AppLoadingIndicator extends StatelessWidget {
  final double size;
  final double strokeWidth;
  final Color? color;

  const AppLoadingIndicator({
    super.key,
    this.size = 28,
    this.strokeWidth = 2.6,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TDCircleIndicator(
        size: size,
        lineWidth: strokeWidth,
        color: color ?? Theme.of(context).colorScheme.primary,
      ),
    ).appFadeIn(duration: AppMotion.fast);
  }
}
