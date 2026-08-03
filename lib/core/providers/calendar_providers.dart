import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_preferences.dart';
import 'sync_providers.dart';
import '../services/sync/calendar_models.dart';
import '../services/sync/sync_models.dart';

const String _calendarSourceKey = 'wjplayer_calendar_source';
const String _calendarTabKey = 'wjplayer_calendar_in_tab';

/// 追剧日历的数据来源（trakt / bangumi），持久化。
final calendarSourceProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: SyncService.trakt.name,
    readValue: (prefs) => prefs.getString(_calendarSourceKey),
    writeValue: (prefs, value) async {
      await prefs.setString(_calendarSourceKey, value);
    },
  );
});

/// 是否把「追剧日历」显示在底部导航栏（移动端），持久化，默认关。
final calendarTabEnabledProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool(_calendarTabKey),
    writeValue: (prefs, value) async {
      await prefs.setBool(_calendarTabKey, value);
    },
  );
});

/// 当前选择的来源枚举。
SyncService calendarSourceOf(String name) =>
    name == SyncService.bangumi.name ? SyncService.bangumi : SyncService.trakt;

/// 追剧日历查询参数：来源 + 是否只看我追的（否则显示整季全部）。
typedef CalendarQuery = ({SyncService source, bool onlyMine});

/// 按来源+范围拉取的追剧日历（autoDispose：每次进入重新拉取）。
final calendarEntriesProvider = FutureProvider.autoDispose
    .family<List<CalendarEntry>, CalendarQuery>((ref, q) {
  return ref
      .read(syncControllerProvider.notifier)
      .fetchCalendar(q.source, onlyMine: q.onlyMine);
});
