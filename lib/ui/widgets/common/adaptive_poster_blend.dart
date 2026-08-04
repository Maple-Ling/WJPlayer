import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/utils/color_extractor.dart';
import 'media_widgets.dart';

/// 详情页通用海报融合头图：取色、柔和底色、底部渐隐和轻微景深统一处理。
class AdaptivePosterBlend extends StatefulWidget {
  const AdaptivePosterBlend({
    super.key,
    required this.imageUrl,
    this.httpHeaders,
    required this.child,
    this.onBackgroundChanged,
  });

  final String? imageUrl;
  final Map<String, String>? httpHeaders;
  final Widget child;
  final ValueChanged<Color>? onBackgroundChanged;

  @override
  State<AdaptivePosterBlend> createState() => _AdaptivePosterBlendState();
}

class _AdaptivePosterBlendState extends State<AdaptivePosterBlend> {
  Color? _background;

  @override
  void initState() {
    super.initState();
    _extract();
  }

  @override
  void didUpdateWidget(covariant AdaptivePosterBlend oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) _extract();
  }

  Future<void> _extract() async {
    final url = widget.imageUrl;
    if (url == null || url.isEmpty) return;
    final brightness = Theme.of(context).brightness;
    final colors = await ColorExtractor.extractFromUrl(
      url,
      brightness: brightness,
      headers: widget.httpHeaders,
    );
    if (!mounted) return;
    setState(() => _background = colors.background);
    widget.onBackgroundChanged?.call(colors.background);
  }

  @override
  Widget build(BuildContext context) {
    final fallback = Theme.of(context).scaffoldBackgroundColor;
    final background = _background ?? fallback;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      color: background,
      child: Stack(fit: StackFit.expand, children: [
        // 轻微放大后回落，避免头图像静态贴片；不改变内容布局。
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 1.025, end: 1.0),
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeOutCubic,
          builder: (context, scale, _) => Transform.scale(
            scale: scale,
            child: MediaImage(
              imageUrl: widget.imageUrl,
              httpHeaders: widget.httpHeaders,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            ),
          ),
        ),
        // 底部融合层覆盖到头图最底部，随 SliverAppBar 一起上移，
        // 不再出现独立浅蓝色遮罩或突兀分界线。
        Positioned(
          left: -24,
          right: -24,
          bottom: -36,
          height: 230,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: ColoredBox(color: background.withValues(alpha: 0.82)),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.42, 0.70, 0.91, 1.0],
              colors: [
                Colors.transparent,
                background.withValues(alpha: 0.18),
                background.withValues(alpha: 0.78),
                background,
              ],
            ),
          ),
        ),
        widget.child,
      ]),
    );
  }
}
