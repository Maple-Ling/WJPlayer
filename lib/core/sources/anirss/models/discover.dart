// 「发现/添加订阅」多搜索源模型：Mikan 季度番表、AniBT 番表、AnimeGarden 番表，
// 以及各自的字幕组（Group）。字段以 `api-docs.json`（OpenAPI v3）为准，只取 UI 用到的。
//
// 订阅生成路径（与 BGM 的 getAniBySubjectId→addAni 对齐）：
// - Mikan：MikanInfo 自带 groups；选字幕组后 rssToAni({url: group.rss,
//   type: 'mikan', bgmUrl, subgroup}) → addAni。
// - AniBT / AnimeGarden：item 仅给 bgmId/bgmUrl，先 aniBTGroup/animeGardenGroup
//   拿 GroupModel 列表，再同样 rssToAni → addAni。

/// 季度（年 + 春/夏/秋/冬）。Mikan 番表的 `seasons[]`，也作为查询 body。
class SeasonModel {
  final int? year;
  final String? season;
  final String? seasonLabel;
  final bool select;

  const SeasonModel({this.year, this.season, this.seasonLabel, this.select = false});

  static SeasonModel fromJson(Map<String, dynamic> m) => SeasonModel(
        year: (m['year'] as num?)?.toInt(),
        season: m['season']?.toString(),
        seasonLabel: m['seasonLabel']?.toString(),
        select: m['select'] == true,
      );

  Map<String, dynamic> toJson() => {
        if (year != null) 'year': year,
        if (season != null) 'season': season,
        if (seasonLabel != null) 'seasonLabel': seasonLabel,
        'select': select,
      };

  String get label {
    if (seasonLabel != null && seasonLabel!.isNotEmpty) return seasonLabel!;
    final parts = <String>[
      if (year != null) '$year',
      if (season != null) season!,
    ];
    return parts.join(' ');
  }
}

/// 一个字幕组/RSS 源（Mikan/AniBT/AnimeGarden 共用）。订阅时取 [rss]+[bgmUrl]+[label]。
class GroupModel {
  final String? subgroupId;
  final String? label;
  final String? rss;
  final String? bgmUrl;
  final String? updateDay;

  const GroupModel({
    this.subgroupId,
    this.label,
    this.rss,
    this.bgmUrl,
    this.updateDay,
  });

  static GroupModel fromJson(Map<String, dynamic> m) => GroupModel(
        subgroupId: m['subgroupId']?.toString(),
        label: m['label']?.toString(),
        rss: m['rss']?.toString(),
        bgmUrl: m['bgmUrl']?.toString(),
        updateDay: m['updateDay']?.toString(),
      );

  String get displayName =>
      (label != null && label!.isNotEmpty) ? label! : '未知字幕组';
}

/// Mikan / AnimeGarden 番表里的一部番剧。
class MikanInfoModel {
  final String? bangumiId;
  final String? cover;
  final String? url;
  final bool exists;
  final double? score;
  final String title;
  final String? bgmUrl;
  final List<GroupModel> groups;

  const MikanInfoModel({
    this.bangumiId,
    this.cover,
    this.url,
    this.exists = false,
    this.score,
    this.title = '',
    this.bgmUrl,
    this.groups = const [],
  });

  static MikanInfoModel fromJson(Map<String, dynamic> m) => MikanInfoModel(
        bangumiId: m['bangumiId']?.toString(),
        cover: m['cover']?.toString(),
        url: m['url']?.toString(),
        exists: m['exists'] == true,
        score: (m['score'] as num?)?.toDouble(),
        title: m['title']?.toString() ?? '',
        bgmUrl: m['bgmUrl']?.toString(),
        groups: (m['groups'] as List?)
                ?.whereType<Map>()
                .map((e) => GroupModel.fromJson(e.cast<String, dynamic>()))
                .toList() ??
            const [],
      );

  /// 仅取 https 封面（服务端本地路径不可直接取）。
  String? get coverHttp {
    final c = cover;
    if (c == null || c.isEmpty) return null;
    return c.startsWith('http') ? c : null;
  }
}

/// 按星期分组（Mikan / AnimeGarden 的 `weeks[]`）。
class WeekModel {
  final String? weekLabel;
  final List<MikanInfoModel> items;

  const WeekModel({this.weekLabel, this.items = const []});

  static WeekModel fromJson(Map<String, dynamic> m) => WeekModel(
        weekLabel: m['weekLabel']?.toString(),
        items: (m['items'] as List?)
                ?.whereType<Map>()
                .map((e) => MikanInfoModel.fromJson(e.cast<String, dynamic>()))
                .toList() ??
            const [],
      );
}

/// Mikan 番表（`/api/mikan`）：季度选择 + 按星期分组的番剧。
class MikanModel {
  final List<SeasonModel> seasons;
  final List<WeekModel> weeks;
  final int? totalItem;

  const MikanModel({
    this.seasons = const [],
    this.weeks = const [],
    this.totalItem,
  });

