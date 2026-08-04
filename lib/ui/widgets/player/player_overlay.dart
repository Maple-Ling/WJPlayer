import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/services/system_info_service.dart';
import 'player_controls.dart';
import 'popup_menu_overlay.dart';

/// 播放器 UI 控制层。
///
/// 控制层独立维护 UI 显隐和当前菜单：
/// - [isUiVisible]：主控制栏是否显示；
/// - [activeMenu]：当前打开的二级/聚合菜单；
/// - 有菜单时点击空白只关闭菜单，不隐藏主控制栏；
/// - 无菜单时点击空白切换主控制栏显隐。
class PlayerOverlay extends StatefulWidget {
  const PlayerOverlay({
    super.key,
    required this.visible,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.bufferedProgress,
    this.isScrubbingPosition = false,
    this.dragPreviewProgress,
    this.isBuffering = false,
    this.rxSpeed = 0,
    required this.title,
    required this.episode,
    required this.meta,
    required this.serverName,
    required this.serverLine,
    required this.logoText,
    this.logo,
    this.logoImage,
    this.serverIcon,
    required this.mediaInfoTitle,
    required this.encoder,
    required this.resolution,
    required this.frameRate,
    required this.bitrate,
    required this.initialDanmakuEnabled,
    required this.initialDanmakuDeduplication,
    required this.initialAutoSkip,
    required this.initialDanmakuOpacity,
    required this.initialDanmakuFontSize,
    required this.initialDanmakuSpeed,
    required this.initialDanmakuDensity,
    required this.initialDanmakuArea,
    required this.initialDanmakuDelay,
    required this.initialSpeed,
    required this.initialAspectRatio,
    required this.initialSource,
    required this.initialCore,
    required this.initialLine,
    required this.initialAudioTrack,
    required this.initialSubtitleTrack,
    required this.initialEpisode,
    required this.episodeCount,
    this.initialIntroTime,
    this.initialOutroTime,
    required this.sources,
    required this.cores,
    required this.lines,
    required this.audioTracks,
    required this.subtitleTracks,
    required this.episodes,
    this.onUiVisibilityChanged,
    this.onMenuVisibilityChanged,
    this.onBack,
    this.onPrevious,
    this.onNext,
    this.onPlayPause,
    this.onSeek,
    this.onPlaybackRateChanged,
    this.onAspectRatioChanged,
    this.onSourceChanged,
    this.onCoreChanged,
    this.onLineChanged,
    this.onAudioTrackChanged,
    this.onSubtitleChanged,
    this.onEpisodeChanged,
    this.onLock,
    this.onRotate,
    this.onDanmakuChanged,
    this.onDanmakuDeduplicationChanged,
    this.onAutoSkipChanged,
    this.onDanmakuOpacityChanged,
    this.onDanmakuFontSizeChanged,
    this.onDanmakuSpeedChanged,
    this.onDanmakuDensityChanged,
    this.onDanmakuAreaChanged,
    this.onDanmakuDelayChanged,
    this.onSearchDanmaku,
    this.onSkipTimeRecorded,
    this.onClearIntro,
    this.onClearOutro,
    this.onExternalSubtitleRequested,
  });

  final bool visible;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final double bufferedProgress;
  final bool isScrubbingPosition;
  final double? dragPreviewProgress;
  final bool isBuffering;
  final double rxSpeed;

  final String title;
  final String episode;
  final String meta;
  final String serverName;
  final String serverLine;
  final String logoText;
  final Widget? logo;
  final ImageProvider<Object>? logoImage;
  final Widget? serverIcon;

  final String mediaInfoTitle;
  final String encoder;
  final String resolution;
  final String frameRate;
  final String bitrate;

