import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_interfaces.dart';
import '../providers/playback_providers.dart';
import '../providers/server_providers.dart';
import '../services/video_player_service.dart';
import 'media_source_backend.dart';

/// 网盘 / 聚合源「直链播放」的导航载荷。
///
/// 关键设计：**复用各端已适配好的完整 [PlayerScreen]**（弹幕 / 字幕轨 / 手势 /
/// 倍速 / 比例 / 续播…）来播放网盘直链，而不是另起一个残血播放页。经 go_router 的
/// `extra` 传入（含 server / entry，不走 path）。
class SourcePlayback {
  final ServerConfig server;
  final SourceEntry entry;

  /// 用户选定的清晰度档（夸克等转码源）；null = 后端默认（约定选最高档）。
  final String? qualityId;

  const SourcePlayback({
    required this.server,
    required this.entry,
    this.qualityId,
  });

  /// 供播放器内部记账/续播的稳定合成 itemId（不参与 Emby 上报）。
  String get syntheticItemId => 'src:${server.id}:${entry.id}';

  /// 构造一个最简 [MediaItem] 给 currentPlayingItemProvider（标题展示 / 弹幕匹配用）。
  MediaItem toMediaItem() => MediaItem(
        id: syntheticItemId,
        name: entry.name,
        type: 'Video',
        mediaType: 'Video',
      );
}

/// 当前源播放可选的全部清晰度档（无则空）。供播放内「清晰度」按钮读取。
final sourcePlayQualitiesProvider =
    StateProvider<List<PlayQuality>>((ref) => const []);

/// 当前源播放选中的清晰度档 id（null = 默认/最高）。
final sourceSelectedQualityProvider = StateProvider<String?>((ref) => null);

/// 文件浏览展示模式：false = 条形列表，true = 封面网格。三端共用、可切换。
final sourceBrowseGridProvider = StateProvider<bool>((ref) => false);

/// 文件浏览排序方式。
enum SourceSortMode { nameAsc, nameDesc, sizeDesc, sizeAsc }

extension SourceSortModeLabel on SourceSortMode {
  String get label => switch (this) {
        SourceSortMode.nameAsc => '名称 ↑',
        SourceSortMode.nameDesc => '名称 ↓',
        SourceSortMode.sizeDesc => '大小 ↓',
        SourceSortMode.sizeAsc => '大小 ↑',
      };
}

/// 当前浏览排序方式。三端共用、可切换。
final sourceBrowseSortProvider =
    StateProvider<SourceSortMode>((ref) => SourceSortMode.nameAsc);

/// 按 [mode] 排序文件项：文件夹始终在前，组内按名称/大小升降序。
List<SourceEntry> sortSourceEntries(
    List<SourceEntry> entries, SourceSortMode mode) {
  final out = [...entries];
  out.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    switch (mode) {
      case SourceSortMode.nameAsc:
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case SourceSortMode.nameDesc:
        return b.name.toLowerCase().compareTo(a.name.toLowerCase());
      case SourceSortMode.sizeDesc:
        return (b.size ?? 0).compareTo(a.size ?? 0);
      case SourceSortMode.sizeAsc:
        return (a.size ?? 0).compareTo(b.size ?? 0);
    }
  });
  return out;
}

/// 解析当前内核 / 解码设置，供「源直链播放」统一构建（三端口径一致）。
({
  PlayerCoreType coreType,
  bool hardwareDecoding,
  bool useLibass,
  bool useGpuNext,
  int? surfaceViewId,
}) resolveSourcePlayerConfig(WidgetRef ref) {
  final coreString = normalizePlayerCore(ref.read(playerCoreProvider));
  final coreType = switch (coreString) {
    'mpv' => PlayerCoreType.mpv,
    'nativeMpv' => PlayerCoreType.nativeMpv,
    _ => PlayerCoreType.exoPlayer,
  };
  final useGpuNext =
      coreType == PlayerCoreType.nativeMpv && ref.read(gpuNextEnabledProvider);
  return (
    coreType: coreType,
    hardwareDecoding: ref.read(hardwareDecodingProvider),
    useLibass:
        coreType == PlayerCoreType.exoPlayer ? ref.read(exoLibassProvider) : false,
    useGpuNext: useGpuNext,
    surfaceViewId: coreType == PlayerCoreType.nativeMpv
        ? DateTime.now().microsecondsSinceEpoch
        : null,
  );
}
