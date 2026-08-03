import 'ranking_cache.dart';
import 'ranking_models.dart';
import 'ranking_source_dandan.dart';
import 'ranking_source_tmdb.dart';

/// 排行榜聚合服务：按分类路由到弹弹Play / TMDB，套一层缓存。
class RankingService {
  final DandanRankingSource _dandan;
  final TmdbRankingSource _tmdb;

  RankingService({DandanRankingSource? dandan, TmdbRankingSource? tmdb})
      : _dandan = dandan ?? DandanRankingSource(),
        _tmdb = tmdb ?? TmdbRankingSource();

  bool get animeConfigured => _dandan.isConfigured;
  bool get videoConfigured => _tmdb.isConfigured;

  /// 当前构建可用的分类：动漫需弹弹凭据，影视需 TMDB 密钥。都没有 → 空。
  List<RankingCategory> get availableCategories => kRankingCategories.where((c) {
        return switch (c.source) {
          RankingSource.dandan => animeConfigured,
          RankingSource.tmdb => videoConfigured,
        };
      }).toList();

  /// 可用的一级分组（去重、保序）。
  List<RankingGroup> get availableGroups {
    final seen = <RankingGroup>{};
    final out = <RankingGroup>[];
    for (final c in availableCategories) {
      if (seen.add(c.group)) out.add(c.group);
    }
    return out;
  }

  List<RankingCategory> categoriesOf(RankingGroup group) =>
      availableCategories.where((c) => c.group == group).toList();

  RankingCategory? categoryById(String id) {
    for (final c in kRankingCategories) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 拉取某分类榜单。默认命中 6 小时缓存；[forceRefresh] 绕过缓存。
  Future<List<RankingEntry>> fetch(String categoryId,
      {bool forceRefresh = false}) async {
    final cat = categoryById(categoryId);
    if (cat == null) return const [];
    if (!forceRefresh) {
      final cached = await RankingCache.instance.get(categoryId);
      if (cached != null) return cached;
    }
    final list = switch (cat.source) {
      RankingSource.dandan => await _dandan.fetch(cat),
      RankingSource.tmdb => await _tmdb.fetch(cat),
    };
    if (list.isNotEmpty) await RankingCache.instance.put(categoryId, list);
    return list;
  }
}
