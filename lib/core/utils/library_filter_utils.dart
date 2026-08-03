/// 媒体库筛选：年份分桶 + 选中状态。纯逻辑，无 Flutter 依赖，便于测试。
///
/// Emby `/Items/Filters` 一次性返回某媒体库的 Genres / Years / Tags 等可选值，
/// 不必逐页拉取全部条目。年份可能很多（1950..今年），所以「当前十年」逐年展示、
/// 更早的按十年代分桶（如 `10年代` = 2010–2019），贴近影视站的时间筛选行。
library;

import 'package:lpinyin/lpinyin.dart';

/// 取一个字符串的拼音小写形式（中文转拼音、英文/数字原样），用于排序键与搜索匹配。
String pinyinOf(String s) {
  final p =
      PinyinHelper.getPinyinE(s.trim(), separator: '', defPinyin: '').toLowerCase();
  return p.isEmpty ? s.trim().toLowerCase() : p;
}

/// 按拼音首字母升序排序（中文转拼音、英文/数字原样），用于筛选弹窗里那一长串
/// 类型/标签/工作室的取值列表。原列表不变，返回新列表。
List<String> sortByPinyin(List<String> items) {
  final copy = [...items];
  copy.sort((a, b) => pinyinOf(a).compareTo(pinyinOf(b)));
  return copy;
}

/// 一个时间筛选项：[label] 显示文案，[yearsCsv] 传给 Emby `Years=` 的逗号分隔值。
class YearChip {
  final String label;
  final String yearsCsv;
  const YearChip(this.label, this.yearsCsv);
}

/// 把 Emby 返回的年份列表整理成「当前十年逐年 + 更早按年代分桶」的筛选项。
///
/// [years] 为字符串年份（Emby Filters.years），[currentYear] 注入便于测试。
/// 规则与常见影视站一致：当前十年（含今年）逐年降序，更早的并入对应「xx年代」。
List<YearChip> buildYearChips(List<String> years, {required int currentYear}) {
  final ints = <int>{};
  for (final y in years) {
    final n = int.tryParse(y.trim());
    if (n != null && n > 0) ints.add(n);
  }
  final sorted = ints.toList()..sort((a, b) => b.compareTo(a)); // 降序
  final decadeStart = (currentYear ~/ 10) * 10;

  final chips = <YearChip>[];
  // 当前十年：逐年。
  for (final y in sorted) {
    if (y >= decadeStart) chips.add(YearChip('$y', '$y'));
  }
  // 更早：按十年代分桶（降序，去重）。
  final olderDecades = <int>{};
  for (final y in sorted) {
    if (y < decadeStart) olderDecades.add((y ~/ 10) * 10);
  }
  final decadesDesc = olderDecades.toList()..sort((a, b) => b.compareTo(a));
  for (final d in decadesDesc) {
    final two = (d % 100).toString().padLeft(2, '0'); // 2010->"10", 2000->"00"
    final csv = List.generate(10, (i) => '${d + i}').join(',');
    // ponytail: %02d 让 1900 与 2000 都成「00年代」，世纪碰撞，剧集年份极少触及，先不处理。
    chips.add(YearChip('$two年代', csv));
  }
  return chips;
}

/// 当前选中的筛选值（单选/组）。空串视为未选。
/// genre/tag 直接是 Emby 的可选值；year 用 [yearLabel] 高亮、[yearsCsv] 查询。
class LibraryFilterValue {
  final String? genre;
  final String? tag;
  final String? studio; // 显示名
  final String? studioId; // 查询用（Emby StudioIds）
  final String? yearLabel;
  final String? yearsCsv;
  final double? ratingMin;
  final double? ratingMax;

  /// 排序：[sortBy] 为 Emby SortBy 字段（更新时间=DateLastContentAdded，即剧集
  /// 最新一集的入库时间；标题=SortName、
  /// 官方评级=OfficialRating），[sortDescending] 决定升/降序。默认按标题升序。
  final String sortBy;
  final bool sortDescending;

  const LibraryFilterValue({
    this.genre,
    this.tag,
    this.studio,
    this.studioId,
    this.yearLabel,
    this.yearsCsv,
    this.ratingMin,
    this.ratingMax,
    this.sortBy = 'SortName',
    this.sortDescending = false,
  });

  bool get isEmpty =>
      genre == null &&
      tag == null &&
      studio == null &&
      yearsCsv == null &&
      ratingMin == null &&
      ratingMax == null;

  int get activeCount =>
      (genre != null ? 1 : 0) +
      (tag != null ? 1 : 0) +
      (studio != null ? 1 : 0) +
      (yearsCsv != null ? 1 : 0) +
      ((ratingMin != null || ratingMax != null) ? 1 : 0);

  LibraryFilterValue _copy({
    Object? genre = _keep,
    Object? tag = _keep,
    Object? studio = _keep,
    Object? studioId = _keep,
    Object? yearLabel = _keep,
    Object? yearsCsv = _keep,
    Object? ratingMin = _keep,
    Object? ratingMax = _keep,
    Object? sortBy = _keep,
    Object? sortDescending = _keep,
  }) =>
      LibraryFilterValue(
        genre: genre == _keep ? this.genre : genre as String?,
        tag: tag == _keep ? this.tag : tag as String?,
        studio: studio == _keep ? this.studio : studio as String?,
        studioId: studioId == _keep ? this.studioId : studioId as String?,
        yearLabel: yearLabel == _keep ? this.yearLabel : yearLabel as String?,
        yearsCsv: yearsCsv == _keep ? this.yearsCsv : yearsCsv as String?,
        ratingMin: ratingMin == _keep ? this.ratingMin : ratingMin as double?,
        ratingMax: ratingMax == _keep ? this.ratingMax : ratingMax as double?,
        sortBy: sortBy == _keep ? this.sortBy : sortBy as String,
        sortDescending:
            sortDescending == _keep ? this.sortDescending : sortDescending as bool,
      );

  LibraryFilterValue withGenre(String? g) => _copy(genre: g);
  LibraryFilterValue withTag(String? t) => _copy(tag: t);
  LibraryFilterValue withStudio(String? name, String? id) =>
      _copy(studio: name, studioId: id);
  LibraryFilterValue withYear(String? label, String? csv) =>
      _copy(yearLabel: label, yearsCsv: csv);
  LibraryFilterValue withRating(double? min, double? max) =>
      _copy(ratingMin: min, ratingMax: max);

  /// 点排序按钮：选中同一字段则升/降序互换；切到新字段则用其默认序
  /// （标题升序、其余降序——最近更新/高评级在前更符合直觉）。
  LibraryFilterValue toggledSort(String key) => sortBy == key
      ? _copy(sortDescending: !sortDescending)
      : _copy(sortBy: key, sortDescending: key != 'SortName');

  LibraryFilterValue cleared() => const LibraryFilterValue();

  @override
  bool operator ==(Object other) =>
      other is LibraryFilterValue &&
      other.genre == genre &&
      other.tag == tag &&
      other.studio == studio &&
      other.studioId == studioId &&
      other.yearLabel == yearLabel &&
      other.yearsCsv == yearsCsv &&
      other.ratingMin == ratingMin &&
      other.ratingMax == ratingMax &&
      other.sortBy == sortBy &&
      other.sortDescending == sortDescending;

  @override
  int get hashCode => Object.hash(genre, tag, studio, studioId, yearLabel,
      yearsCsv, ratingMin, ratingMax, sortBy, sortDescending);
}

/// _copy 的"保持原值"哨兵——区分"不改"与"显式置 null"。
const Object _keep = Object();
