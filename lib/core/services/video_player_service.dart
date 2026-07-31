import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_interfaces.dart';
import '../../plugins/runtime/plugin_player_bridge.dart';
import 'app_logger.dart';
import 'player_adapter.dart';
import 'exo_player_adapter.dart';
import 'mpv_player_adapter.dart';
import 'native_mpv_player_adapter.dart';
import 'windows_native_mpv_adapter.dart';

/// 播放器内核类型
enum PlayerCoreType {
  exoPlayer,  // ExoPlayer（Android 原生）
  mpv,        // MPV（libmpv FFI，桌面/iOS）
  nativeMpv,  // MPV 原生 JNI（Android 专用，通过平台通道调用）
}

/// 重解析得到的播放地址：[url] 为主地址，[fallbackUrl] 为转码兜底地址（可空）。
typedef ResolvedStreamUrls = ({String url, String? fallbackUrl});

/// 重解析回调：重走 PlaybackInfo→重签 302，产出全新 [ResolvedStreamUrls]。
/// 用于播放中断流（网盘 302 过期 / 跨境硬断）后在当前线路内重新取流续播。
typedef StreamUrlResolver = Future<ResolvedStreamUrls?> Function();

/// 视频播放器服务
///
/// 支持动态切换播放器内核：
/// - ExoPlayer: Android 原生，轻量稳定
/// - MPV: libmpv FFI，全格式支持、HDR、高级字幕控制
class VideoPlayerService extends ChangeNotifier {
  static final AppLogger _logger = AppLogger();
  static const int _maxDirectRetryCount = 5;

  PlayerAdapter? _adapter;
  PlayerCoreType _coreType = PlayerCoreType.exoPlayer;
  bool _hasReportedStart = false;
  bool _lastInitializationUsedFallback = false;
  String? _lastFallbackReason;
  Duration? _initialStartPosition;
  bool _lastDolbyVisionFix = false;
  bool _lastUseLibass = false;
  String? _lastPreferredSubtitleLanguage;
  bool _lastHardwareDecoding = true;
  bool _lastStartWithSoftwareDecoding = false;
  // 当前 Anime4K 超分档位（off/modeA/…）。跨适配器重建保留，初始化时回传给内核，
  // 让 media_kit 在开超分时选硬件纹理、原生 mpv 解析出 shader 链。
  String _superResolutionLevel = 'off';
  // Windows 硬解「零拷贝」(d3d11va)：与 ANGLE 同 D3D11 后端，解码帧直接共享、免每帧拷回，
  // 实测消除硬件纹理下的卡/闪，故 Windows **默认开**；关掉回落 auto-copy(拷回,兼容兜底)。
  // 会话级不落盘：万一某显卡 d3d11va 起不来，mpv 自会降级软解(不崩),重启也回默认。
  bool _zeroCopyHwdec = Platform.isWindows;
  // M1 · Windows 原生渲染（--wid 子窗口直出，绕开 ANGLE）。开启后 Windows + mpv 内核
  // 走 WindowsNativeMpvAdapter；切换在下次起播生效。
  // ⚠️ 必须 static + 持久化：VideoPlayerService 每次进播放页都新建实例（非单例），
  // 放实例字段会每次复位（"开了退出再播放又自己关上"的根因）。static 跨实例存活、
  // SharedPreferences 跨重启存活——开一次永久生效，直到用户主动关。
  static bool _windowsNativeRender = false;
  static bool _nativeRenderHydrated = false;
  static const String _kNativeRenderPrefKey = 'windows_native_render';
  String? _primaryVideoUrl;
  String? _fallbackVideoUrl;
  // 逐流取流鉴权（网盘/聚合源直链）：主/兜底链路与适配器重建都复用同一份。
  Map<String, String>? _httpHeaders;
  String? _userAgentOverride;
  bool _fallbackActivated = false;
  bool _autoRetryInFlight = false;
  int _startupRetryCount = 0;

  /// L2 重解析回调（在线播放时由播放页注入；离线/本地文件为 null → 退回旧行为）。
  StreamUrlResolver? _streamUrlResolver;

  /// 播放中断流恢复的可重入守卫。
  bool _recoverInFlight = false;

  /// 防止服务器持续不可用时无限重解析刷接口：滚动窗口内自动恢复失败过多就停手，
  /// 暴露错误让用户手动重试 / 切换线路（被动失败才计数，用户主动恢复 preemptive 不受限）。
  static const int _kMaxRecoverFailuresInWindow = 3;
  static const Duration _kRecoverWindow = Duration(seconds: 90);
  int _recoverFailureCount = 0;
  DateTime? _recoverWindowStart;

  /// L2.5 暂停陷阱：记录进入暂停的时刻；恢复时若超过 TTL 先重解析，避免撞死的网盘签名链。
  DateTime? _pausedAt;

  /// 网盘 302 签名链的保守存活时长（默认值）。暂停超过它再恢复就先重取流。
  /// 实际生效值由 [initialize] 的 streamUrlTtl 注入（L0 按服务器形态调档：
  /// 302 网盘调短、硬盘直传可放宽/接近不触发）。
  static const Duration _kStreamUrlTtl = Duration(minutes: 5);

  /// 当前生效的签名链 TTL（L0 注入；null 时退回 [_kStreamUrlTtl]）。
  Duration? _streamUrlTtl;
  Duration get _effectiveStreamUrlTtl => _streamUrlTtl ?? _kStreamUrlTtl;
  String? _selectedSubtitleTrackId;
  String? _selectedAudioTrackId;
  int? _surfaceViewId;  // For gpu-next rendering on Android
  bool _useGpuNext = false;  // gpu-next rendering mode

  Timer? _progressTimer;
  Timer? _hideControlsTimer;
  Timer? _pendingPlaybackTimer;
  bool? _pendingPlayingState;

  // 手势状态
  bool _showControls = true;
  bool _isLocked = false;
  bool _isDragging = false;
  bool _isScrubbingPosition = false;
  double _dragStartX = 0;
  double _dragStartY = 0;
  Duration _dragStartPosition = Duration.zero;
  Duration _dragPreviewPosition = Duration.zero;
  double _dragStartVolume = 1.0;
  double _currentBrightness = 1.0;
  double _dragStartBrightness = 1.0;

  /// 手势轴锁定：0=未定向, 1=水平(进度), 2=竖向(亮度/音量), -1=已判定但本次手势不响应。
  /// 一旦定向即锁死整段手势，避免竖向调亮度/音量时手指轻微横移误触发进度跳变。
  int _gestureAxis = 0;

  /// 交互区配置（由播放页从设置项注入，缺省维持旧行为：左亮度/右音量、横向可调进度）。
  String _leftVerticalAction = 'brightness';
  String _rightVerticalAction = 'volume';
  bool _horizontalSeekEnabled = true;

