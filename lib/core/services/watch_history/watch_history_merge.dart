import 'watch_history_matcher.dart';
import 'watch_history_models.dart';

/// 记录页合并分组 key：同一电影 / 同一电视剧（跨服务器、跨分集）归为一组。
///
/// - 电影：TMDB ID 优先，缺失时按标题（归一化）+ 年份；两者都缺回退 canonicalKey。
/// - 剧集：系列 TMDB ID 优先，缺失时按系列标题（归一化）；两者都缺回退 canonicalKey。
///   注意**不包含季/集号**——同一部剧的所有分集（无论哪一季哪一集）只允许一条记录。
String watchHistoryMergeGroupKey(WatchHistoryRecord record) {
  if (record.mediaKind == WatchHistoryMediaKind.movie) {
    final tmdb = record.tmdbId?.trim();
    if (tmdb != null && tmdb.isNotEmpty) {
      return 'movie:tmdb:$tmdb';
    }
    final title = normalizeWatchHistoryText(record.title);
    if (title.isNotEmpty) {
      return 'movie:title:$title:${record.year ?? 'unknown'}';
    }
    return 'movie:key:${record.canonicalKey}';
  }
  final seriesTmdb = record.seriesTmdbId?.trim();
  if (seriesTmdb != null && seriesTmdb.isNotEmpty) {
    return 'series:tmdb:$seriesTmdb';
  }
  final seriesTitle = normalizeWatchHistoryText(record.seriesTitle ?? '');
  if (seriesTitle.isNotEmpty) {
    return 'series:title:$seriesTitle';
  }
  return 'series:key:${record.canonicalKey}';
}

/// 合并同一媒体多条播放记录：每组取 [WatchHistoryRecord.lastPlayedAt] 最新者
/// 为代表（最新播放记录 + 最新播放服务器），返回按最近播放时间倒序的列表。
List<WatchHistoryRecord> mergeWatchHistoryRecords(
  List<WatchHistoryRecord> records,
) {
  final representatives = <String, WatchHistoryRecord>{};
  for (final record in records) {
    final key = watchHistoryMergeGroupKey(record);
    final current = representatives[key];
    if (current == null ||
        record.lastPlayedAt.isAfter(current.lastPlayedAt)) {
      representatives[key] = record;
    }
  }
  final merged = representatives.values.toList(growable: false);
  merged
      .sort((left, right) => right.lastPlayedAt.compareTo(left.lastPlayedAt));
  return merged;
}
