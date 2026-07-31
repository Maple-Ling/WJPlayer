import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/services/sync/calendar_models.dart';
import 'package:wjplayer/core/services/sync/sync_models.dart';

void main() {
  // 固定「今天」为 2026-07-10（周五，weekday=5）以便断言标签/顺序。
  final today = DateTime(2026, 7, 10);

  CalendarEntry trakt(DateTime d) =>
      CalendarEntry(title: 't', source: SyncService.trakt, airDate: d);
  CalendarEntry bgm(int wd) =>
      CalendarEntry(title: 'b', source: SyncService.bangumi, weekday: wd);

  test('Trakt：按日期升序，今天/明天标签正确', () {
    final sections = groupCalendarEntries([
      trakt(DateTime(2026, 7, 12, 20)),
      trakt(DateTime(2026, 7, 10, 9)),
      trakt(DateTime(2026, 7, 11)),
    ], now: today);

    expect(sections.map((s) => s.header).toList(),
        ['今天', '明天', '7月12日 周日']);
    expect(sections.first.isToday, isTrue);
  });

  test('Bangumi：按星期从今天(周五)起排一圈', () {
    // 今天周五(5)、周一(1)、周日(7) → 顺序应为 五、日、一（一在下一周）。
    final sections = groupCalendarEntries([
      bgm(1),
      bgm(5),
      bgm(7),
    ], now: today);

    expect(sections.map((s) => s.header).toList(), ['周五', '周日', '周一']);
    expect(sections.first.isToday, isTrue);
  });
}
