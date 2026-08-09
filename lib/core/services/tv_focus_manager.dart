// lib/core/services/tv_focus_manager.dart
// TV 焦点管理器：集中管理所有 TV 页面的焦点区域、遍历策略与初始/恢复聚焦。
//
// 职责边界（TV）：
//   - D-pad / Enter / 返回：Flutter 原生 KeyEvent 到达，经 TvKeyboardListener
//     分发到本类的 moveDPad 或回退到 Flutter 默认焦点遍历
//   - MENU / 系统菜单键：MainActivity 经 tv_key MethodChannel → TvKeyChannel
//     → dispatchGlobalTvKey → 全局处理器 / 恢复 main_tabs 焦点
//
// 手机版：installNativeKeyBridge 不安装，本类保持存在但 TvKeyboardListener
// 在 isTvPlatform=false 时不注册，零焦点副作用。

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' show FocusNode, WidgetsBinding;

import '../../ui/widgets/common/tv_focusable.dart' show ensureVisibleSmartly;

enum DPad { up, down, left, right }

/// 遍历函数：返回目标索引（-1 = 离开本区域）。
/// [nodes] 为区域全部焦点节点，供按屏幕视觉位置导航（上下排对齐）使用；
/// 线性/网格策略忽略该参数。
typedef TraversalFn =
    int Function(int current, DPad direction, List<FocusNode> nodes);

/// 全局路由观察器：TV 页面在 push/pop 时接管/交还焦点区域
/// （挂在 GoRouter.observers 上，供 RouteAware 页面订阅）。
final appRouteObserver = RouteObserver<ModalRoute<void>>();

/// 详情页等长页面的焦点分区。
class FocusSection {
  final String id;
  final int count;

  /// 行尾是否存在「查看更多」入口（作为该行最后一个焦点目标，索引 = count）。
  final bool trailing;

  const FocusSection(this.id, this.count, {this.trailing = false})
      : assert(count > 0);

  /// 该行全部焦点元素数（卡片 + 可选的「查看更多」）。
  int get elementCount => count + (trailing ? 1 : 0);
}

/// 将多个横向分区压平为一个焦点区域，并保持上下分区、左右项目导航。
///
/// 方向键语义（TV 确定性导航）：
///   - 左/右：在当前行内逐卡片移动（一次一个）；行首左停留；
///     行尾最后一个卡片右移到「查看更多」（trailing 行），查看更多右停留。
///   - 下/上：进入相邻分区，**按屏幕视觉位置对齐**——在目标行内找「屏幕
///     x 中心与当前焦点最接近」的卡片（不继承上一排的数据编号）。横排已
///     横向滚动时仍按屏幕位置锚定（当前屏幕最左侧 = 该排第一个位置）；
///     目标行较短、无对应列时自然落到该行最后一个存在的卡片。
///   - 「查看更多」**不参与普通上下导航**：上下切换时不会被选为目标；
///     仅当前焦点在本行**最右侧（行尾）卡片**时按上键进入本行查看更多；
///     焦点在查看更多时按上/下键退出到本行行尾卡片。
class FocusSectionLayout {
  final List<FocusSection> sections;
  late final List<int> _offsets = _buildOffsets();

  FocusSectionLayout(Iterable<FocusSection> sections)
      : sections = List<FocusSection>.unmodifiable(sections);

  List<int> _buildOffsets() {
    var offset = 0;
    final result = <int>[];
    for (final section in sections) {
      result.add(offset);
      offset += section.elementCount;
    }
    return result;
  }

  int get totalCount => sections.isEmpty
      ? 0
      : _offsets.last + sections.last.elementCount;

  int indexOf(String sectionId, int itemIndex) {
    final sectionIndex = sections.indexWhere((item) => item.id == sectionId);
    if (sectionIndex < 0) return 0;
    final section = sections[sectionIndex];
    return _offsets[sectionIndex] +
        itemIndex.clamp(0, section.elementCount - 1).toInt();
  }

  ({String sectionId, int itemIndex}) locationOf(int index) {
    for (var i = sections.length - 1; i >= 0; i--) {
      if (index >= _offsets[i]) {
        final section = sections[i];
        return (
          sectionId: section.id,
          itemIndex: (index - _offsets[i])
              .clamp(0, section.elementCount - 1)
              .toInt(),
        );
      }
    }
    return (sectionId: sections.first.id, itemIndex: 0);
  }

  TraversalFn get traversal => (current, direction, nodes) {
        final location = locationOf(current);
        final sectionIndex = sections
            .indexWhere((section) => section.id == location.sectionId);
        final section = sections[sectionIndex];
        final item = location.itemIndex; // 0..count-1 卡片；count = 查看更多
        switch (direction) {
          case DPad.left:
            // 一次一个卡片；行首停留；查看更多左移回行尾卡片。
            if (item > 0) return indexOf(section.id, item - 1);
            return current;
          case DPad.right:
            // 一次一个卡片；行尾卡片右移到查看更多（若有），否则停留。
            if (item < section.count) {
              if (item == section.count - 1 && section.trailing) {
                return indexOf(section.id, section.count);
              }
              return indexOf(section.id, item + 1);
            }
            return current; // 查看更多右移：停留
          case DPad.up:
            // 查看更多不参与普通上下导航：
            // - 焦点在查看更多 → 退出到本行行尾卡片；
            // - 本行最右侧（行尾）卡片按上 → 进入本行查看更多；
            // - 其余位置 → 上一排按屏幕位置对齐。
            if (item == section.count) {
              return indexOf(section.id, section.count - 1);
            }
            if (section.trailing && item == section.count - 1) {
              return indexOf(section.id, section.count);
            }
            if (sectionIndex == 0) return current;
            return _visualRowTarget(nodes, sectionIndex - 1, current);
          case DPad.down:
            // 焦点在查看更多 → 退出到本行行尾卡片；其余 → 下一排按屏幕位置。
            if (item == section.count) {
              return indexOf(section.id, section.count - 1);
            }
            if (sectionIndex == sections.length - 1) return current;
            return _visualRowTarget(nodes, sectionIndex + 1, current);
        }
      };

  /// 屏幕视觉位置导航：在目标行内找「屏幕 x 中心与当前焦点最接近」的卡片。
  /// - 横排滚动后不继承数据编号，仍按屏幕 x 锚定（屏幕最左侧 = 位置 0）；
  /// - 目标行较短（无对应列）时，x 最接近者即该行最后一个存在的卡片；
  /// - **只遍历本行卡片（end = start + count），查看更多不参与普通上下导航**；
  /// - 整行未挂载（视口外 cacheExtent 未构建）时回退该行最后一个已挂载
  ///   卡片，_requestFocus 会对未挂载目标延迟重试。
  int _visualRowTarget(
      List<FocusNode> nodes, int targetSectionIndex, int currentIndex) {
    final target = sections[targetSectionIndex];
    final start = _offsets[targetSectionIndex];
    // 只遍历本行卡片；「查看更多」是行尾独立目标，不参与上下切换。
    final end = start + target.count;
    final currentX = _screenCenterX(nodes, currentIndex);
    var best = start;
    var bestDist = double.infinity;
    var lastMounted = -1;
    for (var i = start; i < end && i < nodes.length; i++) {
      final ctx = nodes[i].context;
      if (ctx == null) continue;
      lastMounted = i;
      final x = _screenCenterX(nodes, i);
      if (x.isNaN) continue;
      final dist = (x - currentX).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = i;
      }
    }
    if (bestDist.isFinite) return best;
    return lastMounted >= start ? lastMounted : start;
  }

  /// 节点屏幕 x 中心（未挂载/无尺寸返回 NaN）。
  static double _screenCenterX(List<FocusNode> nodes, int index) {
    if (index < 0 || index >= nodes.length) return double.nan;
    final ctx = nodes[index].context;
    if (ctx == null) return double.nan;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return double.nan;
    return box.localToGlobal(Offset.zero).dx + box.size.width / 2;
  }
}

/// 单个可聚焦元素的焦点区域配置。
/// [count] 必须在整个区域生命周期内稳定；如需动态变化，请用 [Key] 重建。
class FocusAreaConfig {
  final String id;
  final int count;
  final TraversalFn traversal;
  final ValueChanged<int>? onFocusChanged;

  /// 方向键移动导致焦点索引变化时回调（区别于 [onFocusChanged]：focusAt/
  /// switchArea 等非用户方向键移动不会触发）。用于"焦点移动即激活"场景
  /// （如状态栏左右键直接切换页面）。
  final ValueChanged<int>? onMoveActivated;

