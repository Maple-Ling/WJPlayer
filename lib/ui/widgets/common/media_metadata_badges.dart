import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/api/discover/discover_models.dart';
import '../../../core/providers/discover_providers.dart';

class SelectedRatingBadge extends ConsumerWidget {
  const SelectedRatingBadge(
      {super.key, required this.item, this.compact = true});
  final MediaItem item;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(reviewSourceProvider);
    final rating = ref.watch(selectedExternalRatingProvider(item));
    return rating.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (value) {
        if (value == null || value <= 0) return const SizedBox.shrink();
        return Container(
          padding: EdgeInsets.symmetric(
              horizontal: compact ? 6 : 9, vertical: compact ? 3 : 5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.76),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.star_rounded,
                  size: 13, color: Color(0xFFFFC107)),
              const SizedBox(width: 2),
              Text(
                '${source.label} ${value.toStringAsFixed(1)}',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 10 : 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class MediaFormatBadges extends StatelessWidget {
  const MediaFormatBadges({super.key, required this.sources, this.max = 3});
  final List<MediaSource>? sources;
  final int max;

  @override
  Widget build(BuildContext context) {
    final labels = mediaFormatLabels(sources).take(max).toList();
    if (labels.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      alignment: WrapAlignment.end,
      children: [
        for (final label in labels)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.76),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700)),
          ),
      ],
    );
  }
}

List<String> mediaFormatLabels(List<MediaSource>? sources) {
  if (sources == null || sources.isEmpty) return const [];
  final labels = <String>[];
  for (final source in sources) {
    final video = source.primaryVideoStream;
    if (video == null) continue;
    final range = video.videoRangeLabel.isEmpty
        ? 'SDR'
        : _shortRange(video.videoRangeLabel);
    final codec = _shortCodec(video.videoCodecLabel);
    final label = [range, codec].where((value) => value.isNotEmpty).join(' · ');
    if (label.isNotEmpty && !labels.contains(label)) labels.add(label);
  }
  return labels;
}

String _shortRange(String value) => switch (value) {
      'Dolby Vision' => 'DV',
      _ => value,
    };

String _shortCodec(String value) => switch (value) {
      'H.264' => '264',
      'HEVC' => '265/HEVC',
      _ => value,
    };
