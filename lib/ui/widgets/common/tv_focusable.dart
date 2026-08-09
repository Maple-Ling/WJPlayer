import 'package:flutter/material.dart';

import '../../../core/utils/platform_utils.dart';

/// TV 遥控器可聚焦卡片包装。
///
/// 背景：Flutter 在 Android 上默认把触摸组件（InkWell/GestureDetector）的
/// 焦点设为不可请求（触摸优化），导致 TV 遥控方向键遍历时跳过所有卡片。
/// 本组件在 [isTvPlatform] 时给卡片挂上可请求的 FocusNode + ActivateIntent，
/// 让方向键能移动焦点（Flutter 的 requestFocus 会自动滚动到可见区域），
/// 确认键（Enter/Select/OK）触发 [onActivate]。
///
/// 选中标识：聚焦时显示主题色描边 + 轻微放大 + 阴影，手机端零变化。
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.onActivate,
    required this.child,
    this.borderRadius = 12,
    this.focusScale = 1.04,
    this.enabled = true,
    this.onFocusChanged,
    this.autofocus = false,
    this.focusNode,
  });

  /// 聚焦后确认（遥控 OK/Enter/Select）触发。
  final VoidCallback onActivate;

  final Widget child;

  /// 描边圆角（与卡片圆角一致）。
  final double borderRadius;

  /// 聚焦时放大倍数。
  final double focusScale;

  /// 是否参与焦点遍历（如已选中态可关闭）。
  final bool enabled;

  /// 初始自动聚焦。默认 false，由 TvFocusManager 或父级 FocusScope 统一分配焦点，
  /// 避免多张卡片同时 autofocus=true 抢占焦点、导致 TV 焦点漂移。
  final bool autofocus;

  final ValueChanged<bool>? onFocusChanged;

  /// 外部注入的焦点节点（由 TvFocusArea/TvFocusManager 统一管理）。
  /// 传入后本组件不再自建节点；节点生命周期归调用方，本组件不 dispose。
  final FocusNode? focusNode;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  FocusNode? _externalNode;
  late final FocusNode _internalNode = FocusNode();
  bool _focused = false;

  FocusNode get _node => _externalNode ?? _internalNode;

  @override
  void initState() {
    super.initState();
    if (isTvPlatform) {
      _externalNode = widget.focusNode;
      _node.addListener(_onFocusChange);
    }
  }

  @override
  void didUpdateWidget(TvFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!isTvPlatform || oldWidget.focusNode == widget.focusNode) return;
    _node.removeListener(_onFocusChange);
    _externalNode = widget.focusNode;
    _node.addListener(_onFocusChange);
    final hasFocus = _node.hasFocus;
    if (hasFocus != _focused) {
      _focused = hasFocus;
      widget.onFocusChanged?.call(hasFocus);
    }
  }

  void _onFocusChange() {
    if (!mounted) return;
    final hasFocus = _node.hasFocus;
    if (hasFocus != _focused) {
      setState(() => _focused = hasFocus);
      widget.onFocusChanged?.call(hasFocus);
    }
    if (hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_node.hasFocus) return;
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  void dispose() {
    if (isTvPlatform) {
      _node.removeListener(_onFocusChange);
    }
    // 外部节点归 TvFocusManager 管理，不在此 dispose。
    _internalNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 非 TV：原样返回，零副作用。
    if (!isTvPlatform) {
      return widget.child;
    }

    final scheme = Theme.of(context).colorScheme;
    final isFocused = _focused && widget.enabled;

    return FocusableActionDetector(
      focusNode: _focusNode,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (widget.enabled) widget.onActivate();
            // Flutter 3.44：Action.invoke 返回 Object?，ActionState 已移除。
            return null;
          },
        ),
      },
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: AnimatedScale(
          scale: isFocused ? widget.focusScale : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          child: Container(
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              // 聚焦：主题色描边 + 柔光阴影（foregroundDecoration 不挤压内容布局）。
              border: isFocused
                  ? Border.all(color: scheme.primary, width: 3)
                  : Border.all(color: Colors.transparent, width: 3),
              boxShadow: isFocused
                  ? [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.45),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
