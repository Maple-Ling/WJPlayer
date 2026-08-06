import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/watch_history/watch_history_store.dart';

/// 观看记录存储单例（独立文件：server_providers 与 watch_history_providers
/// 都要引用它，放任何一侧都会造成循环 import）。
final watchHistoryStoreProvider = Provider<WatchHistoryStore>((ref) {
  return WatchHistoryStore();
});
