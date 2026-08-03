import 'sync_models.dart' show SyncService;

/// 追剧日历的一条放送记录（Trakt 或 Bangumi 归一化后）。
class CalendarEntry {
  /// 剧名（首选本地化名）。
  final String title;

  /// 副标题：Trakt 为「S01E05 · 集标题」，Bangumi 为评分/放送信息（可空）。
  final String? subtitle;

  /// 精确放送时刻（Trakt 有；已转本地时区）。为空时用 [weekday] 归组。
  final DateTime? airDate;

  /// 每周放送日 1=周一…7=周日（Bangumi 用；[airDate] 为空时有效）。
  final int? weekday;

  /// 封面图（Bangumi 直接给；Trakt 无图，后续用 [tmdbId] 从 TMDB 补）。
  final String? imageUrl;

  /// TMDB 剧集 id（Trakt 条目带，用于补封面）。
  final int? tmdbId;

  final SyncService source;

  const CalendarEntry({
    required this.title,
    required this.source,
    this.subtitle,
    this.airDate,
    this.weekday,
    this.imageUrl,
    this.tmdbId,
  });

  CalendarEntry copyWith({String? imageUrl}) => CalendarEntry(
        title: title,
        source: source,
        subtitle: subtitle,
        airDate: airDate,
        weekday: weekday,
        imageUrl: imageUrl ?? this.imageUrl,
        tmdbId: tmdbId,
      );
}

/// 星期简称，索引 = DateTime.weekday - 1（1=周一…7=周日）。
const List<String> calendarWeekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

/// 一个日期/星期分组（供三端 UI 复用）。
class CalendarSection {
  final String header;
  final bool isToday;
  final List<CalendarEntry> items;
  const CalendarSection(this.header, this.isToday, this.items);
}

/// 把放送记录归组：Trakt（有精确日期）按日期升序；Bangumi（只有星期）按每周
/// 放送日、从今天所在星期起排一圈。纯逻辑，三端共用。
List<CalendarSection> groupCalendarEntries(
  List<CalendarEntry> entries, {
  DateTime? now,
}) {
  final ref = now ?? DateTime.now();
  final today = DateTime(ref.year, ref.month, ref.day);

  if (entries.any((e) => e.airDate != null)) {
    final byDay = <DateTime, List<CalendarEntry>>{};
    for (final e in entries) {
      final d = e.airDate ?? ref;
      final key = DateTime(d.year, d.month, d.day);
      byDay.putIfAbsent(key, () => []).add(e);
    }
    final keys = byDay.keys.toList()..sort();
    return keys.map((k) {
      final diff = k.difference(today).inDays;
      final label = diff == 0
          ? '今天'
          : diff == 1
              ? '明天'
              : '${k.month}月${k.day}日 周${calendarWeekdayNames[k.weekday - 1]}';
      return CalendarSection(label, diff == 0, byDay[k]!);
    }).toList();
  }

  final byWeekday = <int, List<CalendarEntry>>{};
  for (final e in entries) {
    final wd = e.weekday ?? today.weekday;
    byWeekday.putIfAbsent(wd, () => []).add(e);
  }
  final out = <CalendarSection>[];
  for (var i = 0; i < 7; i++) {
    final wd = ((today.weekday - 1 + i) % 7) + 1; // 从今天起排一圈
    final items = byWeekday[wd];
    if (items == null || items.isEmpty) continue;
    out.add(CalendarSection('周${calendarWeekdayNames[wd - 1]}', i == 0, items));
  }
  return out;
}
