import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/server_providers.dart';
import '../sources/feiniu_backend.dart';
import '../sources/source_kind.dart';
import 'watch_history_providers.dart';

class ServerCardStats {
  const ServerCardStats({
    this.movieCount,
    this.seriesCount,
    this.episodeCount,
    this.lastWatchedAt,
    this.error,
  });

  final int? movieCount;
  final int? seriesCount;
  final int? episodeCount;
  final DateTime? lastWatchedAt;
  final Object? error;

  bool get loading => movieCount == null && seriesCount == null && episodeCount == null && error == null;
}

/// 成功结果缓存时长：10 分钟内复用（避免每次进列表都并发请求所有服务器），
/// 超过即重新拉取（打开软件/下拉刷新能看到最新影视数量）。
const _statsTtl = Duration(minutes: 10);

class _CachedStats {
  final ServerCardStats stats;
  final DateTime savedAt;
  const _CachedStats(this.stats, this.savedAt);
}

final _serverStatsCache = <String, _CachedStats>{};
final _serverStatsPending = <String, Future<ServerCardStats>>{};

/// 每次应用启动时调用：清空服务器卡片统计缓存，下次进入服务器列表
/// 重新拉取影视数量（打开软件即刷新；会话内由 [_statsTtl] 防抖复用）。
void resetServerStatsCache() {
  _serverStatsCache.clear();
}

final serverCardStatsProvider = FutureProvider.family<ServerCardStats, String>((ref, serverId) async {
  final cached = _serverStatsCache[serverId];
  if (cached != null) {
    // 成功结果 TTL 内复用；失败结果不缓存（下方 remove），
    // 下次进入/下拉刷新立即重新拉取，杜绝「永远显示旧数量/空数量」。
    if (DateTime.now().difference(cached.savedAt) < _statsTtl) {
      return cached.stats;
    }
    _serverStatsCache.remove(serverId);
  }
  final pending = _serverStatsPending[serverId];
  if (pending != null) return pending;

  final future = _loadServerCardStats(ref, serverId);
  _serverStatsPending[serverId] = future;
  try {
    final result = await future;
    // 失败不缓存：网络/CDN 链路恢复后自动刷新出数量。
    if (result.error == null) {
      _serverStatsCache[serverId] = _CachedStats(result, DateTime.now());
    }
    return result;
  } finally {
    _serverStatsPending.remove(serverId);
  }
});

Future<ServerCardStats> _loadServerCardStats(
    Ref ref, String serverId) async {
  final server = ref.watch(serverListProvider).where((item) => item.id == serverId).firstOrNull;
  if (server == null) return const ServerCardStats(error: '服务器不存在');

  DateTime? lastWatchedAt;
  final scopeKey = buildWatchHistoryScopeKey(server);
  if (scopeKey != null) {
    final records = await ref.read(watchHistoryProvider).loadAll();
    lastWatchedAt = records
        .where((record) => record.scopeKey == scopeKey)
        .map((record) => record.lastPlayedAt)
        .fold<DateTime?>(null, (latest, value) => latest == null || value.isAfter(latest) ? value : latest);
  }

  try {
    if (server.sourceKind == SourceKind.emby) {
      final counts = await ref.read(serverApiClientProvider(server.id))!.home.getMediaCounts();
      return ServerCardStats(movieCount: counts.movieCount, seriesCount: counts.seriesCount, episodeCount: counts.episodeCount, lastWatchedAt: lastWatchedAt);
    }
    if (server.sourceKind == SourceKind.feiniu) {
      final stats = await FeiniuBackend().mediaCounts(server);
      return ServerCardStats(movieCount: stats.movieCount, seriesCount: stats.seriesCount, episodeCount: stats.episodeCount, lastWatchedAt: lastWatchedAt);
    }
  } catch (error) {
    return ServerCardStats(lastWatchedAt: lastWatchedAt, error: error);
  }
  return ServerCardStats(lastWatchedAt: lastWatchedAt);
}
