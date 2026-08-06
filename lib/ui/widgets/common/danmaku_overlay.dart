import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';
import '../../../core/api/api_interfaces.dart';

class DanmakuOverlay extends StatefulWidget {
  final List<DanmakuItem> items;
  final Duration position;
  final bool isPlaying;

  /// 播放器当前倍速。Ticker 按该倍率推进弹幕时间轴，避免 1.5x/2x 时每次
  /// 与播放器位置同步都发生跳帧，Exo/MPV 共用。
  final double playbackRate;
  final double opacity;
  final double fontSizeFactor;
  final double speedFactor;
  final double densityFactor;

  /// 显示区域占视频高度比例（0.25/0.5/1.0），弹幕只用顶部这一段轨道。
  final double displayArea;

  /// 描边文字（黑边）。关闭则用半透明底框。
  final bool stroke;

  /// 自定义弹幕字体家族名（已通过 FontService 加载）；null 用系统默认。
  final String? fontFamily;

  const DanmakuOverlay({
    super.key,
    required this.items,
    required this.position,
    this.isPlaying = true,
    this.playbackRate = 1.0,
    this.opacity = 0.8,
    this.fontSizeFactor = 0.5,
    this.speedFactor = 0.5,
    this.densityFactor = 0.5,
    this.displayArea = 1.0,
    this.stroke = true,
    this.fontFamily,
  });

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  Duration _tickerElapsed = Duration.zero;
  Duration _smoothPosition = Duration.zero;
  Duration _lastSyncPosition = Duration.zero;
  Duration _lastSyncElapsed = Duration.zero;
  double _lastPlaybackRate = 1.0;

  /// 段落缓存随 State 存活（跨帧持久），替代旧的 static 缓存（跨实例共享是隐患）。
  final DanmakuLayoutCache _cache = DanmakuLayoutCache();

  @override
  void initState() {
    super.initState();
    _smoothPosition = widget.position;
    _lastSyncPosition = widget.position;
    _lastSyncElapsed = Duration.zero;
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    _tickerElapsed = elapsed;
    if (!widget.isPlaying) {
      _lastSyncElapsed = elapsed;
      return;
    }
    final delta = elapsed - _lastSyncElapsed;
    final scaledMicros =
        (delta.inMicroseconds * widget.playbackRate.clamp(0.1, 8.0)).round();
    _smoothPosition =
        _lastSyncPosition + Duration(microseconds: scaledMicros);
    setState(() {});
  }

  @override
  void didUpdateWidget(DanmakuOverlay old) {
    super.didUpdateWidget(old);
    final positionDelta = (widget.position - old.position).abs();
    final rateChanged = (widget.playbackRate - old.playbackRate).abs() > 0.001;
    // 正常播放时父层每次刷新都会带来微小 position 差异，不能重置时间轴；
    // 只有 seek/换集/暂停恢复/倍速改变才重新锚定。
    final isSeek = positionDelta > const Duration(milliseconds: 450);
    if (isSeek || rateChanged) {
      _lastSyncPosition = widget.position;
      _lastSyncElapsed = _tickerElapsed;
      _smoothPosition = widget.position;
      _lastPlaybackRate = widget.playbackRate;
    }
    if (widget.isPlaying && !old.isPlaying) {
      _lastSyncPosition = _smoothPosition;
      _lastSyncElapsed = _tickerElapsed;
    }
  }

  @override
  void dispose() {
    _cache.clear();
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: widget.opacity.clamp(0.0, 1.0),
      child: CustomPaint(
        painter: DanmakuPainter(
          items: widget.items,
          videoPosition: _smoothPosition,
          fontSizeFactor: widget.fontSizeFactor,
          speedFactor: widget.speedFactor,
          densityFactor: widget.densityFactor,
          displayArea: widget.displayArea,
          stroke: widget.stroke,
          fontFamily: widget.fontFamily,
          cache: _cache,
        ),
        size: Size.infinite,
      ),
    );
  }
}

/// 跨帧持久的段落布局缓存（按 items 引用 + 字号 + 宽度 + 描边 失效）。
class DanmakuLayoutCache {
  List<DanmakuItem>? _items;
  double? _fontSize;
  double? _width;
  bool? _stroke;

  List<ui.Paragraph?> _fill = const [];
  List<ui.Paragraph?> _strokeParas = const [];
  List<double> _widths = const [];

  String? _fontFamily;

  /// 每条弹幕分配到的轨道号（index → lane），起播时算一次后冻结，跨帧复用，
  /// 避免每帧重算导致的 Y 抖动。轨道数/速度变化时清空重排。
  final Map<int, int> laneOf = {};
  int? _laneTrackCount;
  double? _laneSpeed;

  void ensure(List<DanmakuItem> items, double fontSize, double width,
      bool stroke, String? fontFamily) {
    if (identical(_items, items) &&
        _fontSize == fontSize &&
        _width == width &&
        _stroke == stroke &&
        _fontFamily == fontFamily) {
      return;
    }
    _items = items;
    _fontSize = fontSize;
    _width = width;
    _stroke = stroke;
    _fontFamily = fontFamily;
    _fill = List<ui.Paragraph?>.filled(items.length, null);
    _strokeParas = List<ui.Paragraph?>.filled(items.length, null);
    _widths = List<double>.filled(items.length, 0);
    laneOf.clear(); // 换集/换字号 → 索引与宽度全变，轨道分配重来
  }

  /// 轨道数或速度变了（旋转/改显示区域/改速度）→ 已冻结的轨道号失效，清空重排。
  void ensureLanes(int trackCount, double speed) {
    if (_laneTrackCount != trackCount || _laneSpeed != speed) {
      _laneTrackCount = trackCount;
      _laneSpeed = speed;
      laneOf.clear();
    }
  }

  void clear() {
    _items = null;
    _fill = const [];
    _strokeParas = const [];
    _widths = const [];
    laneOf.clear();
  }

  double widthOf(int i) => _widths[i];
  ui.Paragraph? fillOf(int i) => _fill[i];
  ui.Paragraph? strokeOf(int i) => _strokeParas[i];

  void store(int i, ui.Paragraph fill, ui.Paragraph? strokePara, double w) {
    _fill[i] = fill;
    _strokeParas[i] = strokePara;
    _widths[i] = w;
  }
}

class _DanmakuTrackItem {
  final int index;
  final DanmakuItem item;
  double startY;
  final double width;
  final ui.Paragraph fill;
  final ui.Paragraph? stroke;

  _DanmakuTrackItem({
    required this.index,
    required this.item,
    required this.startY,
    required this.width,
    required this.fill,
    required this.stroke,
  });
}

class DanmakuPainter extends CustomPainter {
  final List<DanmakuItem> items;
  final Duration videoPosition;
  final double fontSizeFactor;
  final double speedFactor;
  final double densityFactor;
  final double displayArea;
  final bool stroke;
  final String? fontFamily;
  final DanmakuLayoutCache cache;

  static const double _maxFontSize = 36.0;
  static const double _minFontSize = 12.0;
  static const double _baseSpeed = 120.0;
  static const double _topBottomDuration = 5.0;
  double get _trackHeight => (_fontSize + 12.0).clamp(34.0, 56.0);
  static const double _padding = 4.0;
  static const double _visibleWindow = 30.0;

  DanmakuPainter({
    required this.items,
    required this.videoPosition,
    required this.fontSizeFactor,
    required this.speedFactor,
    required this.densityFactor,
    required this.displayArea,
    required this.stroke,
    required this.cache,
    this.fontFamily,
  });

  double get _fontSize =>
      _minFontSize + (_maxFontSize - _minFontSize) * fontSizeFactor;
  double get _speed => _baseSpeed * (0.5 + speedFactor);
  double get _currentSeconds => videoPosition.inMilliseconds / 1000.0;
  int get _maxVisible =>
      (items.length * (0.3 + densityFactor * 0.7)).round().clamp(0, items.length);

  _DanmakuTrackItem _getTrackItem(int index, Size size) {
    var fill = cache.fillOf(index);
    if (fill == null) {
      final item = items[index];
      final fs = item.size > 0 ? (item.size / 25.0 * _fontSize) : _fontSize;
      fill = _buildParagraph(item, size, fs, fillMode: true);
      final strokePara =
          stroke ? _buildParagraph(item, size, fs, fillMode: false) : null;
      cache.store(index, fill, strokePara, fill.maxIntrinsicWidth + _padding * 2);
    }
    return _DanmakuTrackItem(
      index: index,
      item: items[index],
      startY: 0,
      width: cache.widthOf(index),
      fill: fill,
      stroke: cache.strokeOf(index),
    );
  }

  ui.Paragraph _buildParagraph(DanmakuItem item, Size size, double fs,
      {required bool fillMode}) {
    final color = Color(item.color | 0xFF000000);
    final displayText =
        item.count > 1 ? '${item.text} ×${item.count}' : item.text;

    final fam = fontFamily;
    final ui.TextStyle style;
    if (!stroke) {
      // 旧观感：半透明底框 + 实色字。
      style = ui.TextStyle(
        color: color,
        background: ui.Paint()..color = const Color(0x60000000),
        fontSize: fs,
        fontFamily: fam,
      );
    } else if (fillMode) {
      style = ui.TextStyle(color: color, fontSize: fs, fontFamily: fam);
    } else {
      // 描边层：黑色 stroke。
      final strokeWidth = (fs / 14).clamp(1.2, 2.6);
      style = ui.TextStyle(
        foreground: ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeJoin = ui.StrokeJoin.round
          ..color = const Color(0xCC000000),
        fontSize: fs,
        fontFamily: fam,
      );
    }

    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontSize: fs,
      maxLines: 1,
      ellipsis: '',
      fontFamily: fam,
    ))
      ..pushStyle(style)
      ..addText(displayText);
    final paragraph = builder.build();
    paragraph.layout(ui.ParagraphConstraints(width: size.width));
    return paragraph;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty || size.isEmpty) return;

    final usableHeight = size.height * displayArea.clamp(0.0, 1.0);
    final trackCount = (usableHeight / _trackHeight).floor();
    if (trackCount <= 0) return;

    cache.ensure(items, _fontSize, size.width, stroke, fontFamily);
    cache.ensureLanes(trackCount, _speed);

    final visibleItems = <_DanmakuTrackItem>[];
    var added = 0;
    final maxVisible = _maxVisible;
    for (var i = 0; i < items.length; i++) {
      if (added >= maxVisible) break;
      final diff = items[i].time - _currentSeconds;
      if (diff < -_visibleWindow || diff > _visibleWindow) continue;
      visibleItems.add(_getTrackItem(i, size));
      added++;
    }

    // 轨道分配采用「冻结 + 追尾检查 + 类型分区」模型：
    // - 固定弹幕（type 4 底部 / 5 顶部）独占顶部若干轨道
    //   （0..fixedLaneCount-1，5 秒占轨到期腾轨顺延），滚动弹幕用其余轨道
    //   （fixedLaneCount..）——分区互不重叠，杜绝「单轨几条弹幕上下重叠」；
    // - 弹幕入轨后轨道号冻结（laneOf），跨帧复用 → 不 Y 跳动闪烁
    //   （每帧全量重排会让同一弹幕在不同帧被分到不同轨道，视觉上像
    //   单轨多条弹幕互相交替显示）；
    // - 每帧只做追尾检查：同轨尾条与自身左右重叠才解除冻结重分配；
    //   出屏弹幕释放轨道。
    final fixedLaneCount =
        (trackCount * 0.3).floor().clamp(0, trackCount - 1);
    final laneTail = List<_DanmakuTrackItem?>.filled(trackCount, null);
    final scrollOccupant = List<_DanmakuTrackItem?>.filled(trackCount, null);
    final topOccupant = List<_DanmakuTrackItem?>.filled(trackCount, null);
    final bottomOccupant = List<_DanmakuTrackItem?>.filled(trackCount, null);
    final born = visibleItems
        .where((ti) => ti.item.time <= _currentSeconds)
        .toList()
      ..sort((a, b) => a.item.time.compareTo(b.item.time));

    // 1) 出屏弹幕释放轨道 + 按冻结轨道登记尾条（按 time 升序覆盖为最新）。
    for (final ti in born) {
      final lane = cache.laneOf[ti.index];
      if (lane == null) continue;
      if (_computeX(ti, size) + ti.width < 0) {
        cache.laneOf.remove(ti.index);
        continue;
      }
      laneTail[lane] = ti; // 后入的 time 更大 → 天然成为尾条
    }

    // 2) 分配：已有冻结轨道的做追尾检查；新弹幕（含追尾被解除的）选轨。
    for (final ti in born) {
      final x = _computeX(ti, size);
      if (x + ti.width < 0) continue; // 已出屏
      final existing = cache.laneOf[ti.index];
      if (existing != null) {
        final tail = laneTail[existing];
        // 安全 = 无尾条 / 自身就是尾条 / 与尾条左右不相交
        // （早入轨弹幕在尾条左侧、后入轨弹幕在尾条右侧都正常；
        //  只有真正的左右重叠才算追尾，解除冻结重分配）。
        final safe = tail == null ||
            identical(tail, ti) ||
            x + ti.width + _padding <= _computeX(tail, size) ||
            x >= _computeX(tail, size) + tail.width + _padding;
        if (safe) {
          laneTail[existing] = ti;
          continue;
        }
        cache.laneOf.remove(ti.index); // 追尾 → 解除冻结重新分配
      }
      if (_isFixed(ti.item.type)) {
        final lane = _assignLane(ti, size, scrollOccupant, topOccupant,
            bottomOccupant, trackCount,
            maxLane: fixedLaneCount);
        _recordOccupant(ti, lane, scrollOccupant, topOccupant, bottomOccupant);
        cache.laneOf[ti.index] = lane;
        ti.startY = lane * _trackHeight + _padding;
        laneTail[lane] = ti;
        continue;
      }
      var selectedLane = -1;
      // 滚动弹幕只使用固定弹幕区之外的轨道（分区，避免同轨重叠）。
      for (var lane = fixedLaneCount; lane < trackCount; lane++) {
        final tail = laneTail[lane];
        if (tail == null) {
          selectedLane = lane;
          break;
        }
        // 后入弹幕从屏右进入：右界完全排在该轨尾条右侧即安全（同速不追尾）。
        if (x > _computeX(tail, size) + tail.width + _padding) {
          selectedLane = lane;
          break;
        }
      }
      // 轨道全部繁忙时选择当前最早离场的轨道（尾条右界最靠左）。
      // 若新弹幕 x 仍不超过该轨右界 + padding，这一帧先跳过不画
      // （laneOf 未登记），等下一帧轨道让出后再入轨——避免强制同轨追尾。
      if (selectedLane < 0) {
        var earliest = double.infinity;
        for (var lane = fixedLaneCount; lane < trackCount; lane++) {
          final tail = laneTail[lane];
          if (tail == null) {
            selectedLane = lane;
            break;
          }
          final release = _computeX(tail, size) + tail.width;
          if (release < earliest) {
            earliest = release;
            selectedLane = lane;
          }
        }
        if (selectedLane >= 0) {
          final tail = laneTail[selectedLane];
          if (tail != null &&
              x <= _computeX(tail, size) + tail.width + _padding) {
            continue;
          }
        }
      }
      cache.laneOf[ti.index] = selectedLane;
      ti.startY = selectedLane * _trackHeight + _padding;
      laneTail[selectedLane] = ti;
    }

    for (final trackItem in visibleItems) {
      final lane = cache.laneOf[trackItem.index];
      if (lane == null) continue; // 未出生，先不画
      final x = _computeX(trackItem, size);
      if (x + trackItem.width < 0 || x > size.width) continue;
      // 轨道 Y 统一从 laneOf 恢复：_getTrackItem 每帧重建 startY=0，
      // 冻结弹幕（分配路径 continue 不设 startY）若直接用 startY 会全部
      // 叠在顶部第一轨 → 「只能看到一条 + 重叠 + 闪烁」。
      final offset = Offset(x, lane * _trackHeight + _padding);
      if (trackItem.stroke != null) {
        canvas.drawParagraph(trackItem.stroke!, offset);
      }
      canvas.drawParagraph(trackItem.fill, offset);
    }
  }

  /// 登记轨道占用——只保留「最近（time 最大）」的一条，作为新弹幕的冲突参照。
  void _recordOccupant(
      _DanmakuTrackItem ti,
      int lane,
      List<_DanmakuTrackItem?> scrollOccupant,
      List<_DanmakuTrackItem?> topOccupant,
      List<_DanmakuTrackItem?> bottomOccupant) {
    if (lane < 0 || lane >= scrollOccupant.length) return;
    final occ = _isBottom(ti.item.type)
        ? bottomOccupant
        : _isTop(ti.item.type)
            ? topOccupant
            : scrollOccupant;
    final cur = occ[lane];
    if (cur == null || ti.item.time > cur.item.time) occ[lane] = ti;
  }

  /// 给一条刚出生的弹幕挑轨道：优先无碰撞轨道；全满时选择最早释放轨道。
  int _assignLane(
      _DanmakuTrackItem ti,
      Size size,
      List<_DanmakuTrackItem?> scrollOccupant,
      List<_DanmakuTrackItem?> topOccupant,
      List<_DanmakuTrackItem?> bottomOccupant,
      int trackCount,
      {int maxLane = -1}) {
    final type = ti.item.type;
    // 固定弹幕（顶部/底部）独占 0..maxLane-1 轨道区（默认全池），
    // 与滚动弹幕分区互不重叠（滚动弹幕从 maxLane 起用）。
    final limit = maxLane > 0 ? maxLane : trackCount;
    if (type == 4 || type == 5) {
      final occ = type == 4 ? bottomOccupant : topOccupant;
      for (var i = 0; i < limit; i++) {
        final e = occ[i];
        // 固定弹幕停留 _topBottomDuration 秒，过了就腾出该轨。
        if (e == null || _currentSeconds - e.item.time > _topBottomDuration) {
          return i;
        }
      }
      var fallbackLane = 0;
      var earliestRelease = double.infinity;
      for (var i = 0; i < limit; i++) {
        final e = occ[i];
        if (e == null) return i;
        final release = e.item.time + _topBottomDuration;
        if (release < earliestRelease) {
          earliestRelease = release;
          fallbackLane = i;
        }
      }
      return fallbackLane;
    }
    // 滚动弹幕：优先找不会碰撞的轨道；全满时选择当前最早离开屏幕的轨道，
    // 不再把所有弹幕强压到最后一轨。
    final x = _computeX(ti, size);
    var fallbackLane = 0;
    var earliestRight = double.infinity;
    for (var i = 0; i < trackCount; i++) {
      final e = scrollOccupant[i];
      if (e == null) return i;
      final eRight = _computeX(e, size) + e.width;
      if (eRight < earliestRight) {
        earliestRight = eRight;
        fallbackLane = i;
      }
      if (x > eRight + _padding * 2) return i;
    }
    return fallbackLane;
  }

  /// 固定弹幕（顶部/底部，居中显示 5 秒）：
  /// B 站 4=底部/5=顶部；腾讯/爱奇艺/优酷 2=顶部/3=底部——统一兼容。
  static bool _isFixed(int type) =>
      type == 2 || type == 3 || type == 4 || type == 5;
  static bool _isTop(int type) => type == 2 || type == 5;
  static bool _isBottom(int type) => type == 3 || type == 4;
  /// 逆向滚动（B 站 mode 6：左→右）。
  static bool _isReverse(int type) => type == 6;

  double _computeX(_DanmakuTrackItem trackItem, Size size) {
    final type = trackItem.item.type;
    final elapsed = _currentSeconds - trackItem.item.time;

    if (_isFixed(type)) {
      // 固定弹幕（顶部/底部）只显示 _topBottomDuration 秒；过期返回屏外坐标，让
      // paint 里的裁剪（x > size.width）把它剔除。**必须与 _assignLane 腾出轨道的时机
      // 对齐**：否则画面寿命(_visibleWindow=30s) > 占用寿命(_topBottomDuration=5s)，
      // 5 秒后旧弹幕仍在画、轨道却被判空 → 新固定弹幕拿到同轨同居中坐标 → 精确重叠
      // （这就是「置顶弹幕互相覆盖不顺延」的根因）。对齐后固定弹幕在存活期内按轨道逐条顺延。
      if (elapsed > _topBottomDuration) return size.width + trackItem.width;
      return (size.width - trackItem.width) / 2;
    }

    final totalDuration =
        (size.width + trackItem.width + 2 * _padding) / _speed;
    final progress = elapsed / totalDuration;
    if (_isReverse(type)) {
      // 逆向滚动（B 站 mode 6）：从左侧进入、向右移动，与普通滚动方向相反。
      final startX = -trackItem.width - _padding;
      final endX = size.width + _padding;
      return startX + (endX - startX) * progress;
    }
    final startX = size.width + _padding;
    final endX = -trackItem.width - _padding;
    return startX + (endX - startX) * progress;
  }

  @override
  bool shouldRepaint(DanmakuPainter oldDelegate) {
    return oldDelegate.videoPosition != videoPosition ||
        !identical(oldDelegate.items, items) ||
        oldDelegate.fontSizeFactor != fontSizeFactor ||
        oldDelegate.speedFactor != speedFactor ||
        oldDelegate.densityFactor != densityFactor ||
        oldDelegate.displayArea != displayArea ||
        oldDelegate.stroke != stroke ||
        oldDelegate.fontFamily != fontFamily;
  }
}