  /// 长按 OK/Enter（按键重复事件）时，以当前焦点索引回调（如历史页长按
  /// OK 进入多选删除）。
  final ValueChanged<int>? onLongPressAt;

  /// 遍历到达区域边界（traversal 返回 -1）时回调，用于区域间衔接
  /// （如历史页最底部下键/顶部上键 → 切到状态栏）。
  final ValueChanged<DPad>? onBoundary;

  final bool releaseOnUp;
  final bool ignoreDown;

  const FocusAreaConfig({
    required this.id,
    required this.count,
    required this.traversal,
    this.onFocusChanged,
    this.onMoveActivated,
    this.onLongPressAt,
    this.onBoundary,
    this.releaseOnUp = false,
    this.ignoreDown = false,
  }) : assert(count > 0);
}

class FocusArea {
  final FocusAreaConfig config;
  final List<FocusNode> nodes;
  int focusIndex = 0;

  FocusArea(this.config)
      : nodes = List.generate(
          config.count,
          (index) => FocusNode(debugLabel: '${config.id}[$index]'),
        );

  int nextIndex(DPad direction) {
    final next = config.traversal(focusIndex, direction, nodes);
    // -1 表示"离开本区域"（区域边界），由 moveDPad 交给 onBoundary 处理。
    if (next < 0) return -1;
    return next.clamp(0, config.count - 1).toInt();
  }

  void dispose() {
    for (final node in nodes) node.dispose();
  }
}

class TraversalPolicies {
  static TraversalFn linear(int count) {
    assert(count > 0);
    return (current, direction, _) {
      switch (direction) {
        case DPad.left:
        case DPad.up:
          return current - 1;
        case DPad.right:
        case DPad.down:
          return current + 1;
      }
    };
  }

  static TraversalFn grid({required int columns, required int rowCount}) {
    assert(columns > 0 && rowCount > 0);
    return (current, direction, _) {
      final row = current ~/ columns;
      final col = current % columns;
      switch (direction) {
        case DPad.up:
          return row > 0 ? current - columns : current;
        case DPad.down:
          return row < rowCount - 1 ? current + columns : current;
        case DPad.left:
          return col > 0 ? current - 1 : current;
        case DPad.right:
          return col < columns - 1 ? current + 1 : current;
      }
    };
  }
}

class TvFocusManager extends ChangeNotifier {
  static final TvFocusManager instance = TvFocusManager._();
  TvFocusManager._();

  final Map<String, FocusArea> _areas = <String, FocusArea>{};
  String? _activeAreaId;
  final Map<String, int> _focusRetryCount = <String, int>{};
  final Map<String, int> _lastFocusIndex = <String, int>{};
  String? _lastActiveAreaId;

  /// 返回目标：进入状态栏（main_tabs）前活跃的区域，退出时归还焦点。
  String? _returnAreaId;

  /// 当前可见 tab 页面对应的页面区域 id（由 MainShell 随路由更新），
  /// 状态栏退出/下移时作为初始切入目标（如历史页刷新按钮/第一条卡片）。
  String? _currentPageAreaId;
  int _currentPageTopIndex = 0;
  int _currentPageFirstCardIndex = 1;

  bool get hasManagedFocus => _activeAreaId != null && _areas.containsKey(_activeAreaId);

  FocusArea? get activeArea => _areas[_activeAreaId];

  bool get hasFocusedArea => _lastActiveAreaId != null && _areas.containsKey(_lastActiveAreaId);

  String? get lastActiveAreaId => _lastActiveAreaId;

  /// 设置当前可见页面对应的页面区域 id（无区域页面传 null）。
  /// [topIndex]：状态栏上键退出时的切入位置（如服务器页加号按钮）；
  /// [firstCardIndex]：状态栏下键切入的列表首卡位置。
  void setCurrentPageArea(
    String? areaId, {
    int topIndex = 0,
    int firstCardIndex = 1,
  }) {
    _currentPageAreaId = areaId;
    _currentPageTopIndex = topIndex;
    _currentPageFirstCardIndex = firstCardIndex;
  }

  /// D-pad 接管条件：活动区域存在即接管（**不依赖节点是否已持有系统焦点**）——
  /// 覆盖层（状态栏）打开后方向键只操作当前显示层；节点未挂载/未聚焦时由
  /// [_requestFocus] 持续重试聚焦，避免方向键回退 Flutter 默认遍历
  /// 控制后台页面/乱跳。
  bool get canHandleDPad => hasManagedFocus;

