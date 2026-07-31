import 'package:path/path.dart' as p;

import '../../api/api_interfaces.dart';
import 'watch_history_models.dart';

class WatchHistoryFingerprint {
  const WatchHistoryFingerprint({
    required this.mediaKind,
    required this.canonicalKey,
    required this.title,
    required this.normalizedTitle,
    required this.seriesTitle,
    required this.normalizedSeriesTitle,
    required this.tmdbId,
    required this.seriesTmdbId,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.year,
    required this.presentationUniqueKey,
    required this.normalizedPresentationUniqueKey,
    required this.mediaPath,
    required this.normalizedPathStem,
  });

  final WatchHistoryMediaKind mediaKind;
  final String canonicalKey;
  final String title;
  final String normalizedTitle;
  final String? seriesTitle;
  final String normalizedSeriesTitle;
  final String? tmdbId;
  final String? seriesTmdbId;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? year;
  final String? presentationUniqueKey;
  final String? normalizedPresentationUniqueKey;
  final String? mediaPath;
  final String? normalizedPathStem;
}

class WatchHistoryMatchResult {
  const WatchHistoryMatchResult({
    required this.confidence,
    required this.reason,
  });

  final WatchHistoryMatchConfidence confidence;
  final String reason;
}

WatchHistoryMediaKind? watchHistoryMediaKindFromItem(MediaItem item) {
  switch (item.type.toLowerCase()) {
    case 'movie':
      return WatchHistoryMediaKind.movie;
    case 'episode':
      return WatchHistoryMediaKind.episode;
    default:
      return null;
  }
}

WatchHistoryFingerprint? buildWatchHistoryFingerprintFromItem(
  MediaItem item, {
  String? seriesTmdbId,
}) {
  final mediaKind = watchHistoryMediaKindFromItem(item);
  if (mediaKind == null) {
    return null;
  }

  final tmdbId = extractProviderId(item.providerIds, 'tmdb');
  final resolvedSeriesTmdbId =
      mediaKind == WatchHistoryMediaKind.episode ? seriesTmdbId : null;
  final normalizedTitle = normalizeWatchHistoryText(item.name);
  final normalizedSeriesTitle =
      normalizeWatchHistoryText(item.seriesName ?? '');
  final normalizedPresentationUniqueKey =
      normalizePresentationUniqueKey(item.presentationUniqueKey);
  final normalizedPathStem = normalizePathStem(item.path);

  return WatchHistoryFingerprint(
    mediaKind: mediaKind,
    canonicalKey: buildWatchHistoryCanonicalKey(
      mediaKind: mediaKind,
      itemId: item.id,
      tmdbId: tmdbId,
      seriesTmdbId: resolvedSeriesTmdbId,
      presentationUniqueKey: item.presentationUniqueKey,
      normalizedTitle: normalizedTitle,
      normalizedSeriesTitle: normalizedSeriesTitle,
      seasonNumber: item.parentIndexNumber,
      episodeNumber: item.indexNumber,
      year: item.productionYear,
    ),
    title: item.name,
    normalizedTitle: normalizedTitle,
    seriesTitle: item.seriesName,
    normalizedSeriesTitle: normalizedSeriesTitle,
    tmdbId: tmdbId,
    seriesTmdbId: resolvedSeriesTmdbId,
    seasonNumber: item.parentIndexNumber,
    episodeNumber: item.indexNumber,
    year: item.productionYear,
    presentationUniqueKey: item.presentationUniqueKey,
    normalizedPresentationUniqueKey: normalizedPresentationUniqueKey,
    mediaPath: item.path,
    normalizedPathStem: normalizedPathStem,
  );
}

WatchHistoryFingerprint buildWatchHistoryFingerprintFromRecord(
  WatchHistoryRecord record,
) {
  final normalizedTitle = normalizeWatchHistoryText(record.title);
  final normalizedSeriesTitle =
      normalizeWatchHistoryText(record.seriesTitle ?? '');
  return WatchHistoryFingerprint(
    mediaKind: record.mediaKind,
    canonicalKey: record.canonicalKey,
    title: record.title,
    normalizedTitle: normalizedTitle,
    seriesTitle: record.seriesTitle,
    normalizedSeriesTitle: normalizedSeriesTitle,
    tmdbId: record.tmdbId,
    seriesTmdbId: record.seriesTmdbId,
    seasonNumber: record.seasonNumber,
    episodeNumber: record.episodeNumber,
    year: record.year,
    presentationUniqueKey: record.presentationUniqueKey,
    normalizedPresentationUniqueKey:
        normalizePresentationUniqueKey(record.presentationUniqueKey),
    mediaPath: record.mediaPath,
    normalizedPathStem: normalizePathStem(record.mediaPath),
  );
}

String buildWatchHistoryCanonicalKey({
  required WatchHistoryMediaKind mediaKind,
  required String itemId,
  String? tmdbId,
  String? seriesTmdbId,
  String? presentationUniqueKey,
  required String normalizedTitle,
  required String normalizedSeriesTitle,
  int? seasonNumber,
  int? episodeNumber,
  int? year,
}) {
  final normalizedPresentationUniqueKey =
      normalizePresentationUniqueKey(presentationUniqueKey);

  if (mediaKind == WatchHistoryMediaKind.movie) {
    if (tmdbId != null && tmdbId.isNotEmpty) {
      return 'movie:tmdb:$tmdbId';
    }
    if (normalizedPresentationUniqueKey != null &&
        normalizedPresentationUniqueKey.isNotEmpty) {
      return 'movie:puk:$normalizedPresentationUniqueKey';
    }
    if (normalizedTitle.isNotEmpty) {
      final yearSegment = year == null ? 'unknown' : year.toString();
      return 'movie:title:$normalizedTitle:year:$yearSegment';
    }
    return 'movie:item:$itemId';
  }

  if (seriesTmdbId != null &&
      seriesTmdbId.isNotEmpty &&
      seasonNumber != null &&
      episodeNumber != null) {
    return 'series:tmdb:$seriesTmdbId:s${_padIndex(seasonNumber)}:e${_padIndex(episodeNumber)}';
  }
  if (tmdbId != null &&
      tmdbId.isNotEmpty &&
      seasonNumber != null &&
      episodeNumber != null) {
    return 'episode:tmdb:$tmdbId:s${_padIndex(seasonNumber)}:e${_padIndex(episodeNumber)}';
  }
  if (normalizedPresentationUniqueKey != null &&
      normalizedPresentationUniqueKey.isNotEmpty) {
    return 'episode:puk:$normalizedPresentationUniqueKey';
  }
  if (normalizedSeriesTitle.isNotEmpty &&
      seasonNumber != null &&
      episodeNumber != null) {
    return 'episode:title:$normalizedSeriesTitle:s${_padIndex(seasonNumber)}:e${_padIndex(episodeNumber)}';
  }
  return 'episode:item:$itemId';
}

String buildWatchHistoryRecordId({
  required String scopeKey,
  required WatchHistoryMediaKind mediaKind,
  required String canonicalKey,
}) {
  return '$scopeKey:${mediaKind.wireValue}:$canonicalKey';
}

WatchHistoryMatchResult matchWatchHistoryRecordToCandidate({
  required WatchHistoryRecord record,
  required MediaItem candidate,
  String? candidateSeriesTmdbId,
  bool uniqueCandidate = false,
}) {
  final recordPrint = buildWatchHistoryFingerprintFromRecord(record);
  final candidatePrint = buildWatchHistoryFingerprintFromItem(
    candidate,
    seriesTmdbId: candidateSeriesTmdbId,
  );
  if (candidatePrint == null ||
      recordPrint.mediaKind != candidatePrint.mediaKind) {
    return const WatchHistoryMatchResult(
      confidence: WatchHistoryMatchConfidence.none,
      reason: '类型不匹配',
    );
  }

  final recordPuk = recordPrint.normalizedPresentationUniqueKey;
  final candidatePuk = candidatePrint.normalizedPresentationUniqueKey;
  if (recordPuk != null && recordPuk.isNotEmpty && recordPuk == candidatePuk) {
    return const WatchHistoryMatchResult(
      confidence: WatchHistoryMatchConfidence.strong,
      reason: 'PresentationUniqueKey 匹配',
    );
  }

  if (record.mediaKind == WatchHistoryMediaKind.movie) {
    return _matchMovieRecord(
      record: recordPrint,
      candidate: candidatePrint,
      uniqueCandidate: uniqueCandidate,
    );
  }

  return _matchEpisodeRecord(
    record: recordPrint,
    candidate: candidatePrint,
    uniqueCandidate: uniqueCandidate,
  );
}

String? extractProviderId(Map<String, String>? providerIds, String key) {
  if (providerIds == null || providerIds.isEmpty) {
    return null;
  }
  for (final entry in providerIds.entries) {
    if (entry.key.toLowerCase() == key.toLowerCase()) {
      final value = entry.value.trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
  }
  return null;
}

String normalizeWatchHistoryText(String value) {
  final lowered = value.toLowerCase().trim();
  if (lowered.isEmpty) {
    return '';
  }
  final withoutBrackets = lowered
      .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'\([^)]*\)'), ' ');
  return withoutBrackets
      .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String? normalizePresentationUniqueKey(String? value) {
  final text = value?.trim().toLowerCase();
  if (text == null || text.isEmpty) {
    return null;
  }
  return text;
}

String? normalizePathStem(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  return normalizeWatchHistoryText(p.basenameWithoutExtension(text));
}

WatchHistoryMatchResult _matchMovieRecord({
  required WatchHistoryFingerprint record,
  required WatchHistoryFingerprint candidate,
  required bool uniqueCandidate,
}) {
  final sameTmdb = record.tmdbId != null && record.tmdbId == candidate.tmdbId;
  final sameTitle = record.normalizedTitle.isNotEmpty &&
      record.normalizedTitle == candidate.normalizedTitle;
  final closeTitle = _titlesCloseEnough(
    record.normalizedTitle,
    candidate.normalizedTitle,
  );
  final sameYear = record.year != null && record.year == candidate.year;
  final samePathStem = record.normalizedPathStem != null &&
      record.normalizedPathStem == candidate.normalizedPathStem;

  if (sameTmdb && sameTitle) {
    return const WatchHistoryMatchResult(
      confidence: WatchHistoryMatchConfidence.strong,
      reason: '标题 + TMDB 匹配',
    );
  }

  if (sameTitle && sameYear) {
    return WatchHistoryMatchResult(
      confidence: uniqueCandidate
          ? WatchHistoryMatchConfidence.possible
          : WatchHistoryMatchConfidence.weak,
      reason: '标题 + 年份匹配',
    );
  }

  if (closeTitle && samePathStem) {
    return WatchHistoryMatchResult(
      confidence: uniqueCandidate
          ? WatchHistoryMatchConfidence.possible
          : WatchHistoryMatchConfidence.weak,
      reason: '标题 + 文件名匹配',
    );
  }

  if (closeTitle && uniqueCandidate) {
    return const WatchHistoryMatchResult(
      confidence: WatchHistoryMatchConfidence.possible,
      reason: '标题接近且候选唯一',
    );
  }

  return const WatchHistoryMatchResult(
    confidence: WatchHistoryMatchConfidence.none,
    reason: '电影关键信息不足',
  );
}

WatchHistoryMatchResult _matchEpisodeRecord({
  required WatchHistoryFingerprint record,
  required WatchHistoryFingerprint candidate,
  required bool uniqueCandidate,
}) {
  final sameSeriesTmdb = record.seriesTmdbId != null &&
      record.seriesTmdbId == candidate.seriesTmdbId;
  final sameEpisodeTmdb =
      record.tmdbId != null && record.tmdbId == candidate.tmdbId;
  final sameSeasonEpisode = record.seasonNumber != null &&
      record.episodeNumber != null &&
      record.seasonNumber == candidate.seasonNumber &&
      record.episodeNumber == candidate.episodeNumber;
  final sameSeriesTitle = record.normalizedSeriesTitle.isNotEmpty &&
      record.normalizedSeriesTitle == candidate.normalizedSeriesTitle;
  final samePathStem = record.normalizedPathStem != null &&
      record.normalizedPathStem == candidate.normalizedPathStem;

  if (sameSeriesTmdb && sameSeasonEpisode) {
    return const WatchHistoryMatchResult(
      confidence: WatchHistoryMatchConfidence.strong,
      reason: '剧集 TMDB + 季集号匹配',
    );
  }

  if (sameEpisodeTmdb && sameSeasonEpisode) {
    return const WatchHistoryMatchResult(
      confidence: WatchHistoryMatchConfidence.strong,
      reason: '单集 TMDB + 季集号匹配',
    );
  }

  if (sameSeasonEpisode && sameSeriesTitle) {
    return WatchHistoryMatchResult(
      confidence: uniqueCandidate
          ? WatchHistoryMatchConfidence.possible
          : WatchHistoryMatchConfidence.weak,
      reason: '剧名 + 季集号匹配',
    );
  }

  if (sameSeasonEpisode && samePathStem) {
    return WatchHistoryMatchResult(
      confidence: uniqueCandidate
          ? WatchHistoryMatchConfidence.possible
          : WatchHistoryMatchConfidence.weak,
      reason: '文件名 + 季集号匹配',
    );
  }

  return const WatchHistoryMatchResult(
    confidence: WatchHistoryMatchConfidence.none,
    reason: '剧集关键信息不足',
  );
}

bool _titlesCloseEnough(String left, String right) {
  if (left.isEmpty || right.isEmpty) {
    return false;
  }
  return left == right || left.contains(right) || right.contains(left);
}

String _padIndex(int value) => value.toString().padLeft(2, '0');
