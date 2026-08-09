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

enum DPad { up, down, left, right }

typedef TraversalFn = int Function(int current, DPad direction);

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
///   - 下：进入下一分区，保持列位置（clamp 到下一行卡片数）；最后一行停留，
///     严禁水平随机跳转。
///   - 上：直接进入上一分区（保持列位置，clamp 到上一行卡片数），
///     第一行停留；「查看更多」不再是上键的第一跳（用户反馈调整），
///     由行尾卡片右键到达。
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

  TraversalFn get traversal => (current, direction) {
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
            // 垂直分类切换（2026-08-09 用户反馈调整）：直接上一分区同列
            // （clamp 到上一行卡片数），不再先跳本行「查看更多」。
            // 「查看更多」仍可通过行尾卡片右键到达。
            if (sectionIndex == 0) return current;
            final previous = sections[sectionIndex - 1];
            return indexOf(previous.id,
                item.clamp(0, previous.count - 1).toInt());
          case DPad.down:
            // 确定性垂直切换：下一分区，保持列位置；最后一行停留。
            if (sectionIndex == sections.length - 1) return current;
            final next = sections[sectionIndex + 1];
            return indexOf(next.id,
                item.clamp(0, next.count - 1).toInt());
        }
      };
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
    final next = config.traversal(focusIndex, direction);
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
    return (current, direction) {
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
    return (current, direction) {
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

  /// D-pad 接管条件：活动区域存在，且当前焦点节点真的持有 Flutter 系统焦点。
  bool get canHandleDPad =>
      _activeAreaId != null &&
      activeArea?.nodes[activeArea!.focusIndex]?.hasFocus == true;

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
