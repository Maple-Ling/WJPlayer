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

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LogicalKeyboardKey, KeyDownEvent, KeyRepeatEvent, KeyUpEvent;
import 'package:flutter/widgets.dart'
    show FocusNode, TraversalDirection, WidgetsBinding;

import '../../../core/services/tv_focus_manager.dart';
import '../../../core/services/tv_key_channel.dart';
import '../../../core/utils/platform_utils.dart';
import 'media_widgets.dart';
import 'tv_focusable.dart';

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
        // 状态栏（覆盖层）活跃中：无论其节点是否已聚焦都不抢占——状态栏
        // 展开有渲染时序（collapsed 只渲染搜索按钮，其余节点短暂未挂载），
        // 后台此时抢焦点会导致"状态栏打开后方向键控制后台页面"。
        if (active?.config.id == 'main_tabs') return;
        // 其它区域：仅在其节点真正持有系统焦点（正在使用）时不抢占；
        // 无焦点（被 push 覆盖/聚焦失败）时本区域可接管。
        if (active != null && active.nodes[active.focusIndex].hasFocus) {
          return;
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
    // 手机端不注册焦点区域（initState 已跳过），重建逻辑必须同样跳过，
    // 否则会在手机端误注册/泄漏区域并触发重复注册 assert。
    if (!isTvPlatform) return;
    if (oldWidget.id == widget.id && oldWidget.count == widget.count) return;
    // count 变化（数据刷新/筛选变化）时安全重建区域：旧节点释放、按新
    // count 重新注册并恢复激活。此前仅 assert 会导致区域节点数与新布局
    // 不一致 → indexOf 越界/错位 → 方向键乱跳（首页分区刷新/详情页季切换）。
    final manager = TvFocusManager.instance;
    manager.unregisterArea(oldWidget.id);
    manager.registerArea(
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

  /// 区域焦点节点（聚焦态：仅高亮，不进入输入）。TV 端必须非空。
  final FocusNode? focusNode;

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
      widget.focusNode?.addListener(_onOuterChange);
      _editorNode.addListener(_onEditorChange);
    }
  }

  @override
  void didUpdateWidget(TvInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (isTvPlatform && oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_onOuterChange);
      widget.focusNode?.addListener(_onOuterChange);
    }
  }

  @override
  void dispose() {
    if (isTvPlatform) {
      widget.focusNode?.removeListener(_onOuterChange);
      _editorNode.removeListener(_onEditorChange);
    }
    _editorNode.dispose();
    super.dispose();
  }

  void _onOuterChange() {
    if (!mounted) return;
    final has = widget.focusNode?.hasFocus ?? false;
    if (has != _focused) setState(() => _focused = has);
    if (has) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !(widget.focusNode?.hasFocus ?? false)) return;
        ensureVisibleSmartly(context);
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

// ─── 通用 TV 可聚焦列表项 ───

/// TV 可聚焦 ListTile：遥控方向键遍历 + OK 激活（描边高亮），手机端原样
/// ListTile（零副作用）。用于设置子页/弹层等纯 ListTile 列表的 TV 化——
/// Flutter 在 Android TV 上默认把触摸组件（ListTile/InkWell）设为不可请求
/// 焦点，导致遥控遍历跳过全部列表项。
class TvListTile extends StatelessWidget {
  const TvListTile({
    super.key,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.dense = false,
    this.selected = false,
    this.contentPadding,
    this.borderRadius = 10,
    this.autofocus = false,
  });

  final Widget? leading;
  final Widget? title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  final bool dense;
  final bool selected;
  final EdgeInsetsGeometry? contentPadding;
  final double borderRadius;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final tile = ListTile(
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      onTap: onTap,
      enabled: enabled,
      dense: dense,
      selected: selected,
      contentPadding: contentPadding,
      // TV 上不显示按压水波纹（由描边指示），手机端保留。
      splashColor: isTvPlatform ? Colors.transparent : null,
    );
    if (!isTvPlatform || onTap == null) return tile;
    return TvFocusable(
      onActivate: onTap,
      borderRadius: borderRadius,
      autofocus: autofocus,
      // 处于 TvListArea 子树内时自动分配区域节点（确定性遍历）；
      // 否则自建节点（弹层内走默认遍历）。
      focusNode: TvListArea.takeNode(context),
      child: tile,
    );
  }
}

// ─── 线性可聚焦列表容器 ───

/// 为子树内按出现顺序的 [TvListTile]/[TvListArea.takeNode] 自动分配区域
/// 节点（免手动编号），提供线性遍历 + 顶部边界回调。
/// 仅 TV 生效；手机端零副作用。count 由子级 build 自动统计并重建。
class TvListArea extends StatefulWidget {
  const TvListArea({
    super.key,
    required this.id,
    required this.child,
    this.onBoundary,
  });

  /// 区域 id（同一页面唯一）。
  final String id;

  final Widget child;

  /// 遍历到达顶部边界（traversal 返回 -1）时回调（底部自然停留）。
  final ValueChanged<DPad>? onBoundary;

  /// 子级取下一个焦点节点（无 TvListArea 环境返回 null → 组件自建节点）。
  static FocusNode? takeNode(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<_TvListAreaScope>();
    if (scope == null) return null;
    final idx = scope.counter.take();
    final area = TvFocusManager.instance.getArea(scope.areaId);
    if (area == null || idx >= area.nodes.length) return null;
    return area.nodes[idx];
  }