  // 播放上报
  String? _currentItemId;
  String? _mediaSourceId;
  String? _playSessionId;
  Function(PlaybackProgressInfo)? _onProgressReport;
  Function(PlaybackStartInfo)? _onStartReport;
  Function(PlaybackStopInfo)? _onStopReport;

  // Getters
  bool get isPlaying => _adapter?.isPlaying ?? false;
  bool get isBuffering => _adapter?.isBuffering ?? false;
  bool get isInitialized => _adapter?.isInitialized ?? false;
  bool get hasError => (_adapter?.hasError ?? false) && !_autoRetryInFlight;
  String? get errorMessage => hasError ? _adapter?.errorMessage : null;
  Duration get position => _adapter?.position ?? Duration.zero;
  Duration get duration => _adapter?.duration ?? Duration.zero;
  double get speed => _adapter?.speed ?? 1.0;
  double get volume => _adapter?.volume ?? 1.0;
  bool get showControls => _showControls;
  bool get isLocked => _isLocked;
  bool get isDragging => _isDragging;
  bool get isScrubbingPosition => _isScrubbingPosition;
  bool get isCompleted => _adapter?.isCompleted ?? false;
  double get progress => _adapter?.progress ?? 0.0;

  /// 已缓冲到的位置（缓存进度）。不支持的内核返回 [Duration.zero]。
  Duration get bufferedPosition => _adapter?.bufferedPosition ?? Duration.zero;

  /// 缓存进度 0.0-1.0（进度条上「已缓冲」区间的宽度因子）。
  double get bufferedProgress {
    final d = duration.inMilliseconds;
    if (d <= 0) return 0.0;
    return (bufferedPosition.inMilliseconds / d).clamp(0.0, 1.0).toDouble();
  }

  PlayerCoreType get coreType => _coreType;
  bool get lastInitializationUsedFallback => _lastInitializationUsedFallback;
  String? get lastFallbackReason => _lastFallbackReason;
  Duration get dragPreviewPosition => _dragPreviewPosition;
  bool get isPlaybackActionPending => _pendingPlayingState != null;

  /// 当前播放器适配器（用于内核特定操作）
  PlayerAdapter? get adapter => _adapter;

  double get brightness => _currentBrightness;

  /// 手势起始 X 坐标（用于判断亮度/音量区域）
  double get dragStartX => _dragStartX;

  /// 注入交互区设置（播放页在每次手势开始前调用，保证用最新配置）。
  void configureGestures({
    required String leftVerticalAction,
    required String rightVerticalAction,
    required bool horizontalSeekEnabled,
  }) {
    _leftVerticalAction = leftVerticalAction;
    _rightVerticalAction = rightVerticalAction;
    _horizontalSeekEnabled = horizontalSeekEnabled;
  }

  /// 当前竖向手势是否正在调节亮度/音量（用于决定是否显示亮度/音量指示器）。
  bool get isAdjustingLevel => _isDragging && _gestureAxis == 2;

  /// 按手势起点所在半屏解析出的竖向动作（'brightness'/'volume'/'none'）。
  String get activeVerticalAction => _gestureAxisStartedLeft
      ? _leftVerticalAction
      : _rightVerticalAction;

  /// 手势起点是否落在左半屏（指示器据此取亮度/音量数值）。
  bool _gestureAxisStartedLeft = true;

  /// 拖动方向：1=向前, -1=向后, 0=无
  int get dragDirection {
    if (!_isDragging) return 0;
    final dx =
        _dragPreviewPosition.inMilliseconds - _dragStartPosition.inMilliseconds;
    if (dx < -500) return 1; // 向后拖 = 快进
    if (dx > 500) return -1; // 向前拖 = 快退
    return 0;
  }

  /// Flutter Texture ID（用于 Texture widget 渲染视频，旧架构）
  int? get textureId => _adapter?.textureId;

  /// 构建视频渲染 Widget
  ///
  /// ExoPlayer 返回 Texture widget，media_kit 返回 Video widget
  Widget buildVideo() {
    return _adapter?.buildVideo() ??
        const Center(
          child: CircularProgressIndicator(),
        );
  }

  /// libass 是否已就绪
  bool get libassReady => _adapter?.libassReady ?? false;

  /// 获取当前可用轨道列表
  List<Map<String, dynamic>> get tracksInfo => _adapter?.getTracksInfo() ?? [];

  VideoPlayerService() {
    // 首次构造时从磁盘水合原生渲染开关（幂等，只跑一次）。播放页 initState 建实例，
    // 起播在其后，prefs 读得很快，几乎无竞态；用户显式设过则不再被覆盖。
    unawaited(_hydrateNativeRender());
  }

