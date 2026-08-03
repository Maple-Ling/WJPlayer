enum ReviewSource { douban, tmdb, imdb }

extension ReviewSourceUi on ReviewSource {
  String get label => switch (this) {
        ReviewSource.douban => '豆瓣',
        ReviewSource.tmdb => 'TMDB',
        ReviewSource.imdb => 'IMDb',
      };

  String get wireName => name;
}

ReviewSource reviewSourceFromWire(String? value) => switch (value) {
      'tmdb' => ReviewSource.tmdb,
      'imdb' => ReviewSource.imdb,
      _ => ReviewSource.douban,
    };

/// 各站点原生榜单描述。影视页按这些榜单展示媒体架，而不是人为只切“电影/剧集”。
class DiscoverCategory {
  const DiscoverCategory({
    required this.id,
    required this.label,
    required this.mediaType,
  });

  final String id;
  final String label;
  final String mediaType;
}

List<DiscoverCategory> discoverCategoriesFor(ReviewSource source) =>
    switch (source) {
      ReviewSource.douban => const [
          DiscoverCategory(id: 'movie_showing', label: '精选', mediaType: 'movie'),
          DiscoverCategory(id: 'movie_hot_gaia', label: '热门电影', mediaType: 'movie'),
          DiscoverCategory(id: 'tv_hot', label: '热播剧集', mediaType: 'tv'),
          DiscoverCategory(id: 'show_hot', label: '热播综艺', mediaType: 'tv'),
          DiscoverCategory(id: 'movie_latest', label: '最新电影', mediaType: 'movie'),
          DiscoverCategory(id: 'movie_weekly_best', label: '一周排行榜', mediaType: 'movie'),
          DiscoverCategory(id: 'chart:new', label: '豆瓣新片榜', mediaType: 'movie'),
          DiscoverCategory(id: 'chart:us', label: '北美票房榜', mediaType: 'movie'),
          DiscoverCategory(id: 'annual:2025', label: '豆瓣 2025 年度榜单', mediaType: 'movie'),
          DiscoverCategory(id: 'movie_top250', label: '豆瓣电影 Top 250', mediaType: 'movie'),
          DiscoverCategory(id: 'tv_domestic', label: '国产剧集榜', mediaType: 'tv'),
          DiscoverCategory(id: 'tv_american', label: '美剧榜', mediaType: 'tv'),
          DiscoverCategory(id: 'tv_korean', label: '韩剧榜', mediaType: 'tv'),
          DiscoverCategory(id: 'tv_japanese', label: '日剧榜', mediaType: 'tv'),
          DiscoverCategory(id: 'tv_animation', label: '热门动漫', mediaType: 'tv'),
          DiscoverCategory(id: 'filter:movie', label: '电影筛选', mediaType: 'movie'),
          DiscoverCategory(id: 'filter:tv', label: '电视筛选', mediaType: 'tv'),
        ],
      ReviewSource.tmdb => const [
          DiscoverCategory(id: '/trending/movie/day', label: '实时热门电影', mediaType: 'movie'),
          DiscoverCategory(id: '/trending/tv/day', label: '实时热门剧集', mediaType: 'tv'),
          DiscoverCategory(id: '/movie/now_playing', label: '正在热映', mediaType: 'movie'),
          DiscoverCategory(id: '/movie/popular', label: '热门电影', mediaType: 'movie'),
          DiscoverCategory(id: '/tv/popular', label: '热门剧集', mediaType: 'tv'),
          DiscoverCategory(id: '/discover/tv?with_genres=16&sort_by=popularity.desc', label: '热门动漫', mediaType: 'tv'),
          DiscoverCategory(id: '/discover/tv?with_original_language=ja&with_genres=16&sort_by=popularity.desc', label: '番剧', mediaType: 'tv'),
          DiscoverCategory(id: '/discover/tv?with_original_language=zh&sort_by=vote_average.desc&vote_count.gte=100', label: '国产剧集榜', mediaType: 'tv'),
          DiscoverCategory(id: '/tv/top_rated', label: '全球剧集榜', mediaType: 'tv'),
          DiscoverCategory(id: '/movie/upcoming', label: '即将上映', mediaType: 'movie'),
          DiscoverCategory(id: '/discover/movie?with_watch_providers=8&watch_region=US&sort_by=popularity.desc', label: 'Netflix', mediaType: 'movie'),
          DiscoverCategory(id: '/discover/movie?with_watch_providers=9&watch_region=US&sort_by=popularity.desc', label: 'Prime Video', mediaType: 'movie'),
          DiscoverCategory(id: '/discover/movie?with_watch_providers=337&watch_region=US&sort_by=popularity.desc', label: 'Disney+', mediaType: 'movie'),
          DiscoverCategory(id: '/discover/movie?with_watch_providers=350&watch_region=US&sort_by=popularity.desc', label: 'Apple TV+', mediaType: 'movie'),
          DiscoverCategory(id: '/discover/tv?with_watch_providers=1899&watch_region=US&sort_by=popularity.desc', label: 'HBO Max', mediaType: 'tv'),
          DiscoverCategory(id: '/discover/tv?with_watch_providers=15&watch_region=US&sort_by=popularity.desc', label: 'Hulu', mediaType: 'tv'),
          DiscoverCategory(id: '/discover/tv?with_watch_providers=283&watch_region=US&sort_by=popularity.desc', label: 'Crunchyroll', mediaType: 'tv'),
          DiscoverCategory(id: '/discover/movie?with_watch_providers=192&watch_region=US&sort_by=popularity.desc', label: 'YouTube', mediaType: 'movie'),
          DiscoverCategory(id: '/discover/movie?with_watch_providers=531&watch_region=US&sort_by=popularity.desc', label: 'Paramount+', mediaType: 'movie'),
          DiscoverCategory(id: '/discover/tv?with_networks=160&sort_by=popularity.desc', label: 'Bilibili', mediaType: 'tv'),
          DiscoverCategory(id: '/discover/tv?with_networks=1419&sort_by=popularity.desc', label: '优酷', mediaType: 'tv'),
          DiscoverCategory(id: '/discover/tv?with_networks=1330&sort_by=popularity.desc', label: '爱奇艺', mediaType: 'tv'),
          DiscoverCategory(id: '/discover/tv?with_networks=2007&sort_by=popularity.desc', label: '腾讯视频', mediaType: 'tv'),
        ],
      ReviewSource.imdb => const [
          DiscoverCategory(id: 'movie/trending', label: 'IMDb 热门电影', mediaType: 'movie'),
          DiscoverCategory(id: 'series/trending', label: 'IMDb 热门剧集', mediaType: 'tv'),
          DiscoverCategory(id: 'movie/popular', label: 'IMDb 流行电影', mediaType: 'movie'),
          DiscoverCategory(id: 'series/popular', label: 'IMDb 流行剧集', mediaType: 'tv'),
          DiscoverCategory(id: 'movie/top', label: 'IMDb Top 电影', mediaType: 'movie'),
          DiscoverCategory(id: 'series/top', label: 'IMDb Top 剧集', mediaType: 'tv'),
        ],
    };

class DiscoverEntry {
  const DiscoverEntry({
    required this.id,
    required this.title,
    required this.source,
    this.originalTitle,
    this.posterUrl,
    this.backdropUrl,
    this.rating,
    this.year,
    this.overview,
    this.mediaType = 'movie',
    this.tmdbId,
    this.imdbId,
    this.doubanId,
    this.genres = const [],
  });

  final String id;
  final String title;
  final String? originalTitle;
  final ReviewSource source;
  final String? posterUrl;
  final String? backdropUrl;
  final double? rating;
  final String? year;
  final String? overview;
  final String mediaType;
  final String? tmdbId;
  final String? imdbId;
  final String? doubanId;
  final List<String> genres;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'source': source.name,
        if (originalTitle != null) 'originalTitle': originalTitle,
        if (posterUrl != null) 'posterUrl': posterUrl,
        if (backdropUrl != null) 'backdropUrl': backdropUrl,
        if (rating != null) 'rating': rating,
        if (year != null) 'year': year,
        if (overview != null) 'overview': overview,
        'mediaType': mediaType,
        if (tmdbId != null) 'tmdbId': tmdbId,
        if (imdbId != null) 'imdbId': imdbId,
        if (doubanId != null) 'doubanId': doubanId,
        'genres': genres,
      };

  factory DiscoverEntry.fromJson(Map<String, dynamic> json) => DiscoverEntry(
        id: '${json['id'] ?? ''}',
        title: '${json['title'] ?? ''}',
        source: reviewSourceFromWire(json['source']?.toString()),
        originalTitle: json['originalTitle']?.toString(),
        posterUrl: json['posterUrl']?.toString(),
        backdropUrl: json['backdropUrl']?.toString(),
        rating: (json['rating'] as num?)?.toDouble(),
        year: json['year']?.toString(),
        overview: json['overview']?.toString(),
        mediaType: json['mediaType']?.toString() ?? 'movie',
        tmdbId: json['tmdbId']?.toString(),
        imdbId: json['imdbId']?.toString(),
        doubanId: json['doubanId']?.toString(),
        genres: (json['genres'] as List?)?.map((e) => '$e').toList() ?? const [],
      );
}

class ReviewRating {
  const ReviewRating({required this.source, required this.value});
  final ReviewSource source;
  final double? value;
}
