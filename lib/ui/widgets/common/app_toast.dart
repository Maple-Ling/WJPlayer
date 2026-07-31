import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// 提示类型，决定气泡的强调色与图标。
enum AppToastKind { info, success, error }

/// 气泡出现的位置。
/// - [lowerCenter] 屏幕中部偏下：非播放页统一用这里（默认）。
/// - [topCenter] 顶部居中：播放页专用（避免遮挡底部进度条/控件）。
enum AppToastPosition { topCenter, lowerCenter }

/// 全局气泡提示（Overlay 实现，三端通用：移动 / 桌面）。
///
/// 取代默认「底部大黑框」SnackBar：圆角毛玻璃气泡，滑入淡入 + 自动淡出，
/// 自带强调色图标。单实例——新提示出现时立即顶掉旧的。位置由 [AppToastPosition]
/// 决定：非播放页中部偏下，播放页顶部居中。
class AppToast {
  AppToast._();

  static OverlayEntry? _entry;

  /// 弹出一个气泡提示。[context] 需位于某个 [Overlay] 之下（三端根部都有）。
  static void show(
    BuildContext context,
    String message, {
    AppToastKind kind = AppToastKind.info,
    AppToastPosition position = AppToastPosition.lowerCenter,
    Duration duration = const Duration(seconds: 3),
  }) {
    if (message.trim().isEmpty) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _AppToastBubble(
        message: message,
        kind: kind,
        position: position,
        duration: duration,
        onClosed: () {
          if (identical(_entry, entry)) _entry = null;
          entry.remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  /// 便捷入口。
  static void success(BuildContext context, String message) =>
      show(context, message, kind: AppToastKind.success);

  static void error(BuildContext context, String message) =>
      show(context, message, kind: AppToastKind.error);

  static void _remove() {
    _entry?.remove();
    _entry = null;
  }
}

class _AppToastBubble extends StatefulWidget {
  const _AppToastBubble({
    required this.message,
    required this.kind,
    required this.position,
    required this.duration,
    required this.onClosed,
  });

  final String message;
  final AppToastKind kind;
  final AppToastPosition position;
  final Duration duration;
  final VoidCallback onClosed;

  @override
  State<_AppToastBubble> createState() => _AppToastBubbleState();
}

class _AppToastBubbleState extends State<_AppToastBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  Timer? _hold;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
    // 顶部气泡从上方滑入，中下部气泡从下方滑入。
    final beginDy =
        widget.position == AppToastPosition.topCenter ? -0.35 : 0.35;
    _slide = Tween<Offset>(
      begin: Offset(0, beginDy),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
    _c.forward();
    _hold = Timer(widget.duration, _close);
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _hold?.cancel();
    if (mounted) {
      await _c.reverse();
    }
    widget.onClosed();
  }

  @override
  void dispose() {
    _hold?.cancel();
    _c.dispose();
    super.dispose();
  }

  ({Color accent, IconData icon}) get _style {
    switch (widget.kind) {
      case AppToastKind.success:
        return (accent: AppColors.success, icon: Icons.check_circle_rounded);
      case AppToastKind.error:
        return (accent: AppColors.error, icon: Icons.error_rounded);
      case AppToastKind.info:
        return (accent: AppColors.brand, icon: Icons.info_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final s = _style;
    final bg = (isDark ? const Color(0xFF2A2A2E) : Colors.white)
        .withValues(alpha: 0.94);
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final isTop = widget.position == AppToastPosition.topCenter;

    return Positioned.fill(
      child: SafeArea(
        child: Align(
          alignment: isTop ? Alignment.topCenter : const Alignment(0, 0.55),
          child: Padding(
            padding: EdgeInsets.only(top: isTop ? 16 : 0),
            child: FadeTransition(
            opacity: _fade,
            child: SlideTransition(
              position: _slide,
              child: Material(
                type: MaterialType.transparency,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: GestureDetector(
                    onTap: _close,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: bg,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: s.accent.withValues(alpha: 0.35),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.18),
                                blurRadius: 20,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(s.icon, color: s.accent, size: 20),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  widget.message,
                                  style: TextStyle(
                                    color: textColor,
                                    fontSize: 14,
                                    height: 1.3,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }
}