  FocusArea? getArea(String areaId) => _areas[areaId];
  FocusArea? getAreaById(String areaId) => getArea(areaId);

  // ─── 区域注册 / 注销 ───

  FocusArea registerArea(FocusAreaConfig config) {
    assert(!_areas.containsKey(config.id),
        'TvFocusArea "${config.id}" 重复注册，如需重建请使用不同 Key');
    return _areas[config.id] = FocusArea(config);
  }

  void unregisterArea(String areaId) {
    final area = _areas.remove(areaId);
    if (area != null) {
      _lastFocusIndex[areaId] = area.focusIndex;
      area.dispose();
    }
    _focusRetryCount.removeWhere((key, _) => key.startsWith('$areaId:'));
    if (_activeAreaId == areaId) {
      _activeAreaId = null;
    }
    if (_lastActiveAreaId == areaId) {
      _lastActiveAreaId = null;
    }
  }

  /// 释放当前焦点，但不注销区域。
  void releaseArea(String areaId, {bool remember = true}) {
    if (_activeAreaId == areaId) _activeAreaId = null;
    final area = _areas[areaId];
    if (area != null && remember) {
      _lastFocusIndex[areaId] = area.focusIndex;
      _lastActiveAreaId = areaId;
    }
    final node = area?.nodes[area?.focusIndex ?? 0];
    node?.unfocus();
  }

  /// 记录区域最近一次焦点，但不移除系统焦点。
  void rememberArea(String areaId) {
    final area = _areas[areaId];
    if (area == null) return;
    _lastFocusIndex[areaId] = area.focusIndex;
    _lastActiveAreaId = areaId;
  }

  /// 切换到上一次离开的区域；成功返回 true。
  bool restoreLastArea() {
    final areaId = _lastActiveAreaId;
    if (areaId == null || !_areas.containsKey(areaId)) return false;
    switchArea(areaId);
    return true;
  }

  // ─── 集中管理 API ───

  /// 切换到指定区域；如无 initialIndex，恢复上次焦点。
  void switchArea(String areaId, {int? initialIndex}) {
    final area = _areas[areaId];
    if (area == null) return;
    // 区域切换（覆盖层/状态栏进出）：先释放旧活跃区域节点焦点——后台页面
    // 立即失去焦点，方向键只操作当前显示层，避免"状态栏打开后方向键还
    // 控制后台页面"。
    final previousAreaId = _activeAreaId;
    if (previousAreaId != null && previousAreaId != areaId) {
      final previous = _areas[previousAreaId];
      if (previous != null) {
        previous.nodes[previous.focusIndex]?.unfocus();
      }
    }
    final target = (initialIndex ?? _lastFocusIndex[areaId] ?? 0)
        .clamp(0, area.config.count - 1)
        .toInt();
    area.focusIndex = target;
    _activeAreaId = areaId;
    _lastActiveAreaId = areaId;
    _requestFocus(areaId, target);
    _notifyFocusChanged(area);
  }

  /// 进入区域（如 MENU 进入状态栏）：记录当前活跃区域为返回目标。
  void enterArea(String areaId, {int? initialIndex}) {
    if (_areas[areaId] == null) return;
    if (_activeAreaId != null && _activeAreaId != areaId) {
      _returnAreaId = _activeAreaId;
    }
    switchArea(areaId, initialIndex: initialIndex);
  }

  /// 退出区域（如状态栏内再按 MENU）：安全归还来源区域焦点；
  /// 无来源区域（从 Flutter 默认遍历进入）时仅释放，交还默认焦点树。
  void exitArea(String areaId) {
    if (_activeAreaId != areaId) return;
    _activeAreaId = null;
    final area = _areas[areaId];
    if (area != null) {
      _lastFocusIndex[areaId] = area.focusIndex;
      area.nodes[area.focusIndex].unfocus();
    }
    final returnId = _returnAreaId;
    _returnAreaId = null;
    if (returnId != null &&
        returnId != areaId &&
        _areas.containsKey(returnId)) {
      switchArea(returnId);
    }
  }