  final bool initialDanmakuEnabled;
  final bool initialDanmakuDeduplication;
  final bool initialAutoSkip;
  final double initialDanmakuOpacity;
  final double initialDanmakuFontSize;
  final double initialDanmakuSpeed;
  final double initialDanmakuDensity;
  final double initialDanmakuArea;
  final double initialDanmakuDelay;
  final double initialSpeed;
  final String initialAspectRatio;
  final String initialSource;
  final String initialCore;
  final String initialLine;
  final String initialAudioTrack;
  final String initialSubtitleTrack;
  final int initialEpisode;
  final int episodeCount;
  final String? initialIntroTime;
  final String? initialOutroTime;

  final List<PopupAggregateSource> sources;
  final List<String> cores;
  final List<PopupLineOption> lines;
  final List<String> audioTracks;
  final List<String> subtitleTracks;
  final List<PopupEpisodeOption> episodes;

  final ValueChanged<bool>? onUiVisibilityChanged;
  final ValueChanged<bool>? onMenuVisibilityChanged;
  final VoidCallback? onBack;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onPlayPause;
  final ValueChanged<double>? onSeek;
  final ValueChanged<double>? onPlaybackRateChanged;
  final ValueChanged<String>? onAspectRatioChanged;
  final ValueChanged<String>? onSourceChanged;
  final ValueChanged<String>? onCoreChanged;
  final ValueChanged<String>? onLineChanged;
  final ValueChanged<String>? onAudioTrackChanged;
  final ValueChanged<String>? onSubtitleChanged;
  final ValueChanged<int>? onEpisodeChanged;
  final VoidCallback? onLock;
  final VoidCallback? onRotate;

  final ValueChanged<bool>? onDanmakuChanged;
  final ValueChanged<bool>? onDanmakuDeduplicationChanged;
  final ValueChanged<bool>? onAutoSkipChanged;
  final ValueChanged<double>? onDanmakuOpacityChanged;
  final ValueChanged<double>? onDanmakuFontSizeChanged;
  final ValueChanged<double>? onDanmakuSpeedChanged;
  final ValueChanged<double>? onDanmakuDensityChanged;
  final ValueChanged<double>? onDanmakuAreaChanged;
  final ValueChanged<double>? onDanmakuDelayChanged;
  final VoidCallback? onSearchDanmaku;
  final ValueChanged<PopupSkipRecord>? onSkipTimeRecorded;
  final VoidCallback? onClearIntro;
  final VoidCallback? onClearOutro;
  final VoidCallback? onExternalSubtitleRequested;

  @override
  State<PlayerOverlay> createState() => _PlayerOverlayState();
}

class _PlayerOverlayState extends State<PlayerOverlay> {
  late bool isUiVisible;
  PopupMenuId? activeMenu;
  PopupMenuId? _anchorMenu;

  late bool _danmakuEnabled;
  late bool _danmakuDeduplication;
  late bool _autoSkip;
  late double _danmakuOpacity;
  late double _danmakuFontSize;
  late double _danmakuSpeed;
  late double _danmakuDensity;
  late double _danmakuArea;
  late double _danmakuDelay;
  late double _speed;
  late String _aspectRatio;
  late String _selectedSource;
  late String _selectedCore;
  late String _selectedLine;
  late String _selectedAudioTrack;
  late String _selectedSubtitleTrack;
  late int _selectedEpisode;
  late String? _introTime;
  late String? _outroTime;

  DateTime _now = DateTime.now();
  Timer? _clockTimer;
  String? _toastMessage;
  Timer? _toastTimer;
  VoidCallback? _removeSystemInfoListener;

