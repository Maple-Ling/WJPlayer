import '../api/api_interfaces.dart';
import 'danmaku_filter.dart';

/// 弹幕后处理：屏蔽词过滤 + 时间窗口去重。手动搜索面板与自动加载共用，
/// 保证两条路径得到一致的弹幕（此前去重逻辑只在搜索面板里）。
List<DanmakuItem> applyDanmakuFilterAndDedup(
  List<DanmakuItem> input, {
  required List<String> blockwords,
  required bool dedup,
  required double dedupWindow,
}) {
  var items = input;
  if (blockwords.isNotEmpty) {
    final filter = DanmakuFilter()..importBlockwords(blockwords);
    items = items
        .where((it) => !filter.shouldFilter(it.text, userId: it.userId))
        .toList();
  }
  if (dedup) items = _dedup(items, dedupWindow);
  return items;
}

List<DanmakuItem> _dedup(List<DanmakuItem> items, double windowSeconds) {
  items.sort((a, b) => a.time.compareTo(b.time));
  final result = <DanmakuItem>[];
  final used = List<bool>.filled(items.length, false);
  for (var i = 0; i < items.length; i++) {
    if (used[i]) continue;
    var count = 1;
    for (var j = i + 1; j < items.length; j++) {
      if (used[j]) continue;
      if (items[j].time - items[i].time > windowSeconds) break;
      if (items[j].text == items[i].text && items[j].type == items[i].type) {
        count++;
        used[j] = true;
      }
    }
    result.add(DanmakuItem(
      time: items[i].time,
      text: items[i].text,
      type: items[i].type,
      color: items[i].color,
      size: items[i].size,
      source: items[i].source,
      cid: items[i].cid,
      userId: items[i].userId,
      count: count,
    ));
  }
  return result;
}