  static Future<void> _hydrateNativeRender() async {
    if (_nativeRenderHydrated) return;
    _nativeRenderHydrated = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      // 原生渲染已封存（真机实测证明它治不了「超分卡」——卡=shader 算力随输出分辨率暴涨，
      // 与渲染管线无关；见 native-rendering-project 记忆）。一次性清掉测试期残留的开启态，
      // 让大家回到 media_kit（带完整 Flutter UI + 可见超分菜单）。原生模式下面板被子窗口
      // 盖住、开关够不到，故必须在这里兜底重置。想再试原生仍可在播放设置面板手动开。
      // v2：原生渲染带出双内核打架 bug + 已被证明对超分非必需（FSR 轻量 shader 在 media_kit
      // 上就够），再次强制关回 media_kit，保完整 UI + 单内核。
      if (prefs.getBool('windows_native_render_parked_v2') != true) {
        await prefs.setBool(_kNativeRenderPrefKey, false);
        await prefs.setBool('windows_native_render_parked_v2', true);
      }
      _windowsNativeRender = prefs.getBool(_kNativeRenderPrefKey) ?? false;
    } catch (_) {}
  }

  /// 设置播放器内核
  void setCoreType(PlayerCoreType type) {
    if (_coreType == type) return;
    _coreType = type;
    if (_adapter?.isInitialized ?? false) {
      // TODO: 重新加载当前视频
    }
    notifyListeners();
  }

  /// 创建适配器
  PlayerAdapter _createAdapter() {
    switch (_coreType) {
      case PlayerCoreType.exoPlayer:
        return ExoPlayerAdapter();
      case PlayerCoreType.mpv:
        if (Platform.isWindows && _windowsNativeRender) {
          return WindowsNativeMpvAdapter();
        }
        return MpvPlayerAdapter();
      case PlayerCoreType.nativeMpv:
        return NativeMpvPlayerAdapter();
    }
  }

  /// 向插件系统暴露的播放控制钩子。
  PluginPlayerHooks? _pluginHooks;

  /// 播放事件附带的基础数据（详细媒体信息由插件 ctx.player.getCurrentMedia 获取）。
  Map<String, dynamic> _pluginEventData() => {
        'itemId': _currentItemId,
        'mediaSourceId': _mediaSourceId,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
      };

  /// 绑定插件播放桥（让插件可控制播放并接收事件）。
  void _bindPluginBridge() {
    final hooks = PluginPlayerHooks();
    hooks.play = () => play();
    hooks.pause = () => pause();
    hooks.seek = (pos) => seekTo(pos);
    _pluginHooks = hooks;
    PluginPlayerBridge.instance.bind(hooks);
  }

  void _bindAdapterCallbacks() {
    _bindPluginBridge();
    _adapter!.setCallbacks(PlayerStateCallbacks(
      onPositionChanged: () => notifyListeners(),
      onDurationChanged: () => notifyListeners(),
      onPlayingStateChanged: () {
        final isNowPlaying = _adapter?.isPlaying ?? false;
        if (_pendingPlayingState == isNowPlaying) {
          _setPendingPlayingState(null, notify: false);
        }
        if (isNowPlaying) {
          if (!_hasReportedStart) {
            _reportStart();
            _hasReportedStart = true;
          }
          _startHideControlsTimer();
          PluginPlayerBridge.instance.emit('onPlay', _pluginEventData());
        } else {
          _cancelHideControlsTimer();
          PluginPlayerBridge.instance.emit('onPause', _pluginEventData());
        }
        notifyListeners();
      },
      onBufferingStateChanged: () => notifyListeners(),
      onCompleted: () {
        notifyListeners();
        // 通知插件系统：一集播放结束（示例 Telegram 插件监听此事件）。
        PluginPlayerBridge.instance.emit('onPlayEnd', _pluginEventData());
        // TODO: 自动播放下一集
      },
      onError: () {
        _setPendingPlayingState(null, notify: false);
        // 已起播后的错误 = 播放中断流(网盘302过期/跨境硬断) → L2 重解析原地续播；
        // 尚未起播的错误 = 起播失败 → 维持原有 5 次直连重试 + 转码兜底。
        if (_hasReportedStart) {
          unawaited(_recoverInPlace());
        } else {
          unawaited(_attemptStartupRetry());
        }
        notifyListeners();
      },
      onSubtitleCue: (text, start, end) =>
          subtitleCueHandler?.call(text, start, end),
    ));
  }

  /// 流式字幕翻译的取词处理器：当前字幕 cue 变化时回调（仅 mpv 内核触发）。
  SubtitleCueCallback? subtitleCueHandler;

  void _setPendingPlayingState(bool? targetState, {bool notify = true}) {
    _pendingPlaybackTimer?.cancel();
    _pendingPlaybackTimer = null;

    final changed = _pendingPlayingState != targetState;
    _pendingPlayingState = targetState;

    if (targetState != null) {
      _pendingPlaybackTimer = Timer(const Duration(milliseconds: 900), () {
        if (_pendingPlayingState == targetState) {
          _pendingPlayingState = null;
          notifyListeners();
        }
      });
    }

    if (notify && changed) {
      notifyListeners();
    }
  }

  Future<void> _initializeAdapterForUrl(
    String videoUrl, {
    required Duration? startPosition,
    required bool hardwareDecoding,
    required String? preferredSubtitleLanguage,
    bool useGpuNext = false,
  }) async {
    await _adapter!.initialize(
      videoUrl: videoUrl,
      startPosition: startPosition,
      dolbyVisionFix: _lastDolbyVisionFix,
      useLibass: _lastUseLibass,
      hardwareDecoding: hardwareDecoding,
      preferredSubtitleLanguage: preferredSubtitleLanguage,
      surfaceViewId: _surfaceViewId,  // Pass for gpu-next rendering
      useGpuNext: useGpuNext,
      httpHeaders: _httpHeaders,
      userAgentOverride: _userAgentOverride,
      superResolutionLevel: _superResolutionLevel,
      zeroCopyHwdec: _zeroCopyHwdec,
    );
    _logger.i('VideoPlayerService', '适配器初始化完成, surfaceViewId=$_surfaceViewId');
    if (!(_adapter?.isInitialized ?? false) || (_adapter?.hasError ?? false)) {
      throw StateError(_adapter?.errorMessage ?? '播放器初始化失败');
    }
  }

  Future<void> _recreateAdapter() async {
    await _adapter?.dispose();
    _adapter = _createAdapter();
    _bindAdapterCallbacks();
  }

  Future<void> _restoreTrackSelections({
    String? audioTrackId,
    String? subtitleTrackId,
  }) async {
    if (audioTrackId != null && audioTrackId.isNotEmpty) {
      try {
        await _adapter!.selectAudioTrack(audioTrackId);
      } catch (e, stackTrace) {
        _logger.eWithStack(
          'VideoPlayerService',
          '恢复音轨选择失败: $audioTrackId',
          e,
          stackTrace,
        );
      }
    }

    if (subtitleTrackId != null && subtitleTrackId.isNotEmpty) {
      try {
        await _adapter!.selectSubtitleTrack(subtitleTrackId);
      } catch (e, stackTrace) {
        _logger.eWithStack(
          'VideoPlayerService',
          '恢复字幕轨选择失败: $subtitleTrackId',
          e,
          stackTrace,
        );
      }
    }
  }

  Future<bool> _tryActivateFallbackUrl({
    required Duration? startPosition,
    required bool hardwareDecoding,
    required String? preferredSubtitleLanguage,
    String? audioTrackId,
    String? subtitleTrackId,
    bool autoPlay = false,
  }) async {
    final fallbackUrl = _fallbackVideoUrl;
    if (_fallbackActivated ||
        fallbackUrl == null ||
        fallbackUrl.isEmpty ||
        fallbackUrl == _primaryVideoUrl) {
      return false;
    }

    _logger.w(
      'VideoPlayerService',
      '主播放链路失败，切换到兜底链路: reason=${_lastFallbackReason ?? 'unknown'}',
    );

    try {
      _fallbackActivated = true;
      await _recreateAdapter();
      await _initializeAdapterForUrl(
        fallbackUrl,
        startPosition: startPosition,
        hardwareDecoding: hardwareDecoding,
        preferredSubtitleLanguage: preferredSubtitleLanguage,
      );
      _primaryVideoUrl = fallbackUrl;
      _lastInitializationUsedFallback = true;
      _startupRetryCount = 0;

      if (autoPlay) {
        await _adapter!.play();
      }

      await _restoreTrackSelections(
        audioTrackId: audioTrackId,
        subtitleTrackId: subtitleTrackId,
      );
      return true;
    } catch (error, stackTrace) {
      _fallbackActivated = false;
      _logger.eWithStack(
        'VideoPlayerService',
        '兜底播放链路初始化失败',
        error,
        stackTrace,
      );
      return false;
    }
  }

  Future<void> _attemptStartupRetry() async {
    if (_autoRetryInFlight ||
        _primaryVideoUrl == null ||
        _primaryVideoUrl!.isEmpty ||
        _adapter == null ||
        !(_adapter?.hasError ?? false) ||
        _startupRetryCount >= _maxDirectRetryCount) {
      return;
    }

    final resumePosition = position > Duration.zero
        ? position
        : (_initialStartPosition ?? Duration.zero);
    final hardwareDecoding =
        _lastStartWithSoftwareDecoding ? false : _lastHardwareDecoding;
    final audioTrackId = _selectedAudioTrackId;
    final subtitleTrackId = _selectedSubtitleTrackId;

    _autoRetryInFlight = true;
    notifyListeners();
    try {
      Object? lastError;
      for (var attempt = _startupRetryCount + 1;
          attempt <= _maxDirectRetryCount;
          attempt++) {
        _startupRetryCount = attempt;
        try {
          _logger.w(
            'VideoPlayerService',
            '播放器直连自动重试: attempt=$attempt, resume=${resumePosition.inMilliseconds}ms',
          );

          await _recreateAdapter();

          await _initializeAdapterForUrl(
            _primaryVideoUrl!,
            startPosition: resumePosition,
            hardwareDecoding: hardwareDecoding,
            preferredSubtitleLanguage: _lastPreferredSubtitleLanguage,
          );

          await _adapter!.play();

          await _restoreTrackSelections(
            audioTrackId: audioTrackId,
            subtitleTrackId: subtitleTrackId,
          );

          _logger.i(
            'VideoPlayerService',
            '播放器直连自动重试成功: attempt=$attempt',
          );
          return;
        } catch (error, stackTrace) {
          lastError = error;
          _logger.eWithStack(
            'VideoPlayerService',
            '播放器直连自动重试失败: attempt=$attempt',
            error,
            stackTrace,
          );
          if (attempt < _maxDirectRetryCount) {
            await Future.delayed(const Duration(milliseconds: 350));
          }
        }
      }
      final fallbackActivated = await _tryActivateFallbackUrl(
        startPosition: resumePosition,
        hardwareDecoding: hardwareDecoding,
        preferredSubtitleLanguage: _lastPreferredSubtitleLanguage,
        audioTrackId: audioTrackId,
        subtitleTrackId: subtitleTrackId,
        autoPlay: true,
      );
      if (fallbackActivated) {
        _logger.i('VideoPlayerService', '播放器已切换到兜底播放链路');
        return;
      }
      throw lastError ?? StateError('播放器直连重试失败');
    } finally {
      _autoRetryInFlight = false;
      notifyListeners();
    }
  }

  /// L2 — 播放中断流的「重解析 + 原地续播」。
  ///
  /// 与起播重试的区别：①重走 PlaybackInfo 拿重签后的新地址（网盘 302 过期的正解，
  /// 因为复用旧字符串可能再撞同一条已重定向的死链）；②优先在同一内核 `reload`（免黑屏），
  /// 仅在内核不支持/重载失败时才整体重建；③用独立的局部重试预算，不受起播 5 次终身计数限制，
  /// 长片多次过期事件不会被一次性耗尽。
  ///
  /// [preemptive] 为 true 时用于 L2.5 暂停陷阱：恢复播放前主动重取流，此时无错误态，
  /// 跳过 hasError 守卫；重解析失败也不算错误，退回用原地址重载（重开 Emby 端点同样重签 302）。
  Future<void> _recoverInPlace({bool preemptive = false}) async {
    if (_disposed || _recoverInFlight || _adapter == null) return;
    if (!preemptive && !(_adapter?.hasError ?? false)) return;

    // 滚动窗口熔断：被动恢复在短时间内连续失败过多 → 停手，暴露错误（用户重试/切线）。
    final windowNow = DateTime.now();
    if (_recoverWindowStart == null ||
        windowNow.difference(_recoverWindowStart!) > _kRecoverWindow) {
      _recoverWindowStart = windowNow;
      _recoverFailureCount = 0;
    }
    if (!preemptive && _recoverFailureCount >= _kMaxRecoverFailuresInWindow) {
      _logger.w(
        'VideoPlayerService',
        '短时间内多次断流恢复失败，停止自动恢复，暴露错误供用户重试/切换线路',
      );
      return;
    }

    _recoverInFlight = true;
    // 复用 _autoRetryInFlight 抑制错误卡片，恢复期间不闪「加载失败」。
    _autoRetryInFlight = true;
    notifyListeners();
    try {
      final resumePosition = position > Duration.zero
          ? position
          : (_initialStartPosition ?? Duration.zero);
      final hardwareDecoding =
          _lastStartWithSoftwareDecoding ? false : _lastHardwareDecoding;
      final audioTrackId = _selectedAudioTrackId;
      final subtitleTrackId = _selectedSubtitleTrackId;

      // 1) 重解析：重走 PlaybackInfo→重签 302。失败则退回原地址（重开 Emby 端点也会重签）。
      var targetUrl = _primaryVideoUrl ?? '';
      final resolver = _streamUrlResolver;
      if (resolver != null) {
        try {
          final resolved = await resolver();
          if (resolved != null && resolved.url.isNotEmpty) {
            targetUrl = resolved.url;
            _primaryVideoUrl = resolved.url;
            _fallbackVideoUrl = resolved.fallbackUrl;
            _fallbackActivated = false; // 新链路，允许重新兜底
          }
        } catch (error, stackTrace) {
          _logger.eWithStack(
            'VideoPlayerService',
            '播放中重解析地址失败，退回原地址重连',
            error,
            stackTrace,
          );
        }
      }

      if (targetUrl.isEmpty) {
        // 既无法重解析也无原地址：交给起播兜底路径。
        await _attemptStartupRetry();
        return;
      }

      // 2) 原地重载（免黑屏）；3 次局部重试后降级到整体重建。
      const attempts = 3;
      Object? lastError;
      for (var i = 1; i <= attempts; i++) {
        if (_disposed) return;
        try {
          try {
            await _adapter!.reload(targetUrl, startPosition: resumePosition);
          } on UnsupportedError {
            // 内核不支持原地重载（如 ExoPlayer）：整体重建，但用刚重解析的新地址。
            await _recreateAdapter();
            await _initializeAdapterForUrl(
              targetUrl,
              startPosition: resumePosition,
              hardwareDecoding: hardwareDecoding,
              preferredSubtitleLanguage: _lastPreferredSubtitleLanguage,
              useGpuNext: _useGpuNext,
            );
          }
          await _adapter!.play();
          await _restoreTrackSelections(
            audioTrackId: audioTrackId,
            subtitleTrackId: subtitleTrackId,
          );
          _startupRetryCount = 0; // 恢复成功，归零起播预算。
          _recoverFailureCount = 0; // 恢复成功，清空熔断计数。
          _logger.i('VideoPlayerService', '播放中断流原地恢复成功: attempt=$i');
          return;
        } catch (error, stackTrace) {
          lastError = error;
          _logger.eWithStack(
            'VideoPlayerService',
            '播放中原地恢复失败: attempt=$i',
            error,
            stackTrace,
          );
          if (i < attempts) {
            await Future.delayed(Duration(milliseconds: 350 * i));
          }
        }
      }

      // 3) 原地恢复彻底失败 → 转码兜底；仍失败则让 hasError 自然暴露（用户重试/手动切线）。
      final fallbackActivated = await _tryActivateFallbackUrl(
        startPosition: resumePosition,
        hardwareDecoding: hardwareDecoding,
        preferredSubtitleLanguage: _lastPreferredSubtitleLanguage,
        audioTrackId: audioTrackId,
        subtitleTrackId: subtitleTrackId,
        autoPlay: true,
      );
      if (!fallbackActivated) {
        _recoverFailureCount++; // 熔断计数：被动恢复彻底失败。
        _logger.w(
          'VideoPlayerService',
          '播放中恢复与转码兜底均失败，暴露错误供用户重试/切换线路: ${lastError ?? ''}',
        );
      }
    } finally {
      _recoverInFlight = false;
      _autoRetryInFlight = false;
      notifyListeners();
    }
  }

  /// 初始化播放器
  /// 已释放标记。在异步初始化途中用户返回（dispose 先于 initialize 完成）时，
  /// 用它让 initialize/play 直接短路，避免在屏幕已销毁后才创建适配器、
  /// 导致播放器在后台空跑出声却无画面。
  bool _disposed = false;

  Future<void> initialize({
    required String videoUrl,
    required String itemId,
    String? mediaSourceId,
    String? fallbackVideoUrl,
    Duration? startPosition,
    PlayerCoreType? coreType,
    Function(PlaybackStartInfo)? onStart,
    Function(PlaybackProgressInfo)? onProgress,
    Function(PlaybackStopInfo)? onStop,
    bool? dolbyVisionFix,
    bool? useLibass,
    bool? hardwareDecoding,
    bool startWithSoftwareDecoding = false,
    String? fallbackReason,
    String? preferredSubtitleLanguage,
    int? surfaceViewId,  // For gpu-next rendering on Android
    bool useGpuNext = false,  // gpu-next rendering mode
    StreamUrlResolver? streamUrlResolver,  // L2 在线断流重解析；离线/本地为 null
    Duration? streamUrlTtl,  // L0 按服务器形态调档的签名链 TTL；null 用默认 5 分钟
    Map<String, String>? httpHeaders,  // 网盘/聚合源直链逐流 headers；Emby/本地为 null
    String? userAgentOverride,  // 覆盖默认 UA（夸克等要求特定 UA）
    String? playSessionId,  // Emby 播放会话 id：关联 Start/Progress/Stopped 落地续播进度
    String? superResolutionLevel,  // Anime4K 档位；播放页从持久化状态回传，重建后自动重放
  }) async {
    // 屏幕已销毁：不要再创建/初始化适配器，否则会留下后台空跑的孤儿播放器。
    if (_disposed) return;
    _currentItemId = itemId;
    _mediaSourceId = mediaSourceId ?? itemId;
    _playSessionId = playSessionId;
    _onStartReport = onStart;
    _onProgressReport = onProgress;
    _onStopReport = onStop;
    _hasReportedStart = false;
    _lastInitializationUsedFallback = false;
    _lastFallbackReason = fallbackReason;
    _primaryVideoUrl = videoUrl;
    _fallbackVideoUrl = fallbackVideoUrl;
    _httpHeaders = (httpHeaders != null && httpHeaders.isNotEmpty)
        ? Map<String, String>.from(httpHeaders)
        : null;
    _userAgentOverride = userAgentOverride;
    _streamUrlResolver = streamUrlResolver;
    _streamUrlTtl = streamUrlTtl;
    _pausedAt = null;
    _recoverInFlight = false;
    _recoverFailureCount = 0;
    _recoverWindowStart = null;
    _fallbackActivated = false;
    _initialStartPosition = startPosition;
    _lastDolbyVisionFix = dolbyVisionFix ?? false;
    _lastUseLibass = useLibass ?? false;
    _lastPreferredSubtitleLanguage = preferredSubtitleLanguage;
    _lastHardwareDecoding = hardwareDecoding ?? true;
    _lastStartWithSoftwareDecoding = startWithSoftwareDecoding;
    _superResolutionLevel = superResolutionLevel ?? 'off';
    _autoRetryInFlight = false;
    _startupRetryCount = 0;
    _selectedSubtitleTrackId = null;
    _selectedAudioTrackId = null;
    _surfaceViewId = surfaceViewId;  // Store for gpu-next rendering
    _useGpuNext = useGpuNext;  // Store gpu-next rendering mode
    _setPendingPlayingState(null, notify: false);

    if (coreType != null) {
      _coreType = coreType;
    }

    // 释放旧适配器
    await _recreateAdapter();

    // _recreateAdapter 期间可能发生 dispose（用户返回）。若已释放，立即把
    // 刚建好的适配器销毁并退出，避免它继续初始化并播放。
    if (_disposed) {
      await _adapter?.dispose();
      _adapter = null;
      return;
    }

    // 初始化
    final desiredHardwareDecoding =
        startWithSoftwareDecoding ? false : (hardwareDecoding ?? true);
    try {
      await _initializeAdapterForUrl(
        videoUrl,
        startPosition: startPosition,
        hardwareDecoding: desiredHardwareDecoding,
        preferredSubtitleLanguage: preferredSubtitleLanguage,
        useGpuNext: _useGpuNext,
      );
    } catch (error, stackTrace) {
      final fallbackActivated = await _tryActivateFallbackUrl(
        startPosition: startPosition,
        hardwareDecoding: desiredHardwareDecoding,
        preferredSubtitleLanguage: preferredSubtitleLanguage,
      );
      if (!fallbackActivated) {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }

    // 适配器初始化为异步过程，期间用户可能已返回销毁本服务。
    if (_disposed) {
      await _adapter?.dispose();
      _adapter = null;
      return;
    }

    // 加载 libass 字幕（如果启用）
    if (useLibass ?? false) {
      // 由调用方在 initialize 后手动加载字幕
    }

    // 启动进度定时器
    _startProgressTimer();

    notifyListeners();
  }

  /// 加载外部字幕文件（通过 libass）
  Future<void> loadLibassSubtitle(String path) async {
    await _adapter?.loadLibassSubtitle(path);
  }

  /// 原生 mpv 属性读取（media_kit 与 Android 原生 mpv 内核，其他返回 null）。
  Future<String?> mpvGetProperty(String name) async {
    final a = _adapter;
    if (a is MpvPlayerAdapter) return a.mpvGetProperty(name);
    if (a is NativeMpvPlayerAdapter) return a.mpvGetProperty(name);
    return null;
  }

  /// 原生 mpv 属性设置（media_kit 与 Android 原生 mpv 内核）。
  Future<void> mpvSetProperty(String name, String value) async {
    final a = _adapter;
    if (a is MpvPlayerAdapter) await a.mpvSetProperty(name, value);
    if (a is NativeMpvPlayerAdapter) await a.mpvSetProperty(name, value);
  }

  /// 原生 mpv 命令（media_kit 与 Android 原生 mpv 内核）。
  Future<void> mpvCommand(List<String> args) async {
    final a = _adapter;
    if (a is MpvPlayerAdapter) await a.mpvCommand(args);
    if (a is NativeMpvPlayerAdapter) await a.mpvCommand(args);
    if (a is WindowsNativeMpvAdapter) await a.mpvCommand(args);
  }

  /// 当前内核是否为 media_kit/mpv。
  bool get isMpvCore => _adapter is MpvPlayerAdapter;

  /// 是否支持 sub-step 从已缓冲区预读（凡是 libmpv 内核均可：media_kit + 原生 mpv）。
  bool get supportsSubStep =>
      _adapter is MpvPlayerAdapter || _adapter is NativeMpvPlayerAdapter;

  /// 流式翻译期间隐藏/恢复播放器自带字幕渲染（原文/译文统一走叠加层按排版显示）。
  /// mpv（media_kit / 原生）用 `sub-visibility`，ExoPlayer 用其渲染开关。
  void setNativeSubtitleHidden(bool hidden) {
    final a = _adapter;
    if (a is MpvPlayerAdapter) {
      unawaited(a.mpvSetProperty('sub-visibility', hidden ? 'no' : 'yes'));
    } else if (a is NativeMpvPlayerAdapter) {
      a.setNativeSubtitleHidden(hidden);
    } else if (a is ExoPlayerAdapter) {
      a.setNativeSubtitleHidden(hidden);
    }
  }

  /// 开启/关闭字幕取词观察（仅 Android 原生 mpv 需要：轮询 `sub-text` 喂给取词器；
  /// media_kit / Exo 已通过原生事件推送 cue，这里为空操作）。
  void setSubtitleCueObservation(bool enabled) {
    final a = _adapter;
    if (a is NativeMpvPlayerAdapter) a.setSubtitleCueObservation(enabled);
  }

  /// 加载字幕数据到内存（通过 libass）
  Future<void> loadLibassSubtitleMemory(Uint8List data,
      {String codec = 'ass'}) async {
    await _adapter?.loadLibassSubtitleMemory(data, codec: codec);
  }

  /// 为底层播放器提供字幕类型/标题提示，帮助匹配内封字幕。
  void setSubtitleSelectionHint({String? codec, String? title}) {
    _adapter?.setSubtitleSelectionHint(codec, title: title);
  }

  /// 当前选中的字幕 / 音频轨道 id（未选则为 null）。
  String? get selectedSubtitleTrackId => _selectedSubtitleTrackId;
  String? get selectedAudioTrackId => _selectedAudioTrackId;

  /// 选择字幕轨道（内封字幕切换）
  Future<void> selectSubtitleTrack(String trackId) async {
    _selectedSubtitleTrackId = trackId;
    await _adapter?.selectSubtitleTrack(trackId);
    notifyListeners();
  }

  /// 关闭字幕
  Future<void> deselectSubtitleTrack() async {
    _selectedSubtitleTrackId = null;
    await _adapter?.deselectSubtitleTrack();
    notifyListeners();
  }

  /// 选择音频轨道
  Future<void> selectAudioTrack(String trackId) async {
    _selectedAudioTrackId = trackId;
    await _adapter?.selectAudioTrack(trackId);
    notifyListeners();
  }

  /// 加载次字幕文件
  Future<void> loadSecondarySubtitle(String path) async {
    await _adapter?.loadSecondarySubtitle(path);
    notifyListeners();
  }

  /// 通过轨道ID选择内封字幕作为次字幕
  Future<void> selectSecondarySubtitleTrack(String trackId) async {
    await _adapter?.selectSecondarySubtitleTrack(trackId);
    notifyListeners();
  }

  /// 取消次字幕
  Future<void> deselectSecondarySubtitle() async {
    await _adapter?.deselectSecondarySubtitle();
    notifyListeners();
  }

  /// 播放
  Future<void> play() async {
    if (_disposed ||
        _adapter == null ||
        !isInitialized ||
        hasError ||
        isPlaying ||
        isPlaybackActionPending) {
      return;
    }
    // L2.5 暂停陷阱：暂停超过 TTL 再恢复，先重取流（重签 302）再播，
    // 避免恢复瞬间朝已失效的网盘签名链发 Range 请求导致断流。仅在线流生效。
    if (_streamUrlResolver != null &&
        _pausedAt != null &&
        DateTime.now().difference(_pausedAt!) > _effectiveStreamUrlTtl) {
      _pausedAt = null;
      _setPendingPlayingState(true);
      try {
        await _recoverInPlace(preemptive: true);
      } catch (_) {
        _setPendingPlayingState(null);
        rethrow;
      }
      _startHideControlsTimer();
      notifyListeners();
      return;
    }
    _pausedAt = null;
    _setPendingPlayingState(true);
    try {
      await _playWithStartupRetries();
    } catch (_) {
      _setPendingPlayingState(null);
      rethrow;
    }
    _startHideControlsTimer();
    notifyListeners();
  }

  Future<void> _playWithStartupRetries() async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _adapter!.play();
        return;
      } catch (error) {
        lastError = error;
        if (_hasReportedStart ||
            attempt >= 2 ||
            _primaryVideoUrl == null ||
            _primaryVideoUrl!.isEmpty) {
          rethrow;
        }
        _startupRetryCount = attempt + 1;
        await _recreateAdapter();
        await _initializeAdapterForUrl(
          _primaryVideoUrl!,
          startPosition: _initialStartPosition,
          hardwareDecoding:
              _lastStartWithSoftwareDecoding ? false : _lastHardwareDecoding,
          preferredSubtitleLanguage: _lastPreferredSubtitleLanguage,
        );
      }
    }
    final fallbackActivated = await _tryActivateFallbackUrl(
      startPosition: _initialStartPosition,
      hardwareDecoding:
          _lastStartWithSoftwareDecoding ? false : _lastHardwareDecoding,
      preferredSubtitleLanguage: _lastPreferredSubtitleLanguage,
      autoPlay: true,
    );
    if (fallbackActivated) {
      _logger.i('VideoPlayerService', '起播阶段已切换到兜底播放链路');
      return;
    }
    throw lastError ?? StateError('播放器直连重试失败');
  }

  /// 暂停
  Future<void> pause() async {
    if (_adapter == null ||
        !isInitialized ||
        hasError ||
        !isPlaying ||
        isPlaybackActionPending) {
      return;
    }
    _setPendingPlayingState(false);
    try {
      await _adapter!.pause();
    } catch (_) {
      _setPendingPlayingState(null);
      rethrow;
    }
    // L2.5：记录进入暂停的时刻，恢复时据此判断网盘签名链是否可能已过期。
    _pausedAt = DateTime.now();
    _reportProgress();
    _cancelHideControlsTimer();
    notifyListeners();
  }

  /// 播放/暂停切换
  Future<void> togglePlay() async {
    if (!isInitialized || hasError || isPlaybackActionPending) {
      return;
    }
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  /// 跳转到指定位置
  Future<void> seekTo(Duration position) async {
    await _adapter?.seekTo(position);
    _dragPreviewPosition = Duration.zero;
    _isScrubbingPosition = false;
    _reportProgress();
    notifyListeners();
  }

  /// 快进/快退
  Future<void> seekBy(Duration offset) async {
    await seekTo(position + offset);
  }

  /// 设置播放速度
  Future<void> setSpeed(double speed) async {
    await _adapter?.setSpeed(speed);
    notifyListeners();
  }

  /// 设置音量
  Future<void> setVolume(double volume) async {
    await _adapter?.setVolume(volume);
    notifyListeners();
  }

  /// 截图
  Future<Uint8List?> screenshot() async {
    return await _adapter?.screenshot();
  }

  /// 设置字幕同步偏移
  Future<void> setSubtitleDelay(double seconds) async {
    await _adapter?.setSubtitleDelay(seconds);
    notifyListeners();
  }

  /// 设置音频同步偏移
  Future<void> setAudioDelay(double seconds) async {
    await _adapter?.setAudioDelay(seconds);
    notifyListeners();
  }

  /// 设置字幕字体
  Future<void> setSubtitleFont(String fontName) async {
    await _adapter?.setSubtitleFont(fontName);
    notifyListeners();
  }

  /// 设置字幕大小
  Future<void> setSubtitleSize(double size) async {
    await _adapter?.setSubtitleSize(size);
    notifyListeners();
  }

  /// 设置字幕位置
  Future<void> setSubtitlePosition(double position) async {
    await _adapter?.setSubtitlePosition(position);
    notifyListeners();
  }

  /// 设置次字幕位置（libmpv 0.41+）
  Future<void> setSecondarySubtitlePosition(double position) async {
    await _adapter?.setSecondarySubtitlePosition(position);
    notifyListeners();
  }

  /// 设置次字幕延迟（libmpv 0.41+）
  Future<void> setSecondarySubtitleDelay(double seconds) async {
    await _adapter?.setSecondarySubtitleDelay(seconds);
    notifyListeners();
  }

  /// 设置字幕黑色背景
  Future<void> setSubtitleBackground(bool enabled) async {
    await _adapter?.setSubtitleBackground(enabled);
    notifyListeners();
  }

  /// 设置图形字幕(PGS/SUP)混合渲染模式（'no'/'video'/'yes'）。实验项，桌面 libmpv 生效。
  Future<void> setSubtitleBlendMode(String mode) async {
    await _adapter?.setSubtitleBlendMode(mode);
    notifyListeners();
  }

  /// 设置画面比例
  Future<void> setAspectRatio(String ratio) async {
    await _adapter?.setAspectRatio(ratio);
    notifyListeners();
  }

  /// 应用超分辨率
  Future<void> applySuperResolution(bool enable) async {
    _superResolutionLevel = enable ? 'modeB' : 'off';
    await _adapter?.applySuperResolution(enable);
    notifyListeners();
  }

  /// 应用超分辨率档位。记住档位，重建适配器时（换线路/换硬解）自动重放。
  Future<void> applySuperResolutionLevel(String level) async {
    _superResolutionLevel = level;
    await _adapter?.applySuperResolutionLevel(level);
    notifyListeners();
  }

  /// 当前是否能「即时」切换超分档位（含开/关）而无需重建播放管线。
  ///
  /// GLSL user shader 只能在硬件(OpenGL)渲染管线里跑。纹理模式在建 VideoController
  /// 时定死、无法运行时切换。桌面三端已恒硬件纹理 → 恒可即时应用，超分/六档随手切。
  /// （保留此判定：若 macOS 因黑屏回退软件纹理，isSoftwareTexture 会重新为真，
  /// 届时桌面 UI 自动退回「下次播放生效」分支。）
  bool get superResolutionCanApplyLive {
    final a = _adapter;
    if (a is MpvPlayerAdapter) return !a.isSoftwareTexture;
    return true; // 原生 mpv 恒硬件表面；其余内核不支持超分菜单也走不到这里
  }

  String get superResolutionLevel => _superResolutionLevel;

  bool get zeroCopyHwdec => _zeroCopyHwdec;

  /// 切换 Windows 硬解零拷贝(d3d11va)↔拷回(auto-copy)。会话级、不落盘。
  /// 记住状态，跨适配器重建（换硬解/换线路）自动重放；当前播放中即时切换。
  Future<void> setZeroCopyHwdec(bool enable) async {
    _zeroCopyHwdec = enable;
    final a = _adapter;
    if (a is MpvPlayerAdapter) await a.applyZeroCopyHwdec(enable);
    notifyListeners();
  }

  /// M1 · Windows 原生渲染实验开关（--wid 子窗口直出，绕开 ANGLE）。会话级、下次
  /// 起播生效（需换适配器，故不即时切换当前播放）。仅 Windows 有效。
  bool get windowsNativeRender => _windowsNativeRender;

  /// 播放页推送控制栏可见状态给原生渲染适配器（决定挖洞时避开控制栏区域，否则
  /// 控制栏会被挖穿变透明）。设置面板的排除走全局 [nativeRenderPanelFraction]，不经此。
  /// 仅 Windows 原生渲染适配器有效，其余为空操作。
  void setNativeChrome({bool? controls}) {
    final a = _adapter;
    if (a is WindowsNativeMpvAdapter) {
      a.setChrome(controls: controls);
    }
  }

  /// 把 UI 状态（标题/是否有剧集/超分开关）推给自研 Lua 控制栏。仅原生渲染有效。
  void pushNativeUiState({String? title, bool? hasSeries, bool? superres}) {
    final a = _adapter;
    if (a is WindowsNativeMpvAdapter) {
      a.pushUiState(title: title, hasSeries: hasSeries, superres: superres);
    }
  }

  void setWindowsNativeRender(bool enable) {
    _windowsNativeRender = enable;
    _nativeRenderHydrated = true; // 用户显式设置，别再被异步水合覆盖
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kNativeRenderPrefKey, enable);
      } catch (_) {}
    }());
    notifyListeners();
  }

  /// mpv 应用超分后实际持有的 shader 数（回读值）。0 = 没落到内核；>0 但软件纹理
  /// 下仍不会渲染。用于 UI 给用户「到底生效没」的确切反馈，取代盲猜。
  int get activeGlslShaderCount {
    final a = _adapter;
    if (a is MpvPlayerAdapter) return a.activeGlslShaderCount;
    if (a is NativeMpvPlayerAdapter) return a.activeGlslShaderCount;
    return 0;
  }

  /// 获取播放统计信息
  Future<Map<String, String>> getPlaybackStats() async {
    return await _adapter?.getPlaybackStats() ?? {};
  }

  /// 设置亮度
  void setBrightness(double brightness) {
    _currentBrightness = brightness.clamp(0.1, 1.0);
    notifyListeners();
  }

  /// 保存亮度到本地
  Future<void> saveBrightness() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('player_brightness', _currentBrightness);
  }

  /// 从本地加载亮度
  Future<void> loadBrightness() async {
    final prefs = await SharedPreferences.getInstance();
    final savedBrightness = prefs.getDouble('player_brightness');
    if (savedBrightness != null) {
      _currentBrightness = savedBrightness;
      notifyListeners();
    }
  }

  /// 显示/隐藏控制栏。锁定态下仍可切换：只影响那颗解锁按钮的显隐（完整控制栏另有 !isLocked 门控）。
  void toggleControls() {
    _showControls = !_showControls;
    if (_showControls) {
      _startHideControlsTimer();
    } else {
      _cancelHideControlsTimer();
    }
    notifyListeners();
  }

  /// 锁定/解锁屏幕。锁定/解锁后都短暂显示对应按钮再自动隐藏，避免解锁键长驻左上角破坏沉浸感。
  void toggleLock() {
    _isLocked = !_isLocked;
    _showControls = true;
    _startHideControlsTimer();
    notifyListeners();
  }

  // ========== 手势控制 ==========

  void onDragStart(DragStartDetails details, BoxConstraints constraints) {
    if (_isLocked || !isInitialized) return;
    _isDragging = true;
    _isScrubbingPosition = false;
    _gestureAxis = 0;
    _dragStartX = details.globalPosition.dx;
    _dragStartY = details.globalPosition.dy;
    _gestureAxisStartedLeft =
        _dragStartX < constraints.maxWidth / 2;
    _dragStartPosition = position;
    _dragPreviewPosition = position;
    _dragStartVolume = volume;
    _dragStartBrightness = _currentBrightness;
    _cancelHideControlsTimer();
    notifyListeners();
  }

  void onDragUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    if (!_isDragging || _isLocked) return;

    final dx = details.globalPosition.dx - _dragStartX;
    final dy = details.globalPosition.dy - _dragStartY;
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;

    // 一旦本次手势被判为不响应（轴=-1），直接忽略后续所有更新，避免误触。
    if (_gestureAxis == -1) return;

    // 方向未锁定：累计位移超过阈值后按主导轴「一次性」锁定，整段手势不再改判。
    // 这修复了竖向调亮度/音量时手指轻微横移会突然跳到进度条、导致进度错乱的问题。
    if (_gestureAxis == 0) {
      const threshold = 12.0;
      if (dx.abs() < threshold && dy.abs() < threshold) return;
      if (dx.abs() >= dy.abs()) {
        // 主导方向为水平 → 进度
        _gestureAxis = _horizontalSeekEnabled ? 1 : -1;
      } else {
        // 主导方向为竖向 → 亮度/音量（按起点半屏的配置；'none' 则不响应）
        final action = activeVerticalAction;
        _gestureAxis = (action == 'brightness' || action == 'volume') ? 2 : -1;
        _isScrubbingPosition = false;
      }
      if (_gestureAxis == -1) return;
    }

    if (_gestureAxis == 1) {
      // 水平滑动（进度调节）
      _isScrubbingPosition = true;
      final progressDelta =
          dx / width * duration.inMilliseconds * 0.5; // 降低灵敏度系数
      final newPositionMs = max(
          0,
          min(
            _dragStartPosition.inMilliseconds + progressDelta.round(),
            duration.inMilliseconds,
          ));
      _dragPreviewPosition = Duration(milliseconds: newPositionMs);
      notifyListeners();
    } else if (_gestureAxis == 2) {
      // 竖向滑动（亮度/音量）：动作由起点半屏的配置决定
      _isScrubbingPosition = false;
      final delta = -dy / height * 0.7; // 降低灵敏度系数
      if (activeVerticalAction == 'brightness') {
        setBrightness((_dragStartBrightness + delta).clamp(0.1, 1.0));
      } else {
        setVolume((_dragStartVolume + delta).clamp(0.0, 1.0));
      }
    }
  }

  void onDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    _isDragging = false;
    // 仅在确实处于进度拖动时才 seek；竖向/无效手势保持原位，避免松手误跳。
    final wasScrubbing = _gestureAxis == 1 && _isScrubbingPosition;
    _gestureAxis = 0;
    final targetPosition =
        wasScrubbing ? _dragPreviewPosition : _dragStartPosition;
    _isScrubbingPosition = false;
    if (wasScrubbing) seekTo(targetPosition);
    _startHideControlsTimer();
    notifyListeners();
  }

  // ========== 内部方法 ==========

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _reportProgress();
    });
  }

  void _stopProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  void _startHideControlsTimer() {
    _cancelHideControlsTimer();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (isPlaying && !_isDragging) {
        _showControls = false;
        notifyListeners();
      }
    });
  }

  void _cancelHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = null;
  }

  // ========== 播放上报 ==========

  void _reportStart() {
    if (_onStartReport == null || _currentItemId == null) return;
    _onStartReport!(PlaybackStartInfo(
      itemId: _currentItemId!,
      mediaSourceId: _mediaSourceId ?? _currentItemId!,
      playSessionId: _playSessionId,
    ));
  }

  void _reportProgress() {
    if (_onProgressReport == null || _currentItemId == null) return;
    _onProgressReport!(PlaybackProgressInfo(
      itemId: _currentItemId!,
      mediaSourceId: _mediaSourceId ?? _currentItemId!,
      positionTicks: (position.inMilliseconds * 10000).round(),
      isPaused: !isPlaying,
      volumeLevel: volume,
      playSessionId: _playSessionId,
    ));
  }

  void _reportStop() {
    if (_onStopReport == null || _currentItemId == null) return;
    _onStopReport!(PlaybackStopInfo(
      itemId: _currentItemId!,
      mediaSourceId: _mediaSourceId ?? _currentItemId!,
      positionTicks: (position.inMilliseconds * 10000).round(),
      playSessionId: _playSessionId,
    ));
  }

  /// 释放资源
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    // 同步置位，让仍在途中的 initialize/play 立刻短路。
    _disposed = true;
    _setPendingPlayingState(null, notify: false);
    _pendingPlaybackTimer?.cancel();
    _pendingPlaybackTimer = null;
    _primaryVideoUrl = null;
    _fallbackVideoUrl = null;
    _streamUrlResolver = null;
    _pausedAt = null;
    _recoverInFlight = false;
    _recoverFailureCount = 0;
    _recoverWindowStart = null;
    _fallbackActivated = false;
    _initialStartPosition = null;
    _lastPreferredSubtitleLanguage = null;
    _autoRetryInFlight = false;
    _startupRetryCount = 0;
    _reportStop();
    _stopProgressTimer();
    _cancelHideControlsTimer();
    _hasReportedStart = false;
    final hooks = _pluginHooks;
    if (hooks != null) {
      PluginPlayerBridge.instance.unbind(hooks);
      _pluginHooks = null;
    }
    await _adapter?.dispose();
    _adapter = null;
    super.dispose();
  }
}
