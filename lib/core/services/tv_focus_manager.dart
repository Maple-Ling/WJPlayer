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

/// 单个可聚焦元素的焦点区域配置。
/// [count] 必须在整个区域生命周期内稳定；如需动态变化，请用 [Key] 重建。
class FocusAreaConfig {
  final String id;
  final int count;
  final TraversalFn traversal;
  final ValueChanged<int>? onFocusChanged;

  const FocusAreaConfig({
    required this.id,
    required this.count,
    required this.traversal,
    this.onFocusChanged,
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

  bool get hasManagedFocus => _activeAreaId != null && _areas.containsKey(_activeAreaId);

  FocusArea? get activeArea => _areas[_activeAreaId];

  bool get hasFocusedArea => _lastActiveAreaId != null && _areas.containsKey(_lastActiveAreaId);

  String? get lastActiveAreaId => _lastActiveAreaId;

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

  /// 切换区域：若当前就在目标区域，直接释放焦点并返回 false；否则切换到目标区域并返回 true。
  bool toggleArea(String areaId, {int? initialIndex}) {
    final area = _areas[areaId];
    if (area == null) return false;
    if (_activeAreaId == areaId) {
      // 已在该区域，直接释放焦点
      _activeAreaId = null;
      area.nodes[area.focusIndex].unfocus();
      return false;
    }
    switchArea(areaId, initialIndex: initialIndex);
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

    if (direction == DPad.up) {
      // 上键：释放焦点，返回 Flutter 默认焦点树
      _activeAreaId = null;
      area.nodes[area.focusIndex].unfocus();
      return;
    }

    if (direction == DPad.down) return; // 下键舍弃

    final next = area.nextIndex(direction);
    if (next == area.focusIndex) return;
    _lastFocusIndex[area.config.id] = next;
    area.focusIndex = next;
    _lastActiveAreaId = area.config.id;
    _requestFocus(area.config.id, next);
    _notifyFocusChanged(area);
  }

  // ─── 系统焦点树同步 ───

  void _requestFocus(String areaId, int index) {
    final area = _areas[areaId];
    if (area == null || index < 0 || index >= area.nodes.length) return;
    final node = area.nodes[index];
    if (node.canRequestFocus) {
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
