import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/anirss/anirss_providers.dart';
import '../../widgets/anirss/anirss_add_subscription_body.dart';

/// 弹出「添加订阅」面板（多搜索源：BGM / Mikan 季度 / AniBT / AnimeGarden / 自定义 RSS，
/// 支持添加前 previewAni 预览匹配剧集）。
Future<void> showAniRssAddSubscriptionSheet(
    BuildContext context, WidgetRef ref) {
  final api = ref.read(aniRssApiProvider);
  if (api == null) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
      ),
      child: SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.72,
        child: AniRssAddSubscriptionBody(
          api: api,
          parentRef: ref,
          onAdded: () => Navigator.of(sheetContext).pop(),
        ),
      ),
    ),
  );
}
