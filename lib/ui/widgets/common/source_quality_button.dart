import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_playback.dart';

/// 网盘转码源（夸克等）播放内的「清晰度」按钮。
///
/// 读取 [sourcePlayQualitiesProvider] / [sourceSelectedQualityProvider]：仅当有
/// 2 档及以上可选时显示。点击弹出选择面板，回调 [onSelect] 按新档重解析续播。
/// 三端（移动 / 桌面 / TV）共用。
class SourceQualityButton extends ConsumerWidget {
  final void Function(String qualityId) onSelect;

  const SourceQualityButton({super.key, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final qualities = ref.watch(sourcePlayQualitiesProvider);
    final selectedId = ref.watch(sourceSelectedQualityProvider);
    if (qualities.length < 2) return const SizedBox.shrink();
    final current = qualities.firstWhere(
      (q) => q.id == selectedId,
      orElse: () => qualities.first,
    );
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _pick(context, qualities, current),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.high_quality_rounded,
                  color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Text(current.label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context, List<PlayQuality> qualities,
      PlayQuality current) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('选择清晰度',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
              ),
            ),
            for (final q in qualities)
              ListTile(
                leading: Icon(
                  q.id == current.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: q.id == current.id
                      ? const Color(0xFF5B8DEF)
                      : Colors.white54,
                ),
                title: Text(q.label,
                    style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.of(ctx).pop(q.id),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null && picked != current.id) onSelect(picked);
  }
}
