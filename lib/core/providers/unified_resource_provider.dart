import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sources/unified_media_adapter.dart';

/// 详情页 → 播放页共享的统一媒体资源数据源。
/// 详情页在启动播放前写入，播放页从中读取媒体信息、音轨、字幕列表。
final unifiedResourceProvider = StateProvider<UnifiedMediaResource?>((ref) => null);
