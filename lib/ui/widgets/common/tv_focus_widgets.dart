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
//   traversal: TraversalPolicies.grid(columns: 4, rowCount: 3),
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

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, KeyDownEvent;
import 'package:flutter/widgets.dart'
    show FocusNode, TraversalDirection, WidgetsBinding;

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
    this.onLongPressAt,
    this.onBoundary,
    this.child,
    super.key,
  });

  final String id;
  final int count;
  final TraversalFn traversal;

  /// 焦点索引变更回调
  final ValueChanged<int>? onFocusChanged;

  /// 长按 OK/Enter（按键重复事件）时以当前索引回调。
  final ValueChanged<int>? onLongPressAt;

  /// 遍历到达区域边界（traversal 返回 -1）时回调，用于区域间衔接。
  final ValueChanged<DPad>? onBoundary;

  final Widget? child;

  @override
  State<TvFocusArea> createState() => _TvFocusAreaState();
}

class _TvFocusAreaState extends State<TvFocusArea> {
  @override
  void initState() {
    super.initState();
    if (!isTvPlatform) return; // 手机端零副作用：不注册焦点区域。

    // 焦点区域：注册后仅创建 FocusNode 集合，焦点行为由 [TvFocusManager] 集中
    // 管理（焦点索引、方向键遍历、初始/恢复聚焦）。
    TvFocusManager.instance.registerArea(
      FocusAreaConfig(
        id: widget.id,
        count: widget.count,
        traversal: widget.traversal,
        onFocusChanged: widget.onFocusChanged,
        onLongPressAt: widget.onLongPressAt,
        onBoundary: widget.onBoundary,
      ),
    );
    _autoActivate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (isTvPlatform) _autoActivate();
  }

  /// 区域就绪后自动激活（首次进入页面即获得初始焦点）；其他区域正在使用
  /// （其节点持有系统焦点）或本页被上层页面覆盖时不抢占。
  void _autoActivate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !isTvPlatform) return;
      final manager = TvFocusManager.instance;
      if (manager.activeArea?.config.id == widget.id) return;
      if (manager.hasManagedFocus) {
        final active = manager.activeArea;
        if (active != null && active.nodes[active.focusIndex].hasFocus) {
          return; // 底部栏等其他区域正在使用，不抢占。
        }
      }
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return; // 被上层页面覆盖。
      manager.switchArea(widget.id);
    });
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
    if (isTvPlatform) TvFocusManager.instance.unregisterArea(widget.id);
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

/// TV 两段式输入框包装：聚焦（区域节点）时**仅显示高亮描边**，绝不直接进入
/// 键盘输入；用户按 OK 键后才激活内部编辑器（聚焦 TextField 并打开 IME）。
/// 手机端直接渲染编辑器（零副作用）。
class TvInputField extends StatefulWidget {
  const TvInputField({
    super.key,
    required this.focusNode,
    required this.buildEditor,
    this.borderRadius = 14,
  });

  /// 区域焦点节点（聚焦态：仅高亮，不进入输入）。
  final FocusNode focusNode;

  /// 构建内部编辑器（接收内部编辑节点，交给 TextField 的 focusNode）。
  final Widget Function(BuildContext context, FocusNode editorNode)
      buildEditor;

  final double borderRadius;

  @override
  State<TvInputField> createState() => _TvInputFieldState();
}

class _TvInputFieldState extends State<TvInputField> {
  final FocusNode _editorNode = FocusNode();
  bool _focused = false;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    if (isTvPlatform) {
      widget.focusNode.addListener(_onOuterChange);
      _editorNode.addListener(_onEditorChange);
    }
  }

  @override
  void didUpdateWidget(TvInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (isTvPlatform && oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onOuterChange);
      widget.focusNode.addListener(_onOuterChange);
    }
  }

  @override
  void dispose() {
    if (isTvPlatform) {
      widget.focusNode.removeListener(_onOuterChange);
      _editorNode.removeListener(_onEditorChange);
    }
    _editorNode.dispose();
    super.dispose();
  }

  void _onOuterChange() {
    if (!mounted) return;
    final has = widget.focusNode.hasFocus;
    if (has != _focused) setState(() => _focused = has);
    if (has) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.focusNode.hasFocus) return;
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  void _onEditorChange() {
    if (!mounted) return;
    final editing = _editorNode.hasFocus;
    if (editing != _editing) setState(() => _editing = editing);
  }

  /// OK 键：从"聚焦高亮"进入"编辑"（打开键盘）。
  void _activate() {
    if (!isTvPlatform || _editing) return;
    _editorNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    if (!isTvPlatform) {
      return widget.buildEditor(context, _editorNode);
    }
    final scheme = Theme.of(context).colorScheme;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
      },
      child: Container(
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          // 聚焦（非编辑）：主题色描边；编辑态交给 TextField 自身 focusedBorder。
          border: Border.all(
            color: _focused && !_editing
                ? scheme.primary
                : Colors.transparent,
            width: 3,
          ),
        ),
        child: widget.buildEditor(context, _editorNode),
      ),
    );
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
      child: Padding(
        padding: const EdgeInsets.all(4),
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

        // 长按 OK/Enter（按键重复事件）：通知当前焦点区域处理
        // （如历史页长按 OK 进入多选删除）。
        if (event.repeat &&
            (key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.select)) {
          final manager = TvFocusManager.instance;
          final area = manager.activeArea;
          if (area != null && area.config.onLongPressAt != null) {
            area.config.onLongPressAt!(area.focusIndex);
            return KeyEventResult.handled;
          }
        }

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
          final scope = FocusScope.of(context);
          switch (dir) {
            case DPad.up:
              if (scope.focusInDirection(TraversalDirection.up))
                return KeyEventResult.handled;
              break;
            case DPad.down:
              if (scope.focusInDirection(TraversalDirection.down))
                return KeyEventResult.handled;
              break;
            case DPad.left:
              if (scope.focusInDirection(TraversalDirection.left))
                return KeyEventResult.handled;
              break;
            case DPad.right:
              if (scope.focusInDirection(TraversalDirection.right))
                return KeyEventResult.handled;
              break;
          }
          return KeyEventResult.ignored;
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