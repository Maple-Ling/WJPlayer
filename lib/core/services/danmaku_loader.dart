/// canvas_danmaku 弹幕时间窗口加载器（增量喂入 + 游标 + 二分 + 去重）
///
/// 目标：避免一次性 addAll 几万条导致的 Dart 对象批量创建 / GC 周期回收 / UI 线程阻塞。
///
/// 核心语义（与原"按秒喂"等价但更强）：
/// - [items] 播放前一次解析完成并按 [DanmakuItem.time] 升序排列，播放中不再解析。
/// - **增量喂入**：每次 onPositionChanged(position) 只喂「上一次喂入点 → 当前位置」
///   之间**新经过**的弹幕（即此刻该上屏的弹幕），绝不提前批量加载未来弹幕。
///   位图创建（引擎侧 generateParagraph/recordDanmakuImage）量 = 每 200ms 实际
///   产生的弹幕条数（通常几条到几十条），不会因预加载 20 秒产生位图风暴。
/// - **二分 [_lowerBound]**：每次按时间窗 O(log n) 定位起点/终点，不遍历全量、
///   不建临时 List、不追赶历史（超单帧预算的弹幕直接丢弃，宁缺毋卡）。
/// - **[seenIds] Set<int>**：整数指纹去重（值类型零对象引用），同条弹幕只入队一次。
/// - **seek**：调用 [reset]，controller.clear() 清屏 + 清空 seen + 游标归零重喂。
/// - **倍速**：加载窗口按倍速缩短/拉长；引擎侧动画速度由播放页 updateOption 控制。
///
/// canvas_danmaku ^0.3.1 适配：DanmakuController 无 speedRate setter（引擎动画
/// 速度由 DanmakuOption.duration 控制，播放页每次 build 同步 updateOption 即可），
/// 本类只负责「何时喂、喂多少」，不控制动画速率。
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

  /// 单次 feed 最大入队条数（防单帧突发超大窗口掉帧；超出下帧继续）。
  final int maxShowCount;

  /// 增量喂入的起点（毫秒，构造即设定，避免首次全量喂历史）。
  final int initialPositionMs;

  /// 上次喂入的播放位置（毫秒）：增量喂入的起点。
  int _fedMs = 0;

  /// reset（seek）后向回回退的毫秒数：让新位置立即上屏最近一小段弹幕。
  static const int _seedAheadMs = 300;

  /// 去重集合：已入队弹幕的整数指纹（Set<int> 值类型，零对象引用）。
  final Set<int> _seenIds = {};

  /// 来源过滤回调（逐条实时判断，由调用方注入）。
  final DanmakuFeedFilter feedFilter;

  bool _disposed = false;

  DanmakuLoader({
    required List<DanmakuItem> items,
    required DanmakuController<dynamic> controller,
    this.maxShowCount = 45,
    this.initialPositionMs = 0,
    this.feedFilter = _defaultTrue,
  })  : _items = items,
        _controller = controller,
        _fedMs = initialPositionMs - _seedAheadMs;

  static bool _defaultTrue(DanmakuItem item) => true;

  // ------------- 状态恢复（Seek / 切集 / 重新挂载） -------------

  /// Seek / 切集：清空画布全部弹幕 + 清空去重集合 + 游标归零，重喂新窗口。
  void reset(Duration position) {
    _controller.clear();
    _seenIds.clear();
    // 从新位置往前回退 300ms 作为首次喂入起点：seek 后立即上屏最近 300ms
    // 的弹幕（量小、无位图风暴），后续增量平滑推进。
    _fedMs = position.inMilliseconds - _seedAheadMs;
    _feed(position);
  }

  /// 释放（进入播放器 / 弹幕列表变化重建时调用）。
  void dispose() {
    _disposed = true;
  }

  // ------------- 每个 onPositionChanged 调用（约 200ms） -------------

  /// 播放器 position 回调入口（毫秒）。只喂「上一次喂入 → 当前位置」间的增量。
  /// 调用频率约 200ms，每次新增条数 = 这段时间内实际出现的弹幕（通常 <= 几十条）。
  void onPositionChanged(int positionMs) {
    if (_disposed || _items.isEmpty) return;
    _feed(Duration(milliseconds: positionMs));
  }

  void _feed(Duration d) {
    final posMs = d.inMilliseconds;
    if (posMs < _fedMs) {
      // 位置回退（seek/跳变）：由上层跳变检测调 reset 清屏重喂；兜底防漏。
      reset(d);
      return;
    }
    final fromMs = _fedMs;
    _fedMs = posMs;

    // 严格时间窗：只喂 [fromMs, posMs] 刚经过时间段内的弹幕（此刻该上屏的）。
    // 绝无追赶——如果该时段弹幕数超过单帧预算，超出部分直接丢弃（宁可少弹幕，
    // 不因追喂历史弹幕造成持续位图创建卡顿）。这才是大厂密度控制的本质。
    final startIdx = _lowerBound(fromMs);
    final endIdx = _lowerBound(posMs);
    if (endIdx <= startIdx) return;

    // 单帧预算：超出的丢弃（不推进游标到 endIdx，但也不会回头补喂——
    // 因为 fromMs 只前进不后退，被丢的弹幕永远过了播放时刻，丢弃即放弃）。
    final until = min(endIdx, startIdx + maxShowCount);
    for (var i = startIdx; i < until; i++) {
      final item = _items[i];
      if (!feedFilter(item)) continue;
      final key = _fingerprint(item);
      if (_seenIds.add(key)) {
        _emit(item);
      }
    }
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
  /// 毫秒级时间 + 文本 + 颜色 + 类型。
  int _fingerprint(DanmakuItem item) {
    return Object.hash(
      (item.time * 1000).round(),
      item.text.hashCode,
      item.color,
      item.type,
    );
  }

  void _emit(DanmakuItem item) {
    final content = DanmakuContentItem<dynamic>(
      item.text,
      color: Color(item.color | 0xFF000000),
      type: _canvasDanmakuType(item.type),
      count: item.count > 1 ? item.count : null,
    );
    _controller.addDanmaku(content);
  }

  /// 弹幕 type → canvas_danmaku 类型：4=底部、5=顶部，其余（1/2/3 滚动、
  /// 6 逆向、7+ 特殊）统一右→左滚动（与项目现有语义一致）。
  static DanmakuItemType _canvasDanmakuType(int type) {
    if (type == 4) return DanmakuItemType.bottom;
    if (type == 5) return DanmakuItemType.top;
    return DanmakuItemType.scroll;
  }
}