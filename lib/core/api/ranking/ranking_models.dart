// 排行榜数据模型（三端共用）。
//
// 动漫榜来自弹弹Play 开放平台「排行榜」接口，影视榜来自 TMDB。两者字段差异
// 收敛到统一的 RankingEntry，UI 层无需感知数据源差异。

/// 数据源类型。
enum RankingSource { dandan, tmdb }

/// 榜单分组（决定顶部一级分类与图标）。
enum RankingGroup { anime, movie, tv }

/// 榜单中的一个条目（已带名次，可直接渲染）。
class RankingEntry {
  final RankingSource source;

  /// dandan：animeId；tmdb：tmdb id（字符串化）。
  final String id;
  final String title;

  /// 完整可直接加载的封面 URL（dandan 直接给全 URL；tmdb 已拼好 image.tmdb.org）。
  final String? imageUrl;

  /// 评分（0–10）。
  final double? rating;

  /// 1 基名次。
  final int rank;

  /// 副标题：年份 / 类型描述 / 首播季度等。
  final String? subtitle;

  /// 是否已追番（仅 dandan）。
  final bool isFavorited;

  /// tmdb 媒体类型：'movie' | 'tv'（用于点按跳转）。
  final String? mediaType;

  const RankingEntry({
    required this.source,
    required this.id,
    required this.title,
    required this.rank,
    this.imageUrl,
    this.rating,
    this.subtitle,
    this.isFavorited = false,
    this.mediaType,
  });

  Map<String, dynamic> toJson() => {
        'source': source.name,
        'id': id,
        'title': title,
        'rank': rank,
        if (imageUrl != null) 'imageUrl': imageUrl,
        if (rating != null) 'rating': rating,
        if (subtitle != null) 'subtitle': subtitle,
        'isFavorited': isFavorited,
        if (mediaType != null) 'mediaType': mediaType,
      };

  static RankingEntry fromJson(Map<String, dynamic> j) => RankingEntry(
        source: j['source'] == 'tmdb' ? RankingSource.tmdb : RankingSource.dandan,
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        rank: (j['rank'] as num?)?.toInt() ?? 0,
        imageUrl: j['imageUrl'] as String?,
        rating: (j['rating'] as num?)?.toDouble(),
        subtitle: j['subtitle'] as String?,
        isFavorited: j['isFavorited'] as bool? ?? false,
        mediaType: j['mediaType'] as String?,
      );
}

/// 一个可拉取的榜单（分类）描述符。字段即拉取所需的全部信息。
class RankingCategory {
  /// 稳定唯一键（用于缓存文件名与 provider family 参数）。
  final String id;
  final RankingGroup group;
  final RankingSource source;

  /// 子类标签，如「本周热门」「当季新番」「正在上映」。
  final String label;

  /// dandan：拼在 `/api/v2/trending/{path}` 后的相对片段，
  /// 如 `all/hot/week`、`new-anime/hot/current-season`。
  final String? dandanPath;

  /// tmdb：相对 `/3` 的路径，如 `/trending/movie/week`、`/movie/top_rated`。
  final String? tmdbPath;

  const RankingCategory({
    required this.id,
    required this.group,
    required this.source,
    required this.label,
    this.dandanPath,
    this.tmdbPath,
  });
}

/// 分组的展示元信息。
extension RankingGroupLabel on RankingGroup {
  String get label => switch (this) {
        RankingGroup.anime => '动漫',
        RankingGroup.movie => '电影',
        RankingGroup.tv => '剧集',
      };
}

/// 内置榜单清单。动漫走弹弹Play，电影/剧集走 TMDB。
const List<RankingCategory> kRankingCategories = [
  // —— 动漫（弹弹Play 排行榜）——
  RankingCategory(
    id: 'anime_hot_week',
    group: RankingGroup.anime,
    source: RankingSource.dandan,
    label: '本周热门',
    dandanPath: 'all/hot/week',
  ),
  RankingCategory(
    id: 'anime_hot_month',
    group: RankingGroup.anime,
    source: RankingSource.dandan,
    label: '本月热门',
    dandanPath: 'all/hot/month',
  ),
  RankingCategory(
    id: 'anime_rising_week',
    group: RankingGroup.anime,
    source: RankingSource.dandan,
    label: '本周飙升',
    dandanPath: 'all/rising/week',
  ),
  RankingCategory(
    id: 'anime_new_current',
    group: RankingGroup.anime,
    source: RankingSource.dandan,
    label: '当季新番',
    dandanPath: 'new-anime/hot/current-season',
  ),
  RankingCategory(
    id: 'anime_new_previous',
    group: RankingGroup.anime,
    source: RankingSource.dandan,
    label: '上季新番',
    dandanPath: 'new-anime/hot/previous-season',
  ),
  // —— 电影（TMDB）——
  RankingCategory(
    id: 'movie_trending_week',
    group: RankingGroup.movie,
    source: RankingSource.tmdb,
    label: '本周趋势',
    tmdbPath: '/trending/movie/week',
  ),
  RankingCategory(
    id: 'movie_popular',
    group: RankingGroup.movie,
    source: RankingSource.tmdb,
    label: '流行',
    tmdbPath: '/movie/popular',
  ),
  RankingCategory(
    id: 'movie_top_rated',
    group: RankingGroup.movie,
    source: RankingSource.tmdb,
    label: '高分',
    tmdbPath: '/movie/top_rated',
  ),
  RankingCategory(
    id: 'movie_now_playing',
    group: RankingGroup.movie,
    source: RankingSource.tmdb,
    label: '正在上映',
    tmdbPath: '/movie/now_playing',
  ),
  // —— 剧集（TMDB）——
  RankingCategory(
    id: 'tv_trending_week',
    group: RankingGroup.tv,
    source: RankingSource.tmdb,
    label: '本周趋势',
    tmdbPath: '/trending/tv/week',
  ),
  RankingCategory(
    id: 'tv_popular',
    group: RankingGroup.tv,
    source: RankingSource.tmdb,
    label: '流行',
    tmdbPath: '/tv/popular',
  ),
  RankingCategory(
    id: 'tv_top_rated',
    group: RankingGroup.tv,
    source: RankingSource.tmdb,
    label: '高分',
    tmdbPath: '/tv/top_rated',
  ),
  RankingCategory(
    id: 'tv_on_the_air',
    group: RankingGroup.tv,
    source: RankingSource.tmdb,
    label: '正在播出',
    tmdbPath: '/tv/on_the_air',
  ),
];