  /// 清空返回目标（路由变化后旧来源失效，避免退出状态栏时焦点回到
  /// 已不可见的旧页面区域）。
  void clearReturnTarget() {
    _returnAreaId = null;
  }

  /// 聚焦指定元素。
  void focusAt(String areaId, int index) {
    final area = _areas[areaId];
    if (area == null) return;
    final target = index.clamp(0, area.config.count - 1).toInt();
    _lastFocusIndex[areaId] = target;
    area.focusIndex = target;
    _activeAreaId = areaId;
    _lastActiveAreaId = areaId;
    _requestFocus(areaId, target);
    _notifyFocusChanged(area);
  }

  /// 方向键移动焦点。
  void moveDPad(DPad direction) {
    final area = activeArea;
    if (area == null || !hasManagedFocus) return;

    if (direction == DPad.up && area.config.releaseOnUp) {
      // 底部状态栏上键退出：优先归还来源区域焦点；
      // 无来源时切入当前页面区域顶部（如历史页刷新按钮）。
      _activeAreaId = null;
      area.nodes[area.focusIndex].unfocus();
      final returnId = _returnAreaId;
      _returnAreaId = null;
      if (returnId != null &&
          returnId != area.config.id &&
          _areas.containsKey(returnId)) {
        switchArea(returnId);
        return;
      }
      final pageArea = _currentPageAreaId;
      if (pageArea != null && _areas.containsKey(pageArea)) {
        switchArea(pageArea, initialIndex: _currentPageTopIndex);
      }
      return;
    }

    if (direction == DPad.down && area.config.ignoreDown) {
      // 底部状态栏下键：若当前页面有焦点区域（如历史页/服务器列表），
      // 切入其第一条记录/服务器卡片；否则保持当前焦点。
      final pageArea = _currentPageAreaId;
      if (pageArea != null && _areas.containsKey(pageArea)) {
        switchArea(pageArea, initialIndex: _currentPageFirstCardIndex);
      }
      return;
    }

    final next = area.nextIndex(direction);
    if (next < 0) {
      // 到达区域边界：由配置的边界回调衔接（如历史页顶部上键/底部下键 → 状态栏）。
      area.config.onBoundary?.call(direction);
      return;
    }
    if (next == area.focusIndex) return;
    _lastFocusIndex[area.config.id] = next;
    area.focusIndex = next;
    _lastActiveAreaId = area.config.id;
    _requestFocus(area.config.id, next);
    _notifyFocusChanged(area);
    // 仅用户方向键移动触发（focusAt/switchArea 等不会走到这里）。
    area.config.onMoveActivated?.call(next);
  }

  // ─── 系统焦点树同步 ───

  void _requestFocus(String areaId, int index) {
    final area = _areas[areaId];
    if (area == null || index < 0 || index >= area.nodes.length) return;
    final node = area.nodes[index];
    // 未挂载（懒加载视口外，widget 未构建）视为不可聚焦：延迟重试，
    // 等待滚动容器 cacheExtent 构建后挂载（避免 requestFocus 静默失败
    // 导致 canHandleDPad 变 false、方向键回退 Flutter 默认遍历乱跳）。
    if (node.context != null && node.canRequestFocus) {
      _focusRetryCount.removeWhere((key, _) => key.startsWith('$areaId:'));
      node.requestFocus();
      // 聚焦后按可见性最小滚动：覆盖 TextButton 等无自带滚动逻辑的节点
      // （如「查看更多」——从行尾进入时若标题行已滚出视口，自动滚回可见）；
      // 卡片已有 TvFocusable 的智能滚动，此处幂等无副作用。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = node.context;
        if (ctx != null && node.hasFocus) ensureVisibleSmartly(ctx);
      });
      return;
    }
    final retryKey = '$areaId:$index';
    final retry = (_focusRetryCount[retryKey] ?? 0) + 1;
    if (retry > 6) {
      _focusRetryCount.remove(retryKey);
      return;
    }
    _focusRetryCount[retryKey] = retry;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_activeAreaId != areaId || area.focusIndex != index) return;
      _requestFocus(areaId, index);
    });
  }

  void _notifyFocusChanged(FocusArea area) {
    area.config.onFocusChanged?.call(area.focusIndex);
    notifyListeners();
  }

  @override
  void dispose() {
    for (final area in _areas.values) area.dispose();
    _areas.clear();
    super.dispose();
  }
}
