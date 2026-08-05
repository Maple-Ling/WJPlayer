import 'package:flutter/material.dart';

class PlaybackResourceCard extends StatelessWidget {
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
  final int? size;
  final int? bitrate;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  String _text(String? value, String fallback) =>
      value == null || value.trim().isEmpty ? fallback : value.trim();

  String _sizeText() {
    final value = size ?? 0;
    if (value <= 0) return '大小未知';
    if (value >= 1073741824) return '${(value / 1073741824).toStringAsFixed(1)} GB';
    return '${(value / 1048576).toStringAsFixed(1)} MB';
  }

  String _bitrateText() {
    final value = bitrate ?? 0;
    if (value <= 0) return '码率未知';
    return '${(value / 1000000).toStringAsFixed(1)} Mbps';
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    Widget tag(String value, {Color? color, Color? background}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: background ?? Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
            border: color == null ? null : Border.all(color: color),
          ),
          child: Text(value, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
        );
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected
            ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2.5)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              SizedBox(width: 24, height: 24, child: serverIcon ?? const Icon(Icons.dns_rounded, size: 20)),
              const SizedBox(width: 8),
              Expanded(child: Text(serverName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800))),
              if (isBest) tag('最佳资源', color: const Color(0xFF6B4F00), background: const Color(0xFFFFD66B))
              else if (isCurrent) tag('当前资源', color: const Color(0xFF238B57)),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              tag(_text(resolution, '分辨率未知')),
              tag(_text(dynamicRange, 'SDR')),
              tag(_text(codec, '编码未知')),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Icon(Icons.storage_rounded, size: 15, color: muted),
              const SizedBox(width: 4),
              Text(_sizeText(), style: TextStyle(fontSize: 11, color: muted)),
              const Spacer(),
              Icon(Icons.speed_rounded, size: 15, color: muted),
              const SizedBox(width: 4),
              Text(_bitrateText(), style: TextStyle(fontSize: 11, color: muted)),
            ]),
          ]),
        ),
      ),
    );
  }
}
