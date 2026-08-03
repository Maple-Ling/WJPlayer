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

final _serverStatsCache = <String, ServerCardStats>{};
final _serverStatsPending = <String, Future<ServerCardStats>>{};

final serverCardStatsProvider = FutureProvider.family<ServerCardStats, String>((ref, serverId) async {
  final cached = _serverStatsCache[serverId];
  if (cached != null) return cached;
  final pending = _serverStatsPending[serverId];
  if (pending != null) return pending;

  final future = _loadServerCardStats(ref, serverId);
  _serverStatsPending[serverId] = future;
  try {
    final result = await future;
    _serverStatsCache[serverId] = result;
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