  static MikanModel fromJson(Object? json) {
    if (json is! Map) return const MikanModel();
    final m = json.cast<String, dynamic>();
    return MikanModel(
      seasons: (m['seasons'] as List?)
              ?.whereType<Map>()
              .map((e) => SeasonModel.fromJson(e.cast<String, dynamic>()))
              .toList() ??
          const [],
      weeks: (m['weeks'] as List?)
              ?.whereType<Map>()
              .map((e) => WeekModel.fromJson(e.cast<String, dynamic>()))
              .toList() ??
          const [],
      totalItem: (m['totalItem'] as num?)?.toInt(),
    );
  }

  /// 展平去重所有番剧（不分星期时用）。
  List<MikanInfoModel> get allItems {
    final out = <MikanInfoModel>[];
    final seen = <String>{};
    for (final w in weeks) {
      for (final it in w.items) {
        final key = it.bangumiId ?? it.url ?? it.title;
        if (key.isEmpty || !seen.add(key)) continue;
        out.add(it);
      }
    }
    return out;
  }
}

/// 多语言标题（AniBT 的 `Anime.title`）。
class AnimeTitleModel {
  final String? chinese;
  final String? english;
  final String? primary;
  final String? romaji;

  const AnimeTitleModel({this.chinese, this.english, this.primary, this.romaji});

  static AnimeTitleModel fromJson(Object? json) {
    if (json is! Map) return const AnimeTitleModel();
    final m = json.cast<String, dynamic>();
    return AnimeTitleModel(
      chinese: m['chinese']?.toString(),
      english: m['english']?.toString(),
      primary: m['primary']?.toString(),
      romaji: m['romaji']?.toString(),
    );
  }

  String get display {
    for (final s in [chinese, primary, english, romaji]) {
      if (s != null && s.isNotEmpty) return s;
    }
    return '未命名';
  }
}

/// AniBT 番表里的一部番剧。
class AnimeModel {
  final String? animeId;
  final String? bgmId;
  final String? cover;
  final double? rating;
  final AnimeTitleModel title;
  final bool exists;

  const AnimeModel({
    this.animeId,
    this.bgmId,
    this.cover,
    this.rating,
    this.title = const AnimeTitleModel(),
    this.exists = false,
  });

  static AnimeModel fromJson(Map<String, dynamic> m) => AnimeModel(
        animeId: m['animeId']?.toString(),
        bgmId: m['bgmId']?.toString(),
        cover: m['cover']?.toString(),
        rating: (m['rating'] as num?)?.toDouble(),
        title: AnimeTitleModel.fromJson(m['title']),
        exists: m['exists'] == true,
      );

  String? get coverHttp {
    final c = cover;
    if (c == null || c.isEmpty) return null;
    return c.startsWith('http') ? c : null;
  }
}

/// AniBT 按星期分组。
class ByWeekdayModel {
  final List<AnimeModel> animes;
  final int? weekday;
  final String? weekdayLabel;

  const ByWeekdayModel({
    this.animes = const [],
    this.weekday,
    this.weekdayLabel,
  });

  static ByWeekdayModel fromJson(Map<String, dynamic> m) => ByWeekdayModel(
        animes: (m['animes'] as List?)
                ?.whereType<Map>()
                .map((e) => AnimeModel.fromJson(e.cast<String, dynamic>()))
                .toList() ??
            const [],
        weekday: (m['weekday'] as num?)?.toInt(),
        weekdayLabel: m['weekdayLabel']?.toString(),
      );
}

/// AniBT 番表（`/api/aniBT`）。
class AniBTModel {
  final String? currentSeason;
  final String? requestedSeason;
  final List<String> availableSeasons;
  final List<ByWeekdayModel> byWeekday;

  const AniBTModel({
    this.currentSeason,
    this.requestedSeason,
    this.availableSeasons = const [],
    this.byWeekday = const [],
  });

  static AniBTModel fromJson(Object? json) {
    if (json is! Map) return const AniBTModel();
    final m = json.cast<String, dynamic>();
    return AniBTModel(
      currentSeason: m['currentSeason']?.toString(),
      requestedSeason: m['requestedSeason']?.toString(),
      availableSeasons:
          (m['availableSeasons'] as List?)?.map((e) => e.toString()).toList() ??
              const [],
      byWeekday: (m['byWeekday'] as List?)
              ?.whereType<Map>()
              .map((e) => ByWeekdayModel.fromJson(e.cast<String, dynamic>()))
              .toList() ??
          const [],
    );
  }

  /// 展平去重所有番剧。
  List<AnimeModel> get allAnimes {
    final out = <AnimeModel>[];
    final seen = <String>{};
    for (final w in byWeekday) {
      for (final a in w.animes) {
        final key = a.bgmId ?? a.animeId ?? a.title.display;
        if (key.isEmpty || !seen.add(key)) continue;
        out.add(a);
      }
    }
    return out;
  }
}
