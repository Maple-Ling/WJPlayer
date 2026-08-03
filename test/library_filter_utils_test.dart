import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/utils/library_filter_utils.dart';

void main() {
  test('buildYearChips: 当前十年逐年 + 更早按年代分桶', () {
    final chips = buildYearChips(
      ['2026', '2024', '2020', '2019', '2008', '1995', 'bad', '0'],
      currentYear: 2026,
    );
    final labels = chips.map((c) => c.label).toList();
    expect(labels, ['2026', '2024', '2020', '10年代', '00年代', '90年代']);

    // 逐年项 csv 即自身
    expect(chips.firstWhere((c) => c.label == '2024').yearsCsv, '2024');
    // 年代项展开为该十年的全部年份
    expect(chips.firstWhere((c) => c.label == '10年代').yearsCsv,
        '2010,2011,2012,2013,2014,2015,2016,2017,2018,2019');
    expect(chips.firstWhere((c) => c.label == '00年代').yearsCsv.split(',').first,
        '2000');
  });

  test('LibraryFilterValue: 单选切换与激活计数', () {
    const v0 = LibraryFilterValue();
    expect(v0.isEmpty, true);
    expect(v0.activeCount, 0);

    final v1 = v0.withGenre('喜剧').withStudio('正午阳光', '7').withYear('2024', '2024');
    expect(v1.activeCount, 3);
    expect(v1.isEmpty, false);

    // 取消年份，其余保留（哨兵区分"不改"与"置空"）
    final v2 = v1.withYear(null, null);
    expect(v2.activeCount, 2);
    expect(v2.genre, '喜剧');
    expect(v2.studio, '正午阳光');

    expect(v1,
        v0.withGenre('喜剧').withStudio('正午阳光', '7').withYear('2024', '2024')); // 值相等

    // 评分区间算一个激活维度；清除回到空。
    final v3 = v0.withRating(7.0, 9.0);
    expect(v3.activeCount, 1);
    expect(v3.ratingMin, 7.0);
    expect(v3.ratingMax, 9.0);
    expect(v3.withRating(null, null).isEmpty, true);
  });

  test('toggledSort: 同字段切升降序、换字段用默认序', () {
    const v0 = LibraryFilterValue();
    expect(v0.sortBy, 'SortName');
    expect(v0.sortDescending, false);

    // 点已选中的 SortName：升->降
    final v1 = v0.toggledSort('SortName');
    expect(v1.sortBy, 'SortName');
    expect(v1.sortDescending, true);

    // 换到新字段 DateCreated：默认降序（最近更新在前）
    final v2 = v1.toggledSort('DateCreated');
    expect(v2.sortBy, 'DateCreated');
    expect(v2.sortDescending, true);
    // 再点一次：降->升
    expect(v2.toggledSort('DateCreated').sortDescending, false);

    // 排序不计入筛选激活数；清除回默认序。
    expect(v2.activeCount, 0);
    expect(v2.cleared().sortBy, 'SortName');
    expect(v2.cleared().sortDescending, false);
  });

  test('sortByPinyin: 中文按拼音首字母、英文原样，混合升序', () {
    // 爱情(a) < 科幻(k) < 战争(z)；Drama(d) 落在 a 与 k 之间。
    final sorted = sortByPinyin(['科幻', '战争', '爱情', 'Drama']);
    expect(sorted, ['爱情', 'Drama', '科幻', '战争']);
    // 原列表不被修改。
    final src = ['科幻', '爱情'];
    sortByPinyin(src);
    expect(src, ['科幻', '爱情']);
  });
}
