import 'package:flutter/material.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/sources/feiniu_backend.dart';
import '../../../core/sources/unified_media_adapter.dart';

/// 跨服匹配胶囊信息（统一解析入口）。
///
/// 数据源优先级（与详情页底部媒体信息同源，保证「能识别的一定显示」）：
/// - Emby：完整媒体详情（ServerMatchInfo.mediaSource ← getItemMediaSources），
///   缺失回退搜索摘要（item.mediaSources）；
/// - 飞牛：完整媒体详情（ServerMatchInfo.feiniuDetails ← mediaDetails，
///   video/file 为归一化 key，与详情页底部 _buildStreamInfoCards 完全一致），
///   缺失回退搜索摘要。
class MatchPlaybackInfo {
  const MatchPlaybackInfo({
    this.resolution,
    this.dynamicRange,
    this.codec,
    this.size,
    this.bitrate,
    this.frameRate,
  });

  final String? resolution;
  final String? dynamicRange;
  final String? codec;
  final int? size;
  final int? bitrate;
  final String? frameRate;
}

MatchPlaybackInfo matchPlaybackInfo(ServerMatchInfo match) {
  // ① Emby 完整媒体详情（或任意 MediaSource 摘要）。
  final ms = match.mediaSource ?? match.item.mediaSources?.firstOrNull;
  if (ms != null) {
    final v = ms.primaryVideoStream;
    return MatchPlaybackInfo(
      resolution: ms.qualityLabel,
      dynamicRange: v?.videoRangeLabel,
      codec: v?.videoCodecLabel,
      size: ms.size,
      bitrate: v?.bitRate,
      frameRate: v?.realFrameRate == null ? null : _frameRateLabel(v!.realFrameRate!),
    );
  }
  // ② 飞牛完整媒体详情：一律先经 normalizeMediaStream 归一化，与详情页底部
  // 媒体信息（_buildStreamInfoCards）、播放器媒体信息菜单完全同一套 key，
  // 保证 bit_rate/hdr_type/fps/file_size 等协议变体字段不因命名差异而漏显；
  // HDR 判定叠加 color_transfer 线索（bt2020/smpte2084/arib-std-b67 → HDR，
  // bt709 → SDR），编码识别覆盖 HEVC/H.264/AV1/VP9/MPEG 等。
  final details = match.feiniuDetails;
  if (details != null) {
    final v = normalizeMediaStream(details.video);
    final f = normalizeMediaStream(details.file);
    return MatchPlaybackInfo(
      resolution: _qualityFromSize(v['width'], v['height']),
      dynamicRange: _hdrFromValue(v['video_range_type'] ??
          v['video_range'] ??
          v['color_transfer']),
      codec: _codecFromValue(v['codec_name']),
      size: _intOf(f['size']),
      bitrate: _intOf(v['bitrate']),
      frameRate: _frameRateLabel(
          _intOf(v['real_frame_rate'] ?? v['average_frame_rate'])
              ?.toDouble()),
    );
  }
  // ③ 搜索摘要也未携带：全部占位（组件显示「未知」）。
  return const MatchPlaybackInfo();
}

/// 帧率格式化（与详情页底部 / 播放器媒体信息菜单同款）：常见帧率归一为
/// "23.976 fps" / "24 fps" / "60 fps"，其余保留两位小数去尾零。
String? _frameRateLabel(double? rate) {
  if (rate == null || rate <= 0) return null;
  final common = <double, String>{
    23.976: '23.976 fps',
    24: '24 fps',
    25: '25 fps',
    30: '30 fps',
    48: '48 fps',
    50: '50 fps',
    59.94: '59.94 fps',
    60: '60 fps',
    120: '120 fps',
  };
  for (final entry in common.entries) {
    if ((rate - entry.key).abs() < 0.001) return entry.value;
  }
  final value = double.parse(rate.toStringAsFixed(2));
  return '$value fps';
}

/// 宽度/高度主导分档（与 Emby MediaStream.resolution 同款逻辑）。
String? _qualityFromSize(Object? width, Object? height) {
  final w = _intOf(width) ?? 0;
  final h = _intOf(height) ?? 0;
  if (w <= 0 && h <= 0) return null;
  if (w >= 7600 || h >= 4300) return '8K';
  if (w >= 3600 || h >= 2000) return '4K';
  if (w >= 1800 || h >= 1000) return '1080p';
  if (w >= 1200 || h >= 700) return '720p';
  if (w >= 640 || h >= 480) return '480p';
  if (h > 0) return '${h}p';
  return null;
}

/// 编码规范化（与 Emby MediaStream.videoCodecLabel 同款映射）。
String? _codecFromValue(Object? codec) {
  final c = (codec?.toString() ?? '').toLowerCase();
  if (c.isEmpty) return null;
  if (c.contains('hevc') || c.contains('h265') || c.contains('h.265')) {
    return 'HEVC';
  }
  if (c.contains('avc') || c.contains('h264') || c.contains('h.264')) {
    return 'H.264';
  }
  if (c.contains('av1')) return 'AV1';
  if (c.contains('vp9')) return 'VP9';
  if (c.contains('vp8')) return 'VP8';
  if (c.contains('mpeg4')) return 'MPEG-4';
  if (c.contains('mpeg2')) return 'MPEG-2';
  if (c.contains('vc1') || c.contains('vc-1')) return 'VC-1';
  return c.toUpperCase();
}

/// HDR/动态范围规范化（与 Emby MediaStream.videoRangeLabel 同款映射）。
/// 输入统一为 normalizeMediaStream 之后的 key（video_range_type/video_range/
/// color_transfer），覆盖：Dolby Vision / HDR10+ / HDR10 / HLG / PQ / HDR，
/// 并把 bt709 等 SDR 色彩传输排除（返回 null → 组件显示「SDR」）。
String? _hdrFromValue(Object? range) {
  final raw = (range?.toString() ?? '').toLowerCase();
  if (raw.isEmpty) return null;
  // SDR 色彩传输/范围：明确排除，不显示为伪 HDR。
  if (raw.contains('bt709') ||
      raw.contains('smpte170') ||
      raw.contains('bt601') ||
      raw.contains('bt470') ||
      raw == 'sdr' ||
      raw == 'none' ||
      raw == 'n/a') {
    return null;
  }
  // 杜比视界：dv / dovi / dvhe / dvav（含 color_transfer='dovi' 形态）。
  if (raw.contains('dovi') || raw.contains('dvhe') || raw.contains('dvav') ||
      raw == 'dv') {
    return 'Dolby Vision';
  }
  if (raw.contains('hdr10plus') || raw.contains('hdr10+')) return 'HDR10+';
  if (raw.contains('hdr10')) return 'HDR10';
  if (raw.contains('hlg') || raw.contains('arib-std-b67')) return 'HLG';
  // PQ / ST.2084（HDR 传递函数）与 BT.2020（HDR 广色域）→ 泛 HDR。
  if (raw.contains('pq') || raw.contains('smpte2084') ||
      raw.contains('smpte2086') || raw.contains('bt2020')) {
    return 'HDR';
  }
  if (raw.contains('hdr')) return 'HDR';
  return null; // 未知色彩传输一律不冒充 HDR
}

int? _intOf(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse('$value');
}

class PlaybackResourceCard extends StatefulWidget {
  const PlaybackResourceCard({
    super.key,
    required this.serverName,
    this.serverIcon,
    this.isCurrent = false,
    this.isSelected = false,
    this.isBest = false,
    this.resolution,
    this.dynamicRange,
    this.codec,
    this.frameRate,
    this.size,
    this.bitrate,
    this.onTap,
    this.onDoubleTap,
  });

  final String serverName;
  final Widget? serverIcon;
  final bool isCurrent;
  final bool isSelected;
  final bool isBest;
  final String? resolution;
  final String? dynamicRange;
  final String? codec;
  final String? frameRate;
  final int? size;
  final int? bitrate;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  @override
  State<PlaybackResourceCard> createState() => _PlaybackResourceCardState();
}

class _PlaybackResourceCardState extends State<PlaybackResourceCard> {
  // 轻点/双击判定（原始指针事件，无手势竞技场延迟）：
  // InkWell 同时挂 onTap+onDoubleTap 时单击需等双击超时(~300ms)，不跟手。
  Offset _downPosition = Offset.zero;
  DateTime _downTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastTapTime;

  void _onPointerDown(PointerDownEvent event) {
    _downPosition = event.position;
    _downTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent event) {
    final now = DateTime.now();
    if (now.difference(_downTime) > const Duration(milliseconds: 300) ||
        (event.position - _downPosition).distance > 20) {
      return; // 长按/滚动拖动不算轻点
    }
    // 300ms 内两次轻点 = 双击（不触发单击，走 onDoubleTap）。
    if (_lastTapTime != null &&
        now.difference(_lastTapTime!) < const Duration(milliseconds: 300)) {
      _lastTapTime = null;
      widget.onDoubleTap?.call();
      return;
    }
    _lastTapTime = now;
    widget.onTap?.call(); // 单击：立即触发（跟手）
  }

  String _text(String? value, String fallback) =>
      value == null || value.trim().isEmpty ? fallback : value.trim();

  String _sizeText() {
    final value = widget.size ?? 0;
    if (value <= 0) return '大小未知';
    if (value >= 1073741824) {
      return '${(value / 1073741824).toStringAsFixed(1)} GB';
    }
    return '${(value / 1048576).toStringAsFixed(1)} MB';
  }

  String _bitrateText() {
    final value = widget.bitrate ?? 0;
    if (value <= 0) return '码率未知';
    return '${(value / 1000000).toStringAsFixed(1)} Mbps';
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    Widget tag(String value, {Color? color, Color? background}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: background ??
                Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
            border: color == null ? null : Border.all(color: color),
          ),
          child: Text(value,
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: color)),
        );
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      child: Card(
        clipBehavior: Clip.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: widget.isSelected
              ? BorderSide(
                  color: Theme.of(context).colorScheme.primary, width: 2.5)
              : BorderSide.none,
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: InkWell(
            // 空 onTap 仅提供按下涟漪（down 即显示）；实际单击/双击由外层
            // Listener 原始事件判定并立即回调，避免双击等待延迟。
            onTap: () {},
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      SizedBox(
                          width: 24,
                          height: 24,
                          child: widget.serverIcon ??
                              const Icon(Icons.dns_rounded, size: 20)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(widget.serverName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800))),
                      if (widget.isBest)
                        tag('最佳资源',
                            color: const Color(0xFF6B4F00),
                            background: const Color(0xFFFFD66B))
                      else if (widget.isCurrent)
                        tag('当前资源', color: const Color(0xFF238B57)),
                    ]),
                    const SizedBox(height: 10),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      tag(_text(widget.resolution, '分辨率未知')),
                      tag(_text(widget.dynamicRange, 'SDR')),
                      tag(_text(widget.codec, '编码未知')),
                      if (widget.frameRate?.isNotEmpty == true)
                        tag(widget.frameRate!),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Icon(Icons.storage_rounded, size: 15, color: muted),
                      const SizedBox(width: 4),
                      Text(_sizeText(),
                          style: TextStyle(fontSize: 11, color: muted)),
                      const Spacer(),
                      Icon(Icons.speed_rounded, size: 15, color: muted),
                      const SizedBox(width: 4),
                      Text(_bitrateText(),
                          style: TextStyle(fontSize: 11, color: muted)),
                    ]),
                  ]),
            ),
          ),
        ),
      ),
    );
  }
}
