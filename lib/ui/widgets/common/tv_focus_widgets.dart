// lib/ui/widgets/common/tv_focus_widgets.dart
//
// TV 焦点 UI 组件：替换旧的 tv_focusable.dart。
//
// 核心组件：
//   · TvFocusArea — 声明一个焦点区域，自动注册/注销到 TvFocusManager
//   · TvFocusCard — 从 TvFocusArea 获取 FocusNode + 描边动画
//   · TvFocusNodeX — 便捷扩展，从 context 直接获取 FocusNode
//
// 用法：
// ```dart
// TvFocusArea(
//   id: 'home_posters',
//   count: 12,
//   traversal: TraversalPolicies.grid(columns: 4, itemCount: 12),
//   child: GridView.builder(
//     itemCount: 12,
//     itemBuilder: (ctx, i) => TvFocusCard(
//       areaId: 'home_posters',
//       index: i,
//       onActivate: () => print('激活海报 $i'),
//       child: MyCard(),
//     ),
//   ),
// )
// ```

import 'package:flutter/material.dart';

import '../../../core/services/tv_focus_manager.dart';
import '../../../core/services/tv_key_channel.dart';
import '../../../core/utils/platform_utils.dart';

// ─── 焦点区域容器 ───

/// 声明一个焦点区域。自动注册区域 → 创建 FocusNode → 初始聚焦。
/// dispose 时自动注销区域 → 释放所有 FocusNode。
class TvFocusArea extends StatefulWidget {
  const TvFocusArea({
    required this.id,
    required this.count,
    required this.traversal,
    this.onFocusChanged,
    this.child,
    super.key,
  });

  final String id;
  final int count;
  final TraversalFn traversal;

  /// 焦点索引变更回调
  final ValueChanged<int>? onFocusChanged;

  final Widget? child;

  @override
  State<TvFocusArea> createState() => _TvFocusAreaState();
}

class _TvFocusAreaState extends State<TvFocusArea> {
  @override
  void initState() {
    super.initState();

    // 焦点区域：注册后仅创建 FocusNode 集合，焦点行为由 [TvFocusManager] 集中
    // 管理（焦点索引、方向键遍历、初始/恢复聚焦）。
    TvFocusManager.instance.registerArea(
      FocusAreaConfig(
        id: widget.id,
        count: widget.count,
        traversal: widget.traversal,
        onFocusChanged: widget.onFocusChanged,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant TvFocusArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      oldWidget.id == widget.id && oldWidget.count == widget.count,
      'TvFocusArea 的 id/count 变化时必须更换 Key，以便安全重建 FocusNode。',
    );
  }

  @override
  void dispose() {
    TvFocusManager.instance.unregisterArea(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child ?? const SizedBox.shrink();
  }
}

// ─── 便捷扩展 ───

/// 在 TvFocusArea 子树中获取 FocusNode
extension TvFocusNodeX on BuildContext {
  /// 获取指定区域的第 index 个 FocusNode
  FocusNode getFocusNode(String areaId, int index) {
    final area = TvFocusManager.instance.getArea(areaId);
    if (area == null) {
      throw StateError('TvFocusArea "$areaId" 未注册');
    }
    if (index < 0 || index >= area.nodes.length) {
      throw RangeError.range(index, 0, area.nodes.length - 1, 'index');
    }
    return area.nodes[index];
  }

  /// 获取指定区域的当前焦点索引
  int? currentFocusIndex(String areaId) {
    return TvFocusManager.instance.getArea(areaId)?.focusIndex;
  }
}

// ─── 简化可聚焦卡片 ───

/// 自动从 TvFocusArea 获取 FocusNode + 描边动画。
/// 替代旧的 TvFocusable。
///
/// 需在 TvFocusArea 子树内使用。
class TvFocusCard extends StatefulWidget {
  const TvFocusCard({
    required this.areaId,
    required this.index,
    required this.onActivate,
    required this.child,
    this.borderRadius = 12,
    this.focusScale = 1.04,
    this.enabled = true,
    this.onFocusChanged,
    super.key,
  });

  final String areaId;
  final int index;
  final VoidCallback onActivate;
  final Widget child;
  final double borderRadius;
  final double focusScale;
  final bool enabled;
  final ValueChanged<bool>? onFocusChanged;

  @override
  State<TvFocusCard> createState() => _TvFocusCardState();
}

class _TvFocusCardState extends State<TvFocusCard> {
  FocusNode? _node;
  bool _focused = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachNodeIfNeeded();
  }

  @override
  void didUpdateWidget(TvFocusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.areaId != widget.areaId || oldWidget.index != widget.index) {
      _detachNode();
      _attachNodeIfNeeded();
    }
  }