  @override
  void initState() {
    super.initState();
    isUiVisible = widget.visible;
    _danmakuEnabled = widget.initialDanmakuEnabled;
    _danmakuDeduplication = widget.initialDanmakuDeduplication;
    _autoSkip = widget.initialAutoSkip;
    _danmakuOpacity = widget.initialDanmakuOpacity;
    _danmakuFontSize = widget.initialDanmakuFontSize;
    _danmakuSpeed = widget.initialDanmakuSpeed;
    _danmakuDensity = widget.initialDanmakuDensity;
    _danmakuArea = widget.initialDanmakuArea;
    _danmakuDelay = widget.initialDanmakuDelay;
    _speed = widget.initialSpeed;
    _aspectRatio = widget.initialAspectRatio;
    _selectedSource = widget.initialSource;
    _selectedCore = widget.initialCore;
    _selectedLine = widget.initialLine;
    _selectedAudioTrack = widget.initialAudioTrack;
    _selectedSubtitleTrack = widget.initialSubtitleTrack;
    _selectedEpisode = widget.initialEpisode
        .clamp(1, math.max(1, widget.episodeCount))
        .toInt();
    _introTime = widget.initialIntroTime;
    _outroTime = widget.initialOutroTime;

    _clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;
        setState(() => _now = DateTime.now());
      },
    );

    final systemInfo = SystemInfoService.instance;
    systemInfo.start();
    _removeSystemInfoListener = systemInfo.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant PlayerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.visible != oldWidget.visible &&
        widget.visible != isUiVisible &&
        activeMenu == null) {
      isUiVisible = widget.visible;
      if (!isUiVisible) {
        _anchorMenu = null;
      }
    }

    if (widget.episodeCount != oldWidget.episodeCount ||
        widget.initialEpisode != oldWidget.initialEpisode) {
      _selectedEpisode = widget.initialEpisode
          .clamp(1, math.max(1, widget.episodeCount))
          .toInt();
    }
    if (widget.initialCore != oldWidget.initialCore) {
      _selectedCore = widget.initialCore;
    }
    if (widget.initialLine != oldWidget.initialLine) {
      _selectedLine = widget.initialLine;
    }
    if (widget.initialAudioTrack != oldWidget.initialAudioTrack) {
      _selectedAudioTrack = widget.initialAudioTrack;
    }
    if (widget.initialSubtitleTrack != oldWidget.initialSubtitleTrack) {
      _selectedSubtitleTrack = widget.initialSubtitleTrack;
    }
    if (widget.initialAspectRatio != oldWidget.initialAspectRatio) {
      _aspectRatio = widget.initialAspectRatio;
    }
    if (widget.initialSpeed != oldWidget.initialSpeed) {
      _speed = widget.initialSpeed;
    }
  }

  @override
  void dispose() {
    _removeSystemInfoListener?.call();
    _clockTimer?.cancel();
    _toastTimer?.cancel();
    super.dispose();
  }

  void _openMenu(
    PopupMenuId menu, {
    PopupMenuId? anchorMenu,
  }) {
    setState(() {
      isUiVisible = true;
      activeMenu = menu;
      _anchorMenu = anchorMenu ?? menu;
    });
    widget.onUiVisibilityChanged?.call(true);
    // 打开二级菜单时通知外部暂停自动隐藏计时器。
    widget.onMenuVisibilityChanged?.call(true);
  }

  void _closeMenu() {
    if (!mounted) return;
    setState(() {
      activeMenu = null;
      _anchorMenu = null;
    });
    // 二级菜单全部关闭后恢复自动隐藏计时器。
    widget.onMenuVisibilityChanged?.call(false);
  }

  void _handleBack() {
    if (activeMenu != null) {
      _closeMenu();
      return;
    }
    widget.onBack?.call();
  }

  void _setDanmaku(bool value) {
    setState(() => _danmakuEnabled = value);
    widget.onDanmakuChanged?.call(value);
  }

  void _setDanmakuDeduplication(bool value) {
    setState(() => _danmakuDeduplication = value);
    widget.onDanmakuDeduplicationChanged?.call(value);
  }

  void _setAutoSkip(bool value) {
    setState(() => _autoSkip = value);
    widget.onAutoSkipChanged?.call(value);
  }

  void _setDanmakuOpacity(double value) {
    setState(() => _danmakuOpacity = value);
    widget.onDanmakuOpacityChanged?.call(value);
  }

  void _setDanmakuFontSize(double value) {
    setState(() => _danmakuFontSize = value);
    widget.onDanmakuFontSizeChanged?.call(value);
  }

  void _setDanmakuSpeed(double value) {
    setState(() => _danmakuSpeed = value);
    widget.onDanmakuSpeedChanged?.call(value);
  }

  void _setDanmakuDensity(double value) {
    setState(() => _danmakuDensity = value);
    widget.onDanmakuDensityChanged?.call(value);
  }

  void _setDanmakuArea(double value) {
    setState(() => _danmakuArea = value);
    widget.onDanmakuAreaChanged?.call(value);
  }

  void _setDanmakuDelay(double value) {
    setState(() => _danmakuDelay = value);
    widget.onDanmakuDelayChanged?.call(value);
  }

  void _setSpeed(double value) {
    setState(() => _speed = value);
    _closeMenu();
    widget.onPlaybackRateChanged?.call(value);
  }

  void _setAspectRatio(String value) {
    setState(() => _aspectRatio = value);
    _closeMenu();
    widget.onAspectRatioChanged?.call(value);
  }

  void _setSource(String value) {
    setState(() => _selectedSource = value);
    _closeMenu();
    widget.onSourceChanged?.call(value);
  }

  void _setCore(String value) {
    setState(() => _selectedCore = value);
    _closeMenu();
    widget.onCoreChanged?.call(value);
  }

  void _setLine(String value) {
    setState(() => _selectedLine = value);
    _closeMenu();
    widget.onLineChanged?.call(value);
  }

  void _setAudioTrack(String value) {
    setState(() => _selectedAudioTrack = value);
    _closeMenu();
    widget.onAudioTrackChanged?.call(value);
  }

  void _setSubtitleTrack(String value) {
    setState(() => _selectedSubtitleTrack = value);
    _closeMenu();
    widget.onSubtitleChanged?.call(value);
  }

  void _setEpisode(int value) {
    setState(() => _selectedEpisode = value);
    _closeMenu();
    widget.onEpisodeChanged?.call(value);
  }

  void _recordSkipTime(PopupSkipRecord record) {
    setState(() {
      if (record.type == '片头') {
        _introTime = record.time;
      } else {
        _outroTime = record.time;
      }
    });
    widget.onSkipTimeRecorded?.call(record);
    _showToast('已记录${record.type}时间: ${record.time}');
  }

  void _showToast(String message) {
    _toastTimer?.cancel();
    if (!mounted) return;
    setState(() => _toastMessage = message);
    _toastTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _toastMessage = null);
    });
  }

  Set<PlayerTopAction> get _selectedTopActions {
    switch (activeMenu) {
      case PopupMenuId.danmaku:
        return {PlayerTopAction.danmaku};
      case PopupMenuId.speed:
        return {PlayerTopAction.speed};
      case PopupMenuId.skip:
        return {PlayerTopAction.skipOpeningEnding};
      case PopupMenuId.aspect:
        return {PlayerTopAction.aspectRatio};
      case PopupMenuId.info:
        return {PlayerTopAction.mediaInfo};
      default:
        return <PlayerTopAction>{};
    }
  }

  Set<PlayerBottomAction> get _selectedBottomActions {
    switch (activeMenu) {
      case PopupMenuId.aggregate:
        return {PlayerBottomAction.aggregate};
      case PopupMenuId.core:
        return {PlayerBottomAction.core};
      case PopupMenuId.line:
        return {PlayerBottomAction.line};
      case PopupMenuId.audio:
        return {PlayerBottomAction.audio};
      case PopupMenuId.subtitle:
        return {PlayerBottomAction.subtitle};
      case PopupMenuId.episodes:
        return {PlayerBottomAction.episodes};
      default:
        return <PlayerBottomAction>{};
    }
  }

  IconData get _networkIcon {
    switch (SystemInfoService.instance.networkType) {
      case 'wifi':
        return Icons.wifi_rounded;
      case 'mobile':
        return Icons.signal_cellular_alt_rounded;
      case 'none':
        return Icons.signal_cellular_off_rounded;
      default:
        return Icons.network_check_rounded;
    }
  }

  String get _networkLabel {
    switch (SystemInfoService.instance.networkType) {
      case 'wifi':
        return 'Wi-Fi';
      case 'mobile':
        return '4G/5G 移动网络';
      case 'none':
        return '网络未连接';
      default:
        return '网络状态未知';
    }
  }

  Rect? _anchorRect(BuildContext context, Size size) {
    final mediaPadding = MediaQuery.of(context).padding;
    final menu = _anchorMenu ?? activeMenu;
    if (menu == null) return null;

    const topActions = <PopupMenuId>[
      PopupMenuId.danmaku,
      PopupMenuId.speed,
      PopupMenuId.skip,
      PopupMenuId.aspect,
      PopupMenuId.info,
    ];
    final topIndex = topActions.indexOf(menu);
    if (topIndex >= 0) {
      final rightIndex = topActions.length - topIndex - 1;
      final center = Offset(
        size.width - 14 - ((rightIndex + 0.5) * 40),
        mediaPadding.top + 8 + 14 + 8 + 19,
      );
      return Rect.fromCenter(center: center, width: 36, height: 36);
    }

    const bottomActions = <PopupMenuId>[
      PopupMenuId.aggregate,
      PopupMenuId.core,
      PopupMenuId.line,
      PopupMenuId.audio,
      PopupMenuId.subtitle,
      PopupMenuId.episodes,
    ];
    final bottomIndex = bottomActions.indexOf(menu);
    if (bottomIndex >= 0) {
      final rightIndex = bottomActions.length - bottomIndex - 1;
      final center = Offset(
        size.width - 14 - ((rightIndex + 0.5) * 46),
        size.height - mediaPadding.bottom - 14 - 22,
      );
      return Rect.fromCenter(center: center, width: 44, height: 44);
    }
    return null;
  }

  Rect _progressRect(BuildContext context, Size size) {
    final mediaPadding = MediaQuery.of(context).padding;
    final centerY = size.height -
        mediaPadding.bottom -
        14 -
        44 -
        6 -
        14;
    return Rect.fromCenter(
      center: Offset(size.width / 2, centerY),
      width: math.max(1.0, size.width - 84).toDouble(),
      height: 28,
    );
  }

  String _formatDuration(Duration value) {
    final total = value.inSeconds < 0 ? 0 : value.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildToast(Size size) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: size.height * 0.4,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.85),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _toastMessage!,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  /// 手势拖动进度时的极简进度条（UI 隐藏时也可见）。
  Widget _buildScrubbingProgress(BuildContext context, Size size) {
    final dragProgress = widget.dragPreviewProgress ?? 0;
    final progress = widget.duration.inMilliseconds > 0
        ? (widget.position.inMilliseconds / widget.duration.inMilliseconds)
        : 0.0;
    return Positioned(
      left: 0,
      right: 0,
      top: size.height * 0.5,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _formatDuration(widget.duration == Duration.zero
                  ? _estimatePositionFromProgress(dragProgress, widget.duration)
                  : widget.duration == Duration.zero
                      ? Duration.zero
                      : widget.duration == Duration.zero
                          ? Duration.zero
                          : _posFromProg(dragProgress, widget.duration)),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: dragProgress.clamp(0.0, 1.0),
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(
                    Color(0xFF5B8DEF)),
                minHeight: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Duration _posFromProg(double prog, Duration dur) {
    if (dur.inMilliseconds <= 0) return Duration.zero;
    return Duration(
        milliseconds: (prog * dur.inMilliseconds).round().clamp(
            0, dur.inMilliseconds));
  }

  Duration _estimatePositionFromProgress(double prog, Duration dur) {
    return _posFromProg(prog, dur);
  }

  /// 缓冲/卡顿时的网速 + 转圈。
  Widget _buildBufferingSpeed(BuildContext context) {
    final rx = widget.rxSpeed;
    final tx = 0.0; // todo
    return Align(
      alignment: const Alignment(0, 0.333),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation(Colors.white),
          ),
          const SizedBox(height: 12),
          Text(
            '加载中 ${_formatSpeed(rx)}',
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ],
      ),
    );
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.toInt()} B/s';
    } else if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(2)} MB/s';
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        final size = Size(width, height);
        final info = SystemInfoService.instance;

        return Stack(
          fit: StackFit.expand,
          children: [
            // 透传层：visible=false 时完全忽略所有点，让底层的
            // _buildPlayerBody GestureDetector 接管全部手势（双击/长按/拖动）。
            // visible=true 时由下方 GestureDetector 接管空白处点击。
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !isUiVisible,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    if (activeMenu != null) {
                      _closeMenu();
                      return;
                    }
                    // 空白处点击：隐藏控制栏（如果已显示）。
                    if (isUiVisible) {
                      setState(() => isUiVisible = false);
                      widget.onUiVisibilityChanged?.call(false);
                    }
                  },
                ),
              ),
            ),
              IgnorePointer(
                ignoring: !isUiVisible,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: isUiVisible ? 1 : 0,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: TopBar(
                          logo: widget.logo,
                          logoImage: widget.logoImage,
                          logoText: widget.logoText,
                          serverIcon: widget.serverIcon,
                          serverName: widget.serverName,
                          lineName: _selectedLine,
                          timeText:
                              '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}',
                          batteryLevel: info.battery,
                          networkIcon: _networkIcon,
                          networkLabel: _networkLabel,
                          networkSpeed: _formatSpeed(info.rxSpeed),
                          topActions: const [
                            PlayerTopAction.danmaku,
                            PlayerTopAction.speed,
                            PlayerTopAction.skipOpeningEnding,
                            PlayerTopAction.aspectRatio,
                            PlayerTopAction.mediaInfo,
                          ],
                          selectedActions: _selectedTopActions,
                          onBack: _handleBack,
                          onAction: (action) {
                            switch (action) {
                              case PlayerTopAction.danmaku:
                                _openMenu(PopupMenuId.danmaku);
                                break;
                              case PlayerTopAction.speed:
                                _openMenu(PopupMenuId.speed);
                                break;
                              case PlayerTopAction.skipOpeningEnding:
                                _openMenu(PopupMenuId.skip);
                                break;
                              case PlayerTopAction.aspectRatio:
                                _openMenu(PopupMenuId.aspect);
                                break;
                              case PlayerTopAction.mediaInfo:
                                _openMenu(PopupMenuId.info);
                                break;
                            }
                          },
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: BottomBar(
                          title: widget.title,
                          episode: widget.episode,
                          meta: widget.meta,
                          position: widget.position,
                          duration: widget.duration,
                          bufferedProgress: widget.bufferedProgress,
                          isPlaying: widget.isPlaying,
                          bottomActions: const [
                            PlayerBottomAction.aggregate,
                            PlayerBottomAction.core,
                            PlayerBottomAction.line,
                            PlayerBottomAction.audio,
                            PlayerBottomAction.subtitle,
                            PlayerBottomAction.episodes,
                          ],
                          selectedActions: _selectedBottomActions,
                          onProgressChanged: widget.onSeek,
                          onProgressChangeEnd: widget.onSeek,
                          onPrevious: widget.onPrevious,
                          onPlayPause: widget.onPlayPause,
                          onNext: widget.onNext,
                          onAction: (action) {
                            switch (action) {
                              case PlayerBottomAction.aggregate:
                                _openMenu(PopupMenuId.aggregate);
                                break;
                              case PlayerBottomAction.core:
                                _openMenu(PopupMenuId.core);
                                break;
                              case PlayerBottomAction.line:
                                _openMenu(PopupMenuId.line);
                                break;
                              case PlayerBottomAction.audio:
                                _openMenu(PopupMenuId.audio);
                                break;
                              case PlayerBottomAction.subtitle:
                                _openMenu(PopupMenuId.subtitle);
                                break;
                              case PlayerBottomAction.episodes:
                                _openMenu(PopupMenuId.episodes);
                                break;
                            }
                          },
                        ),
                      ),
                      Positioned.fill(
                        child: SideButtons(
                          horizontalPadding: width * 0.08,
                          onLock: widget.onLock,
                          onRotate: widget.onRotate,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (isUiVisible && activeMenu != null)
                Positioned.fill(
                  child: PopupMenuOverlay(
                    activeMenu: activeMenu,
                    anchorRect: _anchorRect(context, size),
                    progressRect: _progressRect(context, size),
                    onClose: _closeMenu,
                    onOpenMenu: (menu) {
                      _openMenu(
                        menu,
                        anchorMenu: menu == PopupMenuId.danmakuSettings
                            ? PopupMenuId.danmaku
                            : null,
                      );
                    },
                    danmakuEnabled: _danmakuEnabled,
                    danmakuDeduplication: _danmakuDeduplication,
                    autoSkip: _autoSkip,
                    danmakuOpacity: _danmakuOpacity,
                    danmakuFontSize: _danmakuFontSize,
                    danmakuSpeed: _danmakuSpeed,
                    danmakuDensity: _danmakuDensity,
                    danmakuArea: _danmakuArea,
                    danmakuDelay: _danmakuDelay,
                    speed: _speed,
                    aspectRatio: _aspectRatio,
                    selectedSource: _selectedSource,
                    selectedCore: _selectedCore,
                    selectedLine: _selectedLine,
                    selectedAudioTrack: _selectedAudioTrack,
                    selectedSubtitleTrack: _selectedSubtitleTrack,
                    selectedEpisode: _selectedEpisode,
                    episodes: widget.episodes,
                    introTime: _introTime,
                    outroTime: _outroTime,
                    currentPositionLabel: _formatDuration(widget.position),
                    mediaTitle: widget.mediaInfoTitle,
                    encoder: widget.encoder,
                    resolution: widget.resolution,
                    frameRate: widget.frameRate,
                    bitrate: widget.bitrate,
                    sources: widget.sources,
                    cores: widget.cores,
                    lines: widget.lines,
                    audioTracks: widget.audioTracks,
                    subtitleTracks: widget.subtitleTracks,
                    onDanmakuChanged: _setDanmaku,
                    onDanmakuDeduplicationChanged:
                        _setDanmakuDeduplication,
                    onAutoSkipChanged: _setAutoSkip,
                    onDanmakuOpacityChanged: _setDanmakuOpacity,
                    onDanmakuFontSizeChanged: _setDanmakuFontSize,
                    onDanmakuSpeedChanged: _setDanmakuSpeed,
                    onDanmakuDensityChanged: _setDanmakuDensity,
                    onDanmakuAreaChanged: _setDanmakuArea,
                    onDanmakuDelayChanged: _setDanmakuDelay,
                    onSearchDanmaku: () {
                      widget.onSearchDanmaku?.call();
                    },
                    onPlaybackRateChanged: _setSpeed,
                    onAspectRatioChanged: _setAspectRatio,
                    onSourceChanged: _setSource,
                    onCoreChanged: _setCore,
                    onLineChanged: _setLine,
                    onAudioTrackChanged: _setAudioTrack,
                    onSubtitleChanged: _setSubtitleTrack,
                    onEpisodeChanged: _setEpisode,
                    onSkipTimeRecorded: _recordSkipTime,
                    onClearIntro: () => widget.onClearIntro?.call(),
                    onClearOutro: () => widget.onClearOutro?.call(),
                    onExternalSubtitleRequested: () {
                      widget.onExternalSubtitleRequested?.call();
                    },
                  ),
                ),
              if (_toastMessage != null) _buildToast(size),
              // 手势拖动进度时，即使主控制栏已隐藏也单独渲染一条极简进度条。
              if (isScrubbingPosition) _buildScrubbingProgress(context, size),
              // 卡顿缓冲时，中央显示网速 + 转圈。
              if (isBuffering && !isUiVisible) _buildBufferingSpeed(context),
            ],
          ),
        );
      },
    );
  }
}
