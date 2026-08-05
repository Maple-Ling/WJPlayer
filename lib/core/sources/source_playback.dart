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

  /// 详情页针对本次媒体选择的内核；null 使用全局默认。
  final String? playerCoreOverride;

  /// 按播放器实际轨道列表的位置选择音轨/字幕。飞牛详情页从 stream API 得到
  /// 同序列表并传入；播放器轨道就绪后再应用，避免起播阶段轨道尚为空。
  final int? preferredAudioListIndex;
  final int? preferredSubtitleListIndex;

  final String? seriesEntryId;

  /// 直链播放鉴权头（Authorization / Authx 等），由协议层传入。
  final Map<String, String>? httpHeaders;

  /// 外部媒体 Logo（TMDB 等），用于直链源播放页顶部；服务器源无 Logo 时为空。
  final String? logoUrl;

  const SourcePlayback({
    required this.server,
    required this.entry,
    this.qualityId,
    this.playerCoreOverride,
    this.preferredAudioListIndex,
    this.preferredSubtitleListIndex,
    this.seriesEntryId,
    this.httpHeaders,
    this.logoUrl,
    this.playlist = const [],
  });

  int get playlistIndex => playlist.indexWhere((item) => item.id == entry.id);

  SourcePlayback withEntry(SourceEntry next) => SourcePlayback(
        server: server,
        entry: next,
        qualityId: qualityId,
        playerCoreOverride: playerCoreOverride,
        preferredAudioListIndex: preferredAudioListIndex,
        preferredSubtitleListIndex: preferredSubtitleListIndex,
        seriesEntryId: seriesEntryId,
        httpHeaders: httpHeaders,
        logoUrl: logoUrl,
        playlist: playlist,
      );

  /// 供播放器内部记账/续播的稳定合成 itemId（不参与 Emby 上报）。
  String get syntheticItemId => 'src:${server.id}:${entry.id}';

  /// 构造来源播放媒体项，供标题、弹幕匹配及跨服务器本地播放记录使用。
  MediaItem toMediaItem({int? runTimeTicks}) {
    final raw = entry.raw ?? const <String, dynamic>{};
    final rawType = '${raw['type'] ?? ''}'.toLowerCase();
    final isEpisode = rawType == 'episode';
    final providerIds = <String, String>{};
    for (final pair in [
      ('tmdb', raw['tmdb_id'] ?? raw['tmdb']),
      ('imdb', raw['imdb_id'] ?? raw['imdb']),
      ('douban', raw['douban_id'] ?? raw['douban']),
    ]) {
      final value = pair.$2?.toString().trim() ?? '';
      if (value.isNotEmpty) providerIds[pair.$1] = value;
    }
    final seriesId = seriesEntryId ??
        (raw['series_guid'] ?? raw['tv_guid'] ?? raw['parent_guid'])?.toString();
    return MediaItem(
      id: syntheticItemId,
      name: entry.name,
      type: isEpisode ? 'Episode' : 'Movie',
      mediaType: 'Video',
      providerIds: providerIds,
      path: entry.id,
      seriesName: (raw['series_title'] ?? raw['tv_title'])?.toString(),
      seriesId: seriesId,
      parentIndexNumber: (raw['season_number'] as num?)?.toInt(),
      indexNumber: (raw['episode_number'] as num?)?.toInt(),
      productionYear: int.tryParse('${raw['year'] ?? ''}'),
      runTimeTicks: runTimeTicks,
    );
  }
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
}) resolveSourcePlayerConfig(WidgetRef ref, {String? coreOverride}) {
  final coreString =
      normalizePlayerCore(coreOverride ?? ref.read(playerCoreProvider));
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
    useLibass: coreType == PlayerCoreType.exoPlayer
        ? ref.read(exoLibassProvider)
        : false,
    useGpuNext: useGpuNext,
    surfaceViewId: coreType == PlayerCoreType.nativeMpv
        ? DateTime.now().microsecondsSinceEpoch
        : null,
  );
}
