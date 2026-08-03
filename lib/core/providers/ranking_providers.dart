import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/ranking/ranking_models.dart';
import '../api/ranking/ranking_service.dart';
import 'app_preferences.dart';

/// 排行榜功能开关（默认关闭）。开启后三端 Tab/侧边栏出现「排行榜」入口。
final rankingEnabledProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('wjplayer_ranking_enabled'),
    writeValue: (prefs, value) async {
      await prefs.setBool('wjplayer_ranking_enabled', value);
    },
  );
});

/// 排行榜聚合服务（单例）。
final rankingServiceProvider =
    Provider<RankingService>((ref) => RankingService());

/// 当前构建可用的一级分组（动漫/电影/剧集，取决于是否配置了对应数据源）。
final rankingGroupsProvider = Provider<List<RankingGroup>>((ref) {
  return ref.watch(rankingServiceProvider).availableGroups;
});

/// 某分组下的可用子分类。
final rankingCategoriesProvider =
    Provider.family<List<RankingCategory>, RankingGroup>((ref, group) {
  return ref.watch(rankingServiceProvider).categoriesOf(group);
});

/// 按分类 id 拉取榜单（带缓存）。
final rankingListProvider =
    FutureProvider.family<List<RankingEntry>, String>((ref, categoryId) async {
  return ref.watch(rankingServiceProvider).fetch(categoryId);
});
