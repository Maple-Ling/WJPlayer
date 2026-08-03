import '../api/api_interfaces.dart';
import '../providers/server_providers.dart';
import 'feiniu_backend.dart';
import 'media_source_backend.dart';

class UnifiedMediaEntry {
  const UnifiedMediaEntry({
    required this.id,
    required this.name,
    required this.type,
    this.posterUrl,
    this.backdropUrl,
    this.imageHeaders,
    this.year,
    this.rating,
    this.overview,
    this.providerIds = const {},
    this.progress,
    this.mediaItem,
    this.sourceEntry,
  });

  final String id;
  final String name;
  final String type;
  final String? posterUrl;
  final String? backdropUrl;
  final Map<String, String>? imageHeaders;
  final int? year;
  final double? rating;
  final String? overview;
  final Map<String, String> providerIds;
  final double? progress;
  final MediaItem? mediaItem;
  final SourceEntry? sourceEntry;

  bool get isSeries =>
      type.toLowerCase() == 'series' || type.toLowerCase() == 'tv';
  bool get isPlayable =>
      const {'movie', 'episode', 'video'}.contains(type.toLowerCase());

  MediaItem get ratingItem =>
      mediaItem ??
      MediaItem(
        id: id,
        name: name,
        type: isSeries ? 'Series' : 'Movie',
        providerIds: providerIds,
        productionYear: year,
      );
}

class UnifiedMediaLibrary {
  const UnifiedMediaLibrary({required this.id, required this.name});
  final String id;
  final String name;
}

class UnifiedContinueItem {
  const UnifiedContinueItem({required this.entry, required this.progress});
  final UnifiedMediaEntry entry;
  final double progress;
}

class UnifiedSeason {
  const UnifiedSeason({required this.id, required this.name});
  final String id;
  final String name;
}

class UnifiedPerson {
  const UnifiedPerson({
    required this.name,
    this.role,
    this.imageUrl,
    this.imageHeaders,
  });
  final String name;
  final String? role;
  final String? imageUrl;
  final Map<String, String>? imageHeaders;
}

class UnifiedMediaDetail {
  const UnifiedMediaDetail({
    required this.entry,
    this.seasons = const [],
    this.people = const [],
    this.seriesId,
    this.initialSeasonId,
    this.initialEntryId,
  });
  final UnifiedMediaEntry entry;
  final List<UnifiedSeason> seasons;
  final List<UnifiedPerson> people;
  final String? seriesId;
  final String? initialSeasonId;
  final String? initialEntryId;
}

class UnifiedMediaResource {
  const UnifiedMediaResource({
    required this.id,
    required this.name,
    this.path,
    this.size,
    this.video,
    this.audios = const [],
    this.subtitles = const [],
  });
  final String id;
  final String name;
  final String? path;
  final int? size;
  final Map<String, dynamic>? video;
  final List<Map<String, dynamic>> audios;
  final List<Map<String, dynamic>> subtitles;
}

abstract class UnifiedMediaAdapter {
  ServerConfig get server;
  bool get isFeiniu;

  Future<List<UnifiedMediaLibrary>> libraries();
  Future<List<UnifiedContinueItem>> continueWatching();
  Future<List<UnifiedMediaEntry>> preview(String libraryId);
  Future<List<UnifiedMediaEntry>> libraryItems(String libraryId);
  Future<UnifiedMediaDetail> detail(UnifiedMediaEntry entry);
  Future<List<UnifiedMediaEntry>> episodes(String seriesId, String seasonId);
  Future<List<UnifiedMediaResource>> mediaResources(UnifiedMediaEntry entry);
}

UnifiedMediaAdapter unifiedMediaAdapterFor(
  ServerConfig server, {
  ApiClientFactory? embyApi,
}) {
  if (server.sourceKind == SourceKind.feiniu) {
    return FeiniuUnifiedMediaAdapter(server);
  }
  if (server.sourceKind == SourceKind.emby && embyApi != null) {
    return EmbyUnifiedMediaAdapter(server, embyApi);
  }
  throw StateError('当前服务器不支持影视统一界面');
}

class EmbyUnifiedMediaAdapter implements UnifiedMediaAdapter {
  EmbyUnifiedMediaAdapter(this.server, this.api);

  @override
  final ServerConfig server;
  final ApiClientFactory api;

  @override
  bool get isFeiniu => false;

  @override
  Future<List<UnifiedMediaLibrary>> libraries() async =>
      (await api.home.getLibraries())
          .map((item) => UnifiedMediaLibrary(id: item.id, name: item.name))
          .toList();

  @override
  Future<List<UnifiedContinueItem>> continueWatching() async =>
      (await api.home.getResumeItems()).map((item) {
        final progress = (item.progress ?? 0).clamp(0.0, 1.0).toDouble();
        return UnifiedContinueItem(entry: _entry(item), progress: progress);
      }).toList();

  @override
  Future<List<UnifiedMediaEntry>> preview(String libraryId) async =>
      (await api.home.getLatestItems(libraryId, limit: 12))
          .map(_entry)
          .toList();

  @override
  Future<List<UnifiedMediaEntry>> libraryItems(String libraryId) async =>
      (await api.library.getLibraryItems(
        libraryId: libraryId,
        limit: 0,
        sortBy: 'DateCreated',
        sortOrder: 'Descending',
      ))
          .map(_entry)
          .toList();

  @override
  Future<UnifiedMediaDetail> detail(UnifiedMediaEntry entry) async {
    final item = await api.media.getItemDetails(entry.id);
    final seriesId = item.type == 'Series' ? item.id : item.seriesId;
    final seasons = seriesId != null && seriesId.isNotEmpty
        ? await api.media.getSeasons(seriesId)
        : const <Season>[];
    final people = item.people ?? const <Person>[];
    return UnifiedMediaDetail(
      entry: _entry(item),
      seriesId: seriesId,
      initialSeasonId: item.type == 'Season' ? item.id : item.seasonId,
      initialEntryId: item.type == 'Episode' ? item.id : null,
      seasons: seasons
          .map((season) => UnifiedSeason(id: season.id, name: season.name))
          .toList(),
      people: people
          .map((person) => UnifiedPerson(
                name: person.name,
                role: person.role ?? person.type,
                imageUrl: person.primaryImageTag == null
                    ? null
                    : api.image.getPrimaryImageUrl(
                        person.id,
                        tag: person.primaryImageTag,
                        maxWidth: 240,
                      ),
              ))
          .toList(),
    );
  }

  @override
  Future<List<UnifiedMediaEntry>> episodes(
      String seriesId, String seasonId) async {
    final items = await api.media.getEpisodes(seriesId, seasonId: seasonId);
    return items.map((episode) {
      final media = MediaItem(
        id: episode.id,
        name: episode.name,
        type: 'Episode',
        overview: episode.overview,
        primaryImageTag: episode.primaryImageTag,
        thumbImageTag: episode.thumbImageTag,
        seriesId: episode.seriesId,
        seasonId: episode.seasonId,
        parentThumbItemId: episode.parentThumbItemId,
        parentThumbImageTag: episode.parentThumbImageTag,
        parentPrimaryImageItemId: episode.parentPrimaryImageItemId,
        parentPrimaryImageTag: episode.parentPrimaryImageTag,
        seriesThumbImageTag: episode.seriesThumbImageTag,
        seriesPrimaryImageTag: episode.seriesPrimaryImageTag,
        runTimeTicks: episode.runTimeTicks,
        userData: episode.userData,
        indexNumber: episode.indexNumber,
        mediaType: 'Video',
      );
      return _entry(media);
    }).toList();
  }

  @override
  Future<List<UnifiedMediaResource>> mediaResources(
      UnifiedMediaEntry entry) async {
    if (entry.mediaItem?.mediaSources != null) {
      final sources = entry.mediaItem!.mediaSources!;
      Map<String, dynamic> stream(MediaStream value) => {
            'index': value.index,
            'codec_name': value.codec,
            'language': value.language,
            'title': value.displayTitle ?? value.title,
            'is_external': value.isExternal,
            'width': value.width,
            'height': value.height,
            'channels': value.channels,
            'bitrate': value.bitRate,
            'video_range': value.videoRange,
            'video_range_type': value.videoRangeType,
          };
      final videos = source.mediaStreams.where((item) => item.isVideo).toList();
      final audios = source.mediaStreams.where((item) => item.isAudio).toList();
      final subtitles =
          source.mediaStreams.where((item) => item.isSubtitle).toList();
      return UnifiedMediaResource(
        id: source.id,
        name: source.name?.trim().isNotEmpty == true
            ? source.name!
            : (source.container?.toUpperCase() ?? '默认资源'),
        path: source.path,
        size: source.size,
        video: videos.isEmpty
            ? null
            : stream(source.primaryVideoStream ?? videos.first),
        audios: audios.map(stream).toList(),
        subtitles: subtitles.map(stream).toList(),
      );
    }).toList();
  }

  UnifiedMediaEntry _entry(MediaItem item) {
    String? poster;
    if (item.primaryImageTag != null) {
      poster = api.image.getPrimaryImageUrl(item.id,
          tag: item.primaryImageTag, maxWidth: 640);
    } else if (item.parentPrimaryImageItemId != null &&
        item.parentPrimaryImageTag != null) {
      poster = api.image.getPrimaryImageUrl(item.parentPrimaryImageItemId!,
          tag: item.parentPrimaryImageTag, maxWidth: 640);
    } else if (item.seriesId != null && item.seriesPrimaryImageTag != null) {
      poster = api.image.getPrimaryImageUrl(item.seriesId!,
          tag: item.seriesPrimaryImageTag, maxWidth: 640);
    }
    String? backdrop;
    if (item.backdropImageTag != null) {
      backdrop = api.image.getBackdropImageUrl(item.backdropItemId ?? item.id,
          tag: item.backdropImageTag, maxWidth: 1400);
    } else if (item.thumbImageTag != null) {
      backdrop = api.image
          .getThumbImageUrl(item.id, tag: item.thumbImageTag, maxWidth: 1400);
    }
    return UnifiedMediaEntry(
      id: item.id,
      name: item.name,
      type: item.type,
      posterUrl: poster,
      backdropUrl: backdrop,
      year: item.productionYear,
      rating: item.communityRating,
      overview: item.overview,
      providerIds: item.providerIds ?? const {},
      progress: item.progress,
      mediaItem: item,
    );
  }
}

class FeiniuUnifiedMediaAdapter implements UnifiedMediaAdapter {
  FeiniuUnifiedMediaAdapter(this.server);

  @override
  final ServerConfig server;
  final FeiniuBackend backend = FeiniuBackend();

  @override
  bool get isFeiniu => true;

  @override
  Future<List<UnifiedMediaLibrary>> libraries() async =>
      (await backend.libraries(server))
          .map((item) => UnifiedMediaLibrary(id: item.id, name: item.name))
          .toList();

  @override
  Future<List<UnifiedContinueItem>> continueWatching() async =>
      (await backend.continueWatching(server))
          .map((item) => UnifiedContinueItem(
                entry: _entry(item.entry),
                progress: item.progress,
              ))
          .toList();

  @override
  Future<List<UnifiedMediaEntry>> preview(String libraryId) async =>
      (await backend.libraryItems(server, libraryId))
          .take(12)
          .map(_entry)
          .toList();

  @override
  Future<List<UnifiedMediaEntry>> libraryItems(String libraryId) async =>
      (await backend.libraryItems(server, libraryId)).map(_entry).toList();

  @override
  Future<UnifiedMediaDetail> detail(UnifiedMediaEntry entry) async {
    final source = entry.sourceEntry ?? _source(entry);
    final detail = await backend.itemDetail(server, source);
    final people = await backend
        .persons(server, detail.seriesGuid ?? source.id)
        .catchError((_) => const <Map<String, dynamic>>[]);
    return UnifiedMediaDetail(
      entry: _entry(detail.entry, detail.item),
      seriesId: detail.seriesGuid,
      initialSeasonId:
          (detail.playInfo['parent_guid'] ?? detail.item['parent_guid'])
              ?.toString(),
      initialEntryId:
          detail.playInfo['guid']?.toString() ?? detail.entry.id,
      seasons: detail.seasons
          .map((season) => UnifiedSeason(id: season.id, name: season.name))
          .toList(),
      people: people
          .map((person) => UnifiedPerson(
                name: (person['name'] ?? '未知').toString(),
                role: person['job']?.toString(),
                imageUrl: backend.imageUrl(
                    server, person['profile_path']?.toString(),
                    width: 240),
                imageHeaders: detail.entry.thumbHeaders,
              ))
          .toList(),
    );
  }

  @override
  Future<List<UnifiedMediaEntry>> episodes(
          String seriesId, String seasonId) async =>
      (await backend.episodes(server, seasonId)).map(_entry).toList();

  @override
  Future<List<UnifiedMediaResource>> mediaResources(
      UnifiedMediaEntry entry) async {
    final media =
        await backend.mediaDetails(server, entry.sourceEntry ?? _source(entry));
    final file = media.file;
    return [
      UnifiedMediaResource(
        id: entry.id,
        name: (file?['file_name'] ?? '默认资源').toString(),
        path: file?['path']?.toString(),
        size: (file?['size'] as num?)?.toInt(),
        video: media.video,
        audios: media.audios,
        subtitles: media.subtitles,
      ),
    ];
  }

  UnifiedMediaEntry _entry(SourceEntry source, [Map<String, dynamic>? detail]) {
    final raw = detail ?? source.raw ?? const <String, dynamic>{};
    final providerIds = <String, String>{};
    for (final pair in [
      ('tmdb', raw['tmdb_id'] ?? raw['tmdb']),
      ('imdb', raw['imdb_id'] ?? raw['imdb']),
      ('douban', raw['douban_id'] ?? raw['douban']),
    ]) {
      final value = pair.$2?.toString().trim() ?? '';
      if (value.isNotEmpty) providerIds[pair.$1] = value;
    }
    final type =
        (raw['type'] ?? (source.isDir ? 'Series' : 'Movie')).toString();
    final backdropPath = _firstImage(raw['backdrops'] ?? raw['still_path']);
    final rating = raw['vote_average'] is num
        ? (raw['vote_average'] as num).toDouble()
        : double.tryParse('${raw['vote_average'] ?? ''}');
    final year = int.tryParse('${raw['year'] ?? ''}') ??
        int.tryParse('${raw['release_date'] ?? ''}'.split('-').first);
    return UnifiedMediaEntry(
      id: source.id,
      name: source.name,
      type: type,
      posterUrl: source.thumbUrl,
      backdropUrl: backend.imageUrl(server, backdropPath, width: 1400),
      imageHeaders: source.thumbHeaders,
      year: year,
      rating: rating,
      overview: raw['overview']?.toString(),
      providerIds: providerIds,
      progress: null,
      sourceEntry: source,
    );
  }

  SourceEntry _source(UnifiedMediaEntry entry) => SourceEntry(
        id: entry.id,
        name: entry.name,
        isDir: entry.isSeries,
        isVideo: entry.isPlayable,
        thumbUrl: entry.posterUrl,
        thumbHeaders: entry.imageHeaders,
        raw: {
          'type': entry.type,
          'overview': entry.overview,
          'year': entry.year,
          'vote_average': entry.rating,
          ...entry.providerIds,
        },
      );

  String? _firstImage(dynamic value) {
    if (value is String && value.isNotEmpty) return value;
    if (value is List && value.isNotEmpty) return value.first?.toString();
    return null;
  }
}