  void _attachNodeIfNeeded() {
    if (_node != null) return;
    final area = TvFocusManager.instance.getArea(widget.areaId);
    if (area == null || widget.index < 0 || widget.index >= area.nodes.length) {
      return;
    }
    _node = area.nodes[widget.index];
    _node!.addListener(_onFocusChange);
    _focused = _node!.hasFocus;
  }

  void _detachNode() {
    _node?.removeListener(_onFocusChange);
    _node = null;
  }

  void _onFocusChange() {
    if (!mounted) return;
    final hasFocus = _node?.hasFocus ?? false;
    if (hasFocus != _focused) {
      setState(() => _focused = hasFocus);
      widget.onFocusChanged?.call(hasFocus);
    }
  }

  @override
  void dispose() {
    _detachNode();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_node == null) return widget.child;

    final isFocused = _focused && widget.enabled;
    final scheme = Theme.of(context).colorScheme;

    return FocusableActionDetector(
      focusNode: _node,
      autofocus: false,
      enabled: widget.enabled,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (widget.enabled) widget.onActivate();
            return null;
          },
        ),
      },
      child: AnimatedScale(
        scale: isFocused ? widget.focusScale : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: Container(
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
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
    );
  }
}

// ─── 根节点键盘监听 ───

/// 包裹在 MaterialApp 的外层，作为 Flutter 侧按键事件的唯一入口。
/// 处理方向键 → TvFocusManager.moveDPad，以及全局按键处理器。
///
/// 注意：此 Widget 处理的是 Flutter 自身的 KeyEvent 通道（TextField 输入等），
/// 原生层（MainActivity.kt）转发的按键由 tv_key_channel.dart 的 installNativeKeyBridge 处理。
/// 两条路径最终都汇聚到 TvFocusManager，不冲突。
class TvKeyboardListener extends StatelessWidget {
  const TvKeyboardListener({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isTvPlatform) return child;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;

        if (dispatchGlobalTvKey(key, KeyEventSource.flutter) ==
            KeyEventResult.handled) {
          return KeyEventResult.handled;
        }

        final dir = _dpadKey(key);
        if (dir != null) {
          if (TvFocusManager.instance.canHandleDPad) {
            TvFocusManager.instance.moveDPad(dir);
            return KeyEventResult.handled;
          }
          // 自定义焦点树尚未就绪时，回退到 Flutter 默认焦点遍历。
          final target = Focus.of(primaryFocus ?? node);
          switch (dir) {
            case DPad.up:    return target.previousFocus();
            case DPad.down:  return target.nextFocus();
            case DPad.left:  return target.leftFocus();
            case DPad.right: return target.rightFocus();
          }
        }

        return KeyEventResult.ignored;
      },
      child: child,
    );
  }

  DPad? _dpadKey(LogicalKeyboardKey key) {
    switch (key) {
      case LogicalKeyboardKey.arrowUp:    return DPad.up;
      case LogicalKeyboardKey.arrowDown:  return DPad.down;
      case LogicalKeyboardKey.arrowLeft:  return DPad.left;
      case LogicalKeyboardKey.arrowRight: return DPad.right;
      default:                            return null;
    }
  }
}