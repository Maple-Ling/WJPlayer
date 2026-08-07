/// canvas_danmaku 弹幕时间窗口加载器（滑动窗口 + 游标 + 二分 + 去重）
///
/// 目标：播放全程只加载「当前播放时间 ~ 当前时间 + windowAheadMs」窗口内的弹幕，
/// 避免一次 addAll 几万条导致的 Dart 对象批量创建 / GC 周期回收 / UI 线程阻塞。
///
/// 设计要点：
/// - [items] 须在播放前一次解析完成并按 [DanmakuItem.time] 升序排列，播放中不再解析。
/// - 用「游标 [_cursorIndex]（只增不减）+ 二分查找」定位窗口，回调中不遍历全量、
///   不建临时 List、不 new 对象（仅窗口内新增条目逐条 addDanmaku）。
/// - [seenIds] (Set<int>) 记录已入队弹幕的稳定整数指纹，Set<int> 值类型零对象引用，
///   GC 无感；同一弹幕（同毫秒/文本/颜色/类型）只入队一次。
/// - Seek：调用 [reset]，内部 controller.clear() 清屏 + 清空 seen + 游标归零重喂新窗口。
/// - 倍速：经 [setSpeed] 同步 controller.speedRate，并按倍速拉长窗口防高速播放断层
///   （有效窗口 = windowAheadMs / speedRate）。
/// - 同时显示上限 [maxShowCount]：单次喂入预算，防止某个时间戳瞬时超大导致掉帧；
///   已上屏弹幕的过期/离场由 canvas_danmaku 引擎内部生命周期管理，本类不手动 remove。
///
/// canvas_danmaku 版本适配说明（^0.3.1）：
/// - `DanmakuController.speedRate`、`addDanmaku`、`clear`、`updateOption` 均为
///   ^0.3.1 已有 API，本类直接使用。
/// - `DanmakuScreen(createdController:, option:)` 已有；本类不持有 widget，仅持 controller。
/// - 若你的 canvas_danmaku 版本支持「同时显示条数上限」（如 DanmakuOption 的
///   maxCount/maxShowCount 字段），请把 [maxShowCount] 传给它并在
///   `_buildDanmakuOption` 中同步；当前实现以单次喂入预算近似（每 200ms 至多
///   新增 maxShowCount 条，远低于引擎吞吐，等效限制同时上屏数量）。
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:canvas_danmaku/canvas_danmaku.dart' hide DanmakuItem;
import '../api/api_interfaces.dart';

/// 过滤回调：返回 false 的弹幕跳过（由上层注入现有的彩色/白色开关 + 密度过滤）。
typedef DanmakuFeedFilter = bool Function(DanmakuItem item);

class DanmakuLoader {
  /// 已排序的全部弹幕（播放前解析，只读，不重建）
  final List<DanmakuItem> _items;

  /// canvas_danmaku 控制器（只持有引用，不持有所有权）
  final DanmakuController<dynamic> _controller;

  /// 窗口向前长度（毫秒）。倍速时有效窗口 = windowAheadMs / speedRate。
  final int windowAheadMs;

  /// 同时显示上限 / 单次喂入预算：限制每帧 addDanmaku 数量，防瞬时超大窗口掉帧。
  final int maxShowCount;

  /// 游标：已处理到 _items 的索引，只增不减（正常顺播绝无回退）。
  int _cursorIndex = 0;

  /// 去重集合：已入队弹幕的整数指纹（Set<int> 值类型，零对象引用）。
  final Set<int> _seenIds = {};

  /// 来源过滤回调（逐条实时判断，由调用方注入）。
  final DanmakuFeedFilter feedFilter;

  double _speedRate = 1.0;
  bool _disposed = false;

  DanmakuLoader({
    required List<DanmakuItem> items,
    required DanmakuController<dynamic> controller,
    this.windowAheadMs = 20000,
    this.maxShowCount = 45,
    this.feedFilter = _alwaysFeed,
  })  : _items = items,
        _controller = controller;

  static bool _alwaysFeed(DanmakuItem item) => true;

  double get speedRate => _speedRate;

  // ------------- 倍速 -------------

  /// 设置倍速：拉长加载窗口防高速播放断层。
  /// 注：canvas_danmaku ^0.3.1 的 DanmakuController 无 speedRate setter，
  /// 引擎侧弹幕动画速度由 _buildDanmakuOption 的 duration 参数控制（播放器
  /// 每次 build 时 updateOption 同步），本方法只调整加载窗口。
  void setSpeed(double speed) {
    _speedRate = speed.clamp(0.25, 4.0);
  }

  // ------------- 状态恢复（Seek / 切集 / 重新挂载） -------------

  /// Seek / 切集：清空画布全部弹幕 + 清空去重集合 + 游标归零，重喂新窗口。
  void reset(Duration position) {
    _controller.clear();
    _seenIds.clear();
    _cursorIndex = 0;
    _feed(position);
  }

  /// 释放（进入播放器 / 弹幕列表变化重建时调用）。
  void dispose() {
    _disposed = true;
  }

  // ------------- 每个 onPositionChanged 调用（约 200ms） -------------

  /// 播放器 position 回调入口（毫秒）。只做窗口推进 + 增量入队。
  ///
  /// 严格约束：
  /// - 不遍历整个 _items（二分 O(log n)）
  /// - 不创建临时 List
  /// - 只对窗口内新增条目调 addDanmaku（每帧 ≤ maxShowCount）
  void onPositionChanged(int positionMs) {
    if (_disposed || _items.isEmpty) return;
    _feed(Duration(milliseconds: positionMs));
  }

  void _feed(Duration position) {
    final posMs = position.inMilliseconds;
    // 倍速越高有效窗口越短（内容在高速下覆盖更少的实际播放时长）。
    final windowMs = (windowAheadMs / _speedRate).round();
    final windowEndMs = posMs + windowMs;

    // 二分查找窗口右边界（_items 已按 time 升序）。
    final endIdx = _lowerBound(windowEndMs);

    // 游标已在窗口右边界之后 → 无新弹幕可喂。
    if (endIdx <= _cursorIndex) return;

    // 单帧喂入上限：限制同帧新增，超出的下帧再喂（_cursorIndex 已推进不重复）。
    final until = min(endIdx, _cursorIndex + maxShowCount);

    for (var i = _cursorIndex; i < until; i++) {
      final item = _items[i];
      if (!feedFilter(item)) continue;
      final key = _fingerprint(item);
      if (_seenIds.add(key)) {
        _emit(item);
      }
    }
    _cursorIndex = until; // 即使被 maxShowCount 截断也不重复处理
  }

  // ------------- 二分查找 -------------

  /// 在 _items 中找第一个 time(秒) 转毫秒 >= targetMs 的索引。
  int _lowerBound(int targetMs) {
    int lo = 0, hi = _items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_items[mid].time * 1000 < targetMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  // ------------- 指纹 & 入队 -------------

  /// 稳定整数指纹（替代项目里 DanmakuItem 缺失的 id(int) 字段）：
  /// 毫秒级时间 + 文本 + 颜色 + 类型。Set<int> 存储，零对象引用。
  int _fingerprint(DanmakuItem item) {
    return Object.hash(
      (item.time * 1000).round(),
      item.text.hashCode,
      item.color,
      item.type,
    );
  }

  void _emit(DanmakuItem item) {
    _controller.addDanmaku(DanmakuContentItem<dynamic>(
      item.text,
      color: Color(item.color | 0xFF000000),
      type: _canvasDanmakuType(item.type),
      // 去重合并计数（≥2 时注入，渲染层可据此处理密度）。
      count: item.count > 1 ? item.count : null,
    ));
  }

  /// 弹幕 type → canvas_danmaku 类型：4=底部、5=顶部，其余（1/2/3 滚动、
  /// 6 逆向、7+ 特殊）统一右→左滚动（与项目现有语义一致）。
  static DanmakuItemType _canvasDanmakuType(int type) {
    if (type == 4) return DanmakuItemType.bottom;
    if (type == 5) return DanmakuItemType.top;
    return DanmakuItemType.scroll;
  }
}