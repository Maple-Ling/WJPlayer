import 'dart:ui' as ui;
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';
import '../../../core/api/api_interfaces.dart';

class DanmakuOverlay extends StatefulWidget {
  final List<DanmakuItem> items;
  final Duration position;
  final bool isPlaying;
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

  /// 段落缓存随 State 存活（跨帧持久），替代旧的 static 缓存（跨实例共享是隐患）。
  final DanmakuLayoutCache _cache = DanmakuLayoutCache();

  @override
  void initState() {
    super.initState();
    _smoothPosition = widget.position;
    _lastSyncPosition = widget.position;
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    _tickerElapsed = elapsed;
    if (!widget.isPlaying) return;
    final delta = elapsed - _lastSyncElapsed;
    _smoothPosition = _lastSyncPosition + delta;
    setState(() {});
  }

  @override
  void didUpdateWidget(DanmakuOverlay old) {
    super.didUpdateWidget(old);
    if (widget.position != old.position) {
      _lastSyncPosition = widget.position;
      _lastSyncElapsed = _tickerElapsed;
      _smoothPosition = widget.position;
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
  static const double _trackHeight = 32.0;
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

    final usableHeight = size.height * displayArea.clamp(0.1, 1.0);
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

    // 轨道占用：每条轨道记录「最近一条」占用者，用于给新弹幕挑不冲突的轨道。
    // 滚动/顶部/底部三类各自一套轨道。
    final scrollOccupant = List<_DanmakuTrackItem?>.filled(trackCount, null);
    final topOccupant = List<_DanmakuTrackItem?>.filled(trackCount, null);
    final bottomOccupant = List<_DanmakuTrackItem?>.filled(trackCount, null);

    // Pass 1：已分配轨道的弹幕直接复用冻结轨道号（不再重算 → 不抖动），并登记占用。
    final unassigned = <_DanmakuTrackItem>[];
    for (final ti in visibleItems) {
      final lane = cache.laneOf[ti.index];
      if (lane == null) {
        unassigned.add(ti);
        continue;
      }
      ti.startY = lane * _trackHeight + _padding;
      _recordOccupant(ti, lane, scrollOccupant, topOccupant, bottomOccupant);
    }

    // Pass 2：给尚未分配、且已经「出生」（当前时间到点）的弹幕分配轨道并冻结。
    // 未到点的（time>当前）先不分配——等它真正从右侧进场那一帧再挑轨道，避免扎堆。
    unassigned.sort((a, b) => a.item.time.compareTo(b.item.time));
    for (final ti in unassigned) {
      if (ti.item.time > _currentSeconds) continue;
      final lane = _assignLane(
          ti, size, scrollOccupant, topOccupant, bottomOccupant, trackCount);
      cache.laneOf[ti.index] = lane;
      ti.startY = lane * _trackHeight + _padding;
      _recordOccupant(ti, lane, scrollOccupant, topOccupant, bottomOccupant);
    }

    for (final trackItem in visibleItems) {
      if (!cache.laneOf.containsKey(trackItem.index)) continue; // 未出生，先不画
      final x = _computeX(trackItem, size);
      if (x + trackItem.width < 0 || x > size.width) continue;
      final offset = Offset(x, trackItem.startY);
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
    final occ = ti.item.type == 4
        ? bottomOccupant
        : ti.item.type == 5
            ? topOccupant
            : scrollOccupant;
    final cur = occ[lane];
    if (cur == null || ti.item.time > cur.item.time) occ[lane] = ti;
  }

  /// 给一条刚出生的弹幕挑轨道：找第一条与当前占用者不冲突的轨道；实在没有就压到最后一轨。
  int _assignLane(
      _DanmakuTrackItem ti,
      Size size,
      List<_DanmakuTrackItem?> scrollOccupant,
      List<_DanmakuTrackItem?> topOccupant,
      List<_DanmakuTrackItem?> bottomOccupant,
      int trackCount) {
    final type = ti.item.type;
    if (type == 4 || type == 5) {
      final occ = type == 4 ? bottomOccupant : topOccupant;
      for (var i = 0; i < trackCount; i++) {
        final e = occ[i];
        // 固定弹幕停留 _topBottomDuration 秒，过了就腾出该轨。
        if (e == null || _currentSeconds - e.item.time > _topBottomDuration) {
          return i;
        }
      }
      return trackCount - 1;
    }
    // 滚动弹幕：同速前进，出生时不与占用者重叠则永不重叠。
    final x = _computeX(ti, size);
    for (var i = 0; i < trackCount; i++) {
      final e = scrollOccupant[i];
      if (e == null) return i;
      final eRight = _computeX(e, size) + e.width;
      if (x > eRight + _padding * 2) return i;
    }
    return trackCount - 1;
  }

  double _computeX(_DanmakuTrackItem trackItem, Size size) {
    final type = trackItem.item.type;
    final elapsed = _currentSeconds - trackItem.item.time;
    if (elapsed < 0) return -trackItem.width;

    if (type == 4 || type == 5) {
      // 固定弹幕（顶部/底部）只显示 _topBottomDuration 秒；过期返回屏外坐标，让
      // paint 里的裁剪（x > size.width）把它剔除。**必须与 _assignLane 腾出轨道的时机
      // 对齐**：否则画面寿命(_visibleWindow=30s) > 占用寿命(_topBottomDuration=5s)，
      // 5 秒后旧弹幕仍在画、轨道却被判空 → 新固定弹幕拿到同轨同居中坐标 → 精确重叠
      // （这就是「置顶弹幕互相覆盖不顺延」的根因）。对齐后固定弹幕在存活期内按轨道逐条顺延。
      if (elapsed > _topBottomDuration) return size.width + trackItem.width;
      return (size.width - trackItem.width) / 2;
    }

    final totalDuration = size.width / _speed + trackItem.width / _speed;
    final progress = elapsed / totalDuration;
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
