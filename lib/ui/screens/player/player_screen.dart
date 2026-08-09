import 'dart:async';
import 'dart:io';
import 'package:canvas_danmaku/canvas_danmaku.dart' hide DanmakuItem;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/network/prefetch_proxy/prefetch_proxy.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/unified_resource_provider.dart';
import '../../../core/sources/unified_media_adapter.dart';import '../../../core/providers/playback_prefs_store.dart';
import '../../../core/services/cache_service.dart';
import '../../../core/services/danmaku_loader.dart';
import '../../../core/services/system_info_service.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/providers/episode_aggregation_provider.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/services/watch_history/watch_history_models.dart';
import '../../../core/providers/sync_providers.dart';
import '../../../core/providers/download_providers.dart';
import '../../../core/services/download/download_helper.dart';
import '../../widgets/common/danmaku_search_widget.dart';
import '../../widgets/common/danmaku_blockword_manager.dart';
import '../../widgets/common/media_widgets.dart';
import '../../utils/media_helpers.dart';
import '../source/unified_media_screens.dart';
import '../../../core/services/video_player_service.dart';
import '../../../core/services/exo_player_adapter.dart';
import '../../../core/services/native_mpv_player_adapter.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/font_service.dart';
import '../../../core/services/player_subtitle_loader.dart';
import '../../../core/services/subtitle_processor.dart';
import '../../../core/services/translation/translation_actions.dart';
import '../../../core/services/translation/translation_engine.dart';
import '../../../core/services/translation/streaming_subtitle_translator.dart';
import '../../../core/services/intro_skip_controller.dart';
import '../../../core/api/danmaku/danmaku_service.dart';
import '../../../core/services/danmaku_auto_loader.dart';
import '../../../core/utils/danmaku_postprocess.dart';
import '../../../core/utils/playback_error_text.dart';
import '../../../core/utils/playback_url_resolver.dart';
import '../../../core/utils/track_preference.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/services/tv_key_channel.dart';
import '../../../core/widgets/player_settings_panel.dart';
import '../../../core/widgets/player_capsule_menu.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/feiniu_backend.dart';
import '../../../core/sources/source_playback.dart';
import '../../../core/sources/source_registry.dart';
import '../../widgets/common/source_quality_button.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/player/player_controls.dart';
import '../../widgets/player/player_overlay.dart';
import '../../widgets/player/popup_menu_overlay.dart';

part 'player_screen_state.dart';
part 'player_screen_panels.dart';

/// 播放页
class PlayerScreen extends ConsumerStatefulWidget {
  final String itemId;
  final String? mediaSourceId;

  /// 详情页针对本次播放选择的内核；null 使用全局默认。
  final String? playerCoreOverride;

  /// 非空表示「网盘/聚合源直链播放」：跳过 Emby PlaybackInfo，直接用
  /// [MediaSourceBackend.resolvePlay] 的 URL + 逐流 headers 喂内核，
  /// 复用本播放页全部能力（弹幕/字幕/手势/续播）。
  final SourcePlayback? sourcePlay;

  /// 指定起播位置（聚合切换源续播用，单位秒）；null 走默认续播逻辑。
  final Duration? startPosition;

  const PlayerScreen({
    super.key,
    required this.itemId,
    this.mediaSourceId,
    this.playerCoreOverride,
    this.sourcePlay,
    this.startPosition,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}