  @override
  State<TvListArea> createState() => _TvListAreaState();
}

class _TvListAreaCounter {
  int next = 0;
  int maxUsed = -1;
}

class _TvListAreaScope extends InheritedWidget {
  const _TvListAreaScope({
    required this.areaId,
    required this.counter,
    required super.child,
  });

  final String areaId;
  final _TvListAreaCounter counter;

  @override
  bool updateShouldNotify(_TvListAreaScope oldWidget) => false;
}

class _TvListAreaState extends State<TvListArea> {
  final _TvListAreaCounter _counter = _TvListAreaCounter();
  late int _count = 1;

  @override
  Widget build(BuildContext context) {
    if (!isTvPlatform) return widget.child;
    _counter.next = 0;
    _counter.maxUsed = -1;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !isTvPlatform) return;
      final needed = _counter.maxUsed + 1;
      if (needed != _count) setState(() => _count = needed);
    });
    return _TvListAreaScope(
      areaId: widget.id,
      counter: _counter,
      child: TvFocusArea(
        id: widget.id,
        count: _count,
        traversal: TraversalPolicies.linear(_count),
        onBoundary: widget.onBoundary,
        child: widget.child,
      ),
    );
  }
}

// ─── 根节点键盘监听 ───

/// TV 全屏剧照浏览：左右键翻页、OK/Enter/返回关闭。
/// 手机端不使用（详情页保留 PageView 滑动/双指缩放）。
class TvImageGallery extends StatefulWidget {
  const TvImageGallery({super.key, required this.images, required this.initial});
  final List<String> images;
  final int initial;

  @override
  State<TvImageGallery> createState() => _TvImageGalleryState();
}

class _TvImageGalleryState extends State<TvImageGallery> {
  late int _index = widget.initial;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent || event is KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowRight &&
            _index < widget.images.length - 1) {
          setState(() => _index++);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft && _index > 0) {
          setState(() => _index--);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.select) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: MediaImage(
                  imageUrl: widget.images[_index], fit: BoxFit.contain),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Text(
                    '${_index + 1}/${widget.images.length}',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 30),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
/// 包裹在 MaterialApp 的外层，作为 Flutter 侧按键事件的唯一入口。
/// 处理方向键 → TvFocusManager.moveDPad，以及全局按键处理器。
///
/// 注意：此 Widget 处理的是 Flutter 自身的 KeyEvent 通道（TextField 输入等），
/// 原生层（MainActivity.kt）转发的按键由 tv_key_channel.dart 的 installNativeKeyBridge 处理。
/// 两条路径最终都汇聚到 TvFocusManager，不冲突。
class TvKeyboardListener extends StatefulWidget {
  const TvKeyboardListener({required this.child, super.key});
  final Widget child;

  @override
  State<TvKeyboardListener> createState() => _TvKeyboardListenerState();
}

class _TvKeyboardListenerState extends State<TvKeyboardListener> {
  // 长按 OK/Enter 判定：按下启动 500ms 计时，触发即回调 onLongPressAt；
  // 松开（KeyUp）取消。不依赖 KeyRepeatEvent（低端遥控重复间隔不一，
  // 可能无法触发或间隔抖动），按下计时跨设备可靠。
  final Map<int, Timer> _longPressTimers = <int, Timer>{};

  @override
  void dispose() {
    for (final timer in _longPressTimers.values) {
      timer.cancel();
    }
    _longPressTimers.clear();
    super.dispose();
  }

  /// OK/Enter 按下：启动长按计时（区域配置了 onLongPressAt 时）。
  void _armLongPress(LogicalKeyboardKey key) {
    final manager = TvFocusManager.instance;
    final area = manager.activeArea;
    if (area == null || area.config.onLongPressAt == null) return;
    _longPressTimers[key.keyId]?.cancel();
    _longPressTimers[key.keyId] = Timer(const Duration(milliseconds: 500), () {
      _longPressTimers.remove(key.keyId);
      final current = TvFocusManager.instance.activeArea;
      if (current != null && current.config.onLongPressAt != null) {
        current.config.onLongPressAt!(current.focusIndex);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!isTvPlatform) return widget.child;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        final key = event.logicalKey;

        // 长按 OK/Enter：按下计时 500ms（不依赖 KeyRepeatEvent），
        // 触发当前焦点区域的 onLongPressAt（如历史页多选/服务器页排序）。
        if (event is KeyDownEvent &&
            event is! KeyRepeatEvent &&
            (key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.select)) {
          _armLongPress(key);
        }
        if (event is KeyUpEvent &&
            (key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.select)) {
          _longPressTimers.remove(key.keyId)?.cancel();
        }

        // KeyUp 也分发给全局处理器（TV 长按松开恢复倍速等场景需要）；
        // 现有处理器（菜单键等）对 isUp 一律忽略，无副作用。
        if (event is KeyUpEvent) {
          if (dispatchGlobalTvKey(
                event.logicalKey,
                KeyEventSource.flutter,
                isUp: true,
              ) ==
              KeyEventResult.handled) {
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        if (dispatchGlobalTvKey(
              key,
              KeyEventSource.flutter,
              isRepeat: event is KeyRepeatEvent,
            ) ==
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
      child: widget.child,
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