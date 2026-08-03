import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/server_providers.dart';
import 'media_widgets.dart';

/// 聚合搜索里「一台服务器一组」的组头：左上角服务器图标 + 服务器名。
/// 移动端 / 桌面端共用（都是 Material 体系）。TV 端自绘（另一套设计 token）。
class ServerGroupHeader extends ConsumerWidget {
  const ServerGroupHeader({
    super.key,
    required this.serverId,
    required this.serverName,
    this.iconSize = 26,
  });

  /// 结果来源服务器 id（取自 MediaItem.sourceServerId），用于查图标。
  final String? serverId;
  final String serverName;
  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String? iconUrl;
    if (serverId != null) {
      for (final s in ref.watch(serverListProvider)) {
        if (s.id == serverId) {
          iconUrl = s.iconUrl;
          break;
        }
      }
    }
    final theme = Theme.of(context);
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: iconSize,
            height: iconSize,
            child: iconUrl != null
                ? MediaImage(
                    imageUrl: iconUrl,
                    width: iconSize,
                    height: iconSize,
                    fit: BoxFit.contain,
                    useDefaultUserAgent: true,
                    errorWidget: const EmbyDefaultIcon(),
                  )
                : const EmbyDefaultIcon(),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            serverName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
