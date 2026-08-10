part of 'player_screen.dart';

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  late VideoPlayerService _playerService;
  bool _showRemaining = false;
  bool _isLongPressing = false;
  // ---- canvas_danmaku 弹幕调度（滑动窗口加载：游标+二分+去重+seek 重喂）----
  DanmakuController<dynamic>? _danmakuController;
  DanmakuLoader? _danmakuLoader;
  List<DanmakuItem>? _lastIndexedDanmaku;
  Duration _lastFeedPosition = Duration.zero;
  bool _lastPlayingState = true;
  // 轻点判定（全屏点击切换控制栏）：记录按下位置/时间。抬起后延迟 300ms
  // 执行 toggle（双击窗口内第二击取消，UI 零闪现；单击延迟可感但无手势
  // 竞技场等待，事件不丢失）。
  Offset _tapDownPosition = Offset.zero;
  DateTime _tapDownTime = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pendingTapTimer;
  // 延迟中的单击 toggle：双击/连点窗口内由 _onTapDown 取消，UI 完全不变化。
  Timer? _pendingTapToggle;
  // 上一击是「双击第二击」（tapDown 取消了 pending）：其 tapUp 不再 toggle。
  bool _tapWasDoubleTap = false;
  // 陀螺仪画面翻转：横屏下 x 轴符号直接判定方向（x<0 翻转 180°），
  // 翻转转为切换系统方向（landscapeLeft↔Right），不再用 Transform。
  StreamSubscription<AccelerometerEvent>? _accelSub;
  bool _isSliderDragging = false;
  double? _sliderDragValue;
  bool _decoderSwitchInFlight = false;
  Timer? _longPressTimer;
  Timer? _statusTimer;
  Timer? _sleepTimer;
  Timer? _sourceProgressTimer;
  Map<String, dynamic>? _sourcePlayMetadata;
  SourcePlayback? _activeSourcePlay;
  bool _sourceProgressWriteInFlight = false;
  int _lastSourceProgressSecond = -1;
  bool _sourceCompletionReported = false;
  // 播放完毕自动连播下一集的防重标志（重新起播/seek 后复位）。
  bool _autoNextHandled = false;
  String? _sourceCoreOverride;
  // ExoPlayer 解码器初始化失败（DTS 等硬件不支持）时自动切 MPV 重试，只切一次。
  bool _autoCoreFallbackTried = false;
  double? _initialVideoAspectRatio;
  // 当前 Anime4K 超分档位（off/modeA/…/modeAC），供顶栏面板高亮选中项。
  String _anime4kMode = 'off';
  // 本次播放是否已上报「看过」到同步服务，避免 onStop 多次触发导致重复写入。
  bool _didScrobble = false;
  List<PopupEpisodeOption> _overlayEpisodes = const <PopupEpisodeOption>[];
  String? _overlayEpisodeLoadKey;

  // ---- TV 遥控播放控制（2026-08-09）----
  // 对齐 Netflix/YouTube/腾讯 TV 播放页惯例：方向键=快进快退、OK=播放暂停、
  // 上下/MENU=呼出控制栏、返回=退出（系统 back）。TV 不做音量/亮度调节
  // （电视/投影有物理音量键与自带亮度调节），上下键用于控制栏显隐。
  // MENU 会经 native 通道与 Flutter 通道双触发，用时间戳去抖。
  DateTime? _lastMenuKeyTime;
  // 长按连续快进/拖动：锚定起始位置后按「累计时间 × 速率」确定性推进
  // （不依赖 200ms 轮询的 position，平滑类似拖动进度条）。
  Duration? _tvSeekAnchor;
  int _tvSeekCount = 0;
  bool _tvSeekForward = true;
  Timer? _tvSeekTimer;
  // 上键单击/长按判定：按下启动 400ms 延迟（单击 → toggleControls），
  // 期间收到 KeyRepeat 则取消延迟并进入长按倍速；松开恢复默认速度。
  Timer? _tvLongPressTimer;
  bool _tvSpeedBoostActive = false;
  // TV：二级菜单（弹幕设置/选集/音轨等）打开状态——系统返回键先关菜单
  // 再退出播放器；菜单打开期间 UI 不自动隐藏（setControlsAutoHidePaused）。
  final GlobalKey<PlayerOverlayState> _overlayKey =
      GlobalKey<PlayerOverlayState>();
  bool _overlayMenuOpen = false;
  // TV 选集栏（底部胶囊）：MENU 键打开，左右滚动聚焦，OK 选集。
  bool _tvEpisodeBarOpen = false;
  int _tvEpisodeIndex = 0;
  final ScrollController _tvEpisodeScrollController = ScrollController();
  // TV 控制栏焦点：-2=进度条；-1=无（UI 隐藏）；0..7=按钮
  // （0 上一集 / 1 播放暂停 / 2 下一集 / 3 聚合 / 4 内核 / 5 线路 / 6 音频 / 7 字幕）。
  int _tvUiFocusRegion = 0;

  /// 区域内焦点索引（bottom：0=进度条、1..3=传输、4..=操作；
  /// top：0=返回、1..=顶部操作）。
  int _tvUiFocusItem = 0;

  /// 底部区按钮焦点节点（0=进度条、1..3=传输、4..=操作）。
  late final List<FocusNode> _tvBottomNodes =
      List.generate(9, (i) => FocusNode(debugLabel: 'tv_bottom[$i]'));

  /// 顶部区按钮焦点节点（0=返回、1..=顶部操作）。
  late final List<FocusNode> _tvTopNodes =
      List.generate(8, (i) => FocusNode(debugLabel: 'tv_top[$i]'));

  /// 内封字幕流式翻译器（无法整轨下载时边播边译，叠加层按双语排版显示）。
  StreamingSubtitleTranslator? _streamTranslator;

  /// 自动跳过片头/片尾控制器（introdb），左下角按钮随控制栏显隐。
  late final IntroSkipController _introSkip;

  static VideoPlayerService? _activePlayerService;

  static VideoPlayerService? get activePlayerService => _activePlayerService;

  /// 当前活跃的播放页实例，供字幕设置面板触发流式翻译回退。
  static _PlayerScreenState? _activeState;

  /// 供字幕设置面板在整轨翻译失败时回退到流式翻译。
  static void startStreamingTranslateFromPanel(
          TranslationEngine engine, MediaStream stream) =>
      _activeState?._startStreamingTranslate(engine, stream);

  MediaSource? _resolveMediaSource(
    PlaybackInfo playbackInfo, {
    String? preferredMediaSourceId,
  }) {
    final targetSourceId = preferredMediaSourceId ??
        ref.read(selectedMediaSourceProvider) ??
        widget.mediaSourceId;
    return resolvePreferredMediaSource(
      playbackInfo,
      preferredMediaSourceId: targetSourceId,
    );
  }

  void _sanitizeSelectionState(MediaSource? mediaSource) {
    if (mediaSource == null) {
      ref.read(audioTrackProvider.notifier).state = null;
      ref.read(subtitleTrackProvider.notifier).state = null;
      ref.read(secondarySubtitleTrackProvider.notifier).state = null;
      return;
    }

    final audioIndexes = mediaSource.mediaStreams
        .where((stream) => stream.isAudio)
        .map((stream) => stream.index)
        .toSet();
    final subtitleIndexes = mediaSource.mediaStreams
        .where((stream) => stream.isSubtitle)
        .map((stream) => stream.index)
        .toSet();

    final selectedAudioIndex = ref.read(audioTrackProvider);
    if (selectedAudioIndex != null &&
        !audioIndexes.contains(selectedAudioIndex)) {
      ref.read(audioTrackProvider.notifier).state = null;
    }

    final selectedSubtitleIndex = ref.read(subtitleTrackProvider);
    if (selectedSubtitleIndex != null &&
        selectedSubtitleIndex != -1 &&
        !subtitleIndexes.contains(selectedSubtitleIndex)) {
      ref.read(subtitleTrackProvider.notifier).state = null;
    }

    final selectedSecondarySubtitleIndex =
        ref.read(secondarySubtitleTrackProvider);
    if (selectedSecondarySubtitleIndex != null &&
        (!subtitleIndexes.contains(selectedSecondarySubtitleIndex) ||
            selectedSecondarySubtitleIndex ==
                ref.read(subtitleTrackProvider))) {
      ref.read(secondarySubtitleTrackProvider.notifier).state = null;
    }
  }

  // 双指缩放画面：在比例模式之上，用户可双指对画面做缩放裁切（1.0–4.0）。
  double _videoZoom = 1.0;
  double _zoomStartScale = 1.0;
  bool _gestureIsZoom = false;

  Rect _computeContentRect(Size containerSize) {
    if (containerSize.width <= 0 || containerSize.height <= 0) {
      return Rect.zero;
    }
    final mode = ref.read(aspectRatioProvider);
    if (mode == '拉伸') {
      ref.read(aspectRatioProvider.notifier).state = '铺满';
    }
    final safeMode = mode == '全屏' || mode == '拉伸' ? '铺满' : mode;
    final ratio = _resolveDisplayAspectRatio();
    if (ratio == null || ratio <= 0) {
      return Offset.zero & containerSize;
    }

    final containerRatio = containerSize.width / containerSize.height;
    // 铺满：保持比例放大到铺满容器、裁掉溢出（Stack 默认裁剪）。
    if (safeMode == '铺满') {
      if (containerRatio > ratio) {
        final contentHeight = containerSize.width / ratio;
        final top = (containerSize.height - contentHeight) / 2;
        return Rect.fromLTWH(0, top, containerSize.width, contentHeight);
      }
      final contentWidth = containerSize.height * ratio;
      final left = (containerSize.width - contentWidth) / 2;
      return Rect.fromLTWH(left, 0, contentWidth, containerSize.height);
    }
    // 自适应 / 原始 / 16:9 / 4:3：保持比例放进容器（letterbox）。
    if (containerRatio > ratio) {
      final contentWidth = containerSize.height * ratio;
      final left = (containerSize.width - contentWidth) / 2;
      return Rect.fromLTWH(left, 0, contentWidth, containerSize.height);
    }
    final contentHeight = containerSize.width / ratio;
    final top = (containerSize.height - contentHeight) / 2;
    return Rect.fromLTWH(0, top, containerSize.width, contentHeight);
  }

  double? _streamDisplayAspectRatio(MediaStream? stream) {
    if (stream == null || stream.width == null || stream.height == null ||
        stream.width! <= 0 || stream.height! <= 0) return null;
    final dar = stream.aspectRatio;
    if (dar != null) {
      final darMatch = RegExp(r'^(\d+(?:\.\d+)?):(\d+(?:\.\d+)?)$').firstMatch(dar);
      if (darMatch != null) {
        final w = double.tryParse(darMatch.group(1)!);
        final h = double.tryParse(darMatch.group(2)!);
        if (w != null && h != null && h > 0) return w / h;
      }
      final numeric = double.tryParse(dar);
      if (numeric != null && numeric > 0) return numeric;
    }
    final sar = stream.sampleAspectRatio;
    if (sar != null) {
      final match = RegExp(r'^(\d+):(\d+)$').firstMatch(sar);
      final sw = match == null ? null : double.tryParse(match.group(1)!);
      final sh = match == null ? null : double.tryParse(match.group(2)!);
      if (sw != null && sh != null && sh > 0) {
        return stream.width! / stream.height! * sw / sh;
      }
    }
    return stream.width! / stream.height!;
  }
  double? _resolveDisplayAspectRatio() {
    final aspectMode = ref.read(aspectRatioProvider);
    switch (aspectMode) {
      case '16:9':
        return 16 / 9;
      case '4:3':
        return 4 / 3;
      case '21:9':
        return 21 / 9;
      case '原始':
      case '自适应':
      case '自动':
      case '铺满':
      default:
        break;
    }

    final adapter = _playerService.adapter;
    if (adapter is ExoPlayerAdapter) {
      return adapter.videoAspectRatio ?? _initialVideoAspectRatio;
    }
    if (adapter is NativeMpvPlayerAdapter) {
      return adapter.videoAspectRatio ?? _initialVideoAspectRatio;
    }
    return _initialVideoAspectRatio;
  }

  @override
  void initState() {
    super.initState();
    // Anime4K 档位从全局设置同步（设置页/播放器面板均可改）。
    _anime4kMode = ref.read(anime4KLevelProvider);
    WidgetsBinding.instance.addObserver(this);
    // 播放期间保持屏幕常亮，防止观看中自动息屏。
    WakelockPlus.enable();
    // 状态栏系统信息（电量/网速）：每秒刷新，仅在控件显示时可见。
    SystemInfoService.instance.start();
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _playerService.showControls) setState(() {});
    });
    _activeState = this;
    _activeSourcePlay = widget.sourcePlay;
    _sourceCoreOverride =
        widget.sourcePlay?.playerCoreOverride ?? widget.playerCoreOverride;
    _introSkip =
        IntroSkipController(service: ref.read(introSkipServiceProvider));
    _playerService = VideoPlayerService();
    _playerService.addListener(_onPlayerUpdate);
    unawaited(VideoPlayerService.beginPageSystemControls());
    unawaited(_playerService.hydrateSystemControls());
    _startAccelerometerFlipDetection();
    // TV：注册全局遥控处理（方向键快进快退/OK 播放暂停/上下及 MENU 控制栏）。
    // 注册晚于 app_router 的菜单键处理器 → 优先级更高，MENU 不会被路由层拦截。
    if (isTvPlatform) {
      registerGlobalKeyHandler(_handleTvRemoteKey);
    }

    // Delay initialization when using nativeMpv to allow SurfaceView to be created
    // This ensures the AndroidView is rendered before we try to use the SurfaceView
    final coreString = normalizePlayerCore(
        _sourceCoreOverride ?? ref.read(playerCoreProvider));
    if (coreString == 'nativeMpv') {
      // Use addPostFrameCallback to delay until after the first frame is built
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initializePlayer(startPositionOverride: widget.startPosition);
      });
    } else {
      _initializePlayer(startPositionOverride: widget.startPosition);
    }

    // 监听播放器设置变化并下发到播放器
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual(subtitleDelayProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitleDelay(next);
      });
      ref.listenManual(audioDelayProvider, (prev, next) {
        if (prev != next) _playerService.setAudioDelay(next);
      });
      ref.listenManual(subtitleSizeProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitleSize(next);
      });
      ref.listenManual(subtitlePositionProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitlePosition(next);
      });
      ref.listenManual(subtitleFontProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitleFont(next);
      });
      ref.listenManual(subtitleBackgroundProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitleBackground(next);
      });
      ref.listenManual(subtitleTrackProvider, (prev, next) {
        _onSubtitleTrackChanged(prev, next);
      });
      ref.listenManual(secondarySubtitleTrackProvider, (prev, next) {
        _onSecondarySubtitleTrackChanged(next);
      });
      ref.listenManual(secondarySubtitlePositionProvider, (prev, next) {
        if (prev != next) _playerService.setSecondarySubtitlePosition(next);
      });
      ref.listenManual(secondarySubtitleDelayProvider, (prev, next) {
        if (prev != next) _playerService.setSecondarySubtitleDelay(next);
      });
      ref.listenManual(currentPlayingItemProvider, (prev, next) {
        if (prev?.id != next?.id) {
          ref.read(loadedDanmakuProvider.notifier).state = [];
        }
      });
    });
  }

  /// L2 在线重解析：重走 PlaybackInfo→重签 302，产出新的主/兜底播放地址。
  /// 与 [_initializePlayer] 的在线地址构建口径完全一致（含 STRM 直链优先），
  /// 每次都用全新 PlaySessionId，确保拿到新签发的网盘短效链。仅在线流调用。
  Future<ResolvedStreamUrls?> _resolveOnlineStreamUrls(
      ApiClientFactory api) async {
    final info = await api.playback.getPlaybackInfo(widget.itemId);
    final sel = buildPlaybackSelection(
      playbackInfo: info,
      itemId: widget.itemId,
      preferredMediaSourceId:
          widget.mediaSourceId ?? ref.read(selectedMediaSourceProvider),
      versionRegex: ref.read(preferredVersionRegexProvider),
      playSessionId:
          '${widget.itemId}-${DateTime.now().microsecondsSinceEpoch}',
      strmDirectPlay: ref.read(strmDirectPlayProvider),
    );
    final primary = api.playback.getVideoStreamUrl(
      sel.primaryRequest.itemId,
      mediaSourceId: sel.primaryRequest.mediaSourceId,
      container: sel.primaryRequest.container,
      playSessionId: sel.primaryRequest.playSessionId,
      staticStream: sel.primaryRequest.staticStream,
      allowDirectPlay: sel.primaryRequest.allowDirectPlay,
      allowDirectStream: sel.primaryRequest.allowDirectStream,
      allowTranscoding: sel.primaryRequest.allowTranscoding,
      enableAutoStreamCopy: sel.primaryRequest.enableAutoStreamCopy,
      enableAutoStreamCopyAudio: sel.primaryRequest.enableAutoStreamCopyAudio,
      enableAutoStreamCopyVideo: sel.primaryRequest.enableAutoStreamCopyVideo,
    );
    final fb = sel.fallbackRequest == null
        ? null
        : api.playback.getVideoStreamUrl(
            sel.fallbackRequest!.itemId,
            mediaSourceId: sel.fallbackRequest!.mediaSourceId,
            container: sel.fallbackRequest!.container,
            playSessionId: sel.fallbackRequest!.playSessionId,
            staticStream: sel.fallbackRequest!.staticStream,
            allowDirectPlay: sel.fallbackRequest!.allowDirectPlay,
            allowDirectStream: sel.fallbackRequest!.allowDirectStream,
            allowTranscoding: sel.fallbackRequest!.allowTranscoding,
            enableAutoStreamCopy: sel.fallbackRequest!.enableAutoStreamCopy,
            enableAutoStreamCopyAudio:
                sel.fallbackRequest!.enableAutoStreamCopyAudio,
            enableAutoStreamCopyVideo:
                sel.fallbackRequest!.enableAutoStreamCopyVideo,
          );
    final directUrl = sel.directPlayUrl;
    final hasDirect = directUrl != null && directUrl.isNotEmpty;
    return (
      url: hasDirect ? directUrl : primary,
      fallbackUrl: hasDirect ? primary : fb,
    );
  }

  Future<void> _initializePlayer({Duration? startPositionOverride}) async {
    // 每次（重新）初始化都允许再次自动内核降级（手动切回 ExoPlayer 后仍生效）。
    _autoCoreFallbackTried = false;
    // 路由未显式指定时，先恢复该媒体上次手动选择的内核；没有覆盖才使用系统默认。
    if (_sourceCoreOverride == null && _activeSourcePlay == null) {
      final remembered =
          await PlaybackPrefsStore.instance.readPlayerCore(widget.itemId);
      if (remembered != null && mounted) _sourceCoreOverride = remembered;
    }
    // 内核/解码/线路重建必须把旧内核的当前位置作为初始化起点传进去；不能先从
    // 服务端续播点初始化再补 seek，慢速大文件会在补 seek 前开始播放并覆盖本地进度。
    final sourcePlay = _activeSourcePlay;
    if (sourcePlay != null) {
      await _initializeSourcePlayer(
        sourcePlay,
        startPosition: startPositionOverride,
      );
      return;
    }
    final api = ref.read(apiClientProvider);

    // 离线优先：本集已下载完成则用本地文件，且拉取元数据失败时兜底离线播放。
    final downloadManager = ref.read(downloadManagerProvider);
    final localPath = downloadManager.completedFilePath(widget.itemId);
    final hasLocal = localPath != null && await File(localPath).exists();

    MediaItem item;
    PlaybackInfo? playbackInfo;
    try {
      item = await api.media.getItemDetails(widget.itemId);
      playbackInfo = await api.playback.getPlaybackInfo(widget.itemId);
    } catch (e) {
      final record = downloadManager.byItemId(widget.itemId);
      if (!hasLocal || record == null) rethrow;
      // 完全离线：用下载记录还原最简元数据继续播放。
      item = mediaItemFromDownload(record);
      playbackInfo = null;
    }

    final selection = playbackInfo != null
        ? buildPlaybackSelection(
            playbackInfo: playbackInfo,
            itemId: widget.itemId,
            preferredMediaSourceId:
                widget.mediaSourceId ?? ref.read(selectedMediaSourceProvider),
            versionRegex: ref.read(preferredVersionRegexProvider),
            playSessionId:
                '${widget.itemId}-${DateTime.now().microsecondsSinceEpoch}',
            strmDirectPlay: ref.read(strmDirectPlayProvider),
          )
        : buildOfflinePlaybackSelection(itemId: widget.itemId);
    final mediaSource = selection.mediaSource;
    _sanitizeSelectionState(mediaSource);
    // 媒体信息统一源头：无论从详情页还是其它入口（历史/搜索/继续观看/聚合
    // 切换）进入播放器，都用当前实际播放的 MediaSource 兜底/刷新
    // unifiedResource（转换逻辑与详情页 mediaResources 一致），保证右上角
    // 媒体信息菜单显示与详情页底部同源的分辨率/帧率/码率/体积/HDR/编码。
    if (mediaSource != null) {
      ref.read(unifiedResourceProvider.notifier).state =
          unifiedResourceFromMediaSource(mediaSource);
    }
    final videoStream = mediaSource?.primaryVideoStream;
    _initialVideoAspectRatio = _streamDisplayAspectRatio(videoStream);

    final videoUrl = api.playback.getVideoStreamUrl(
      selection.primaryRequest.itemId,
      mediaSourceId: selection.primaryRequest.mediaSourceId,
      container: selection.primaryRequest.container,
      playSessionId: selection.primaryRequest.playSessionId,
      staticStream: selection.primaryRequest.staticStream,
      allowDirectPlay: selection.primaryRequest.allowDirectPlay,
      allowDirectStream: selection.primaryRequest.allowDirectStream,
      allowTranscoding: selection.primaryRequest.allowTranscoding,
      enableAutoStreamCopy: selection.primaryRequest.enableAutoStreamCopy,
      enableAutoStreamCopyAudio:
          selection.primaryRequest.enableAutoStreamCopyAudio,
      enableAutoStreamCopyVideo:
          selection.primaryRequest.enableAutoStreamCopyVideo,
    );
    final fallbackVideoUrl = selection.fallbackRequest == null
        ? null
        : api.playback.getVideoStreamUrl(
            selection.fallbackRequest!.itemId,
            mediaSourceId: selection.fallbackRequest!.mediaSourceId,
            container: selection.fallbackRequest!.container,
            playSessionId: selection.fallbackRequest!.playSessionId,
            staticStream: selection.fallbackRequest!.staticStream,
            allowDirectPlay: selection.fallbackRequest!.allowDirectPlay,
            allowDirectStream: selection.fallbackRequest!.allowDirectStream,
            allowTranscoding: selection.fallbackRequest!.allowTranscoding,
            enableAutoStreamCopy:
                selection.fallbackRequest!.enableAutoStreamCopy,
            enableAutoStreamCopyAudio:
                selection.fallbackRequest!.enableAutoStreamCopyAudio,
            enableAutoStreamCopyVideo:
                selection.fallbackRequest!.enableAutoStreamCopyVideo,
          );

    // STRM 直链：开启且解析出可用直链时优先用直链，服务端直传流作为回退（兼容不支持直链的服务器）。
    final directUrl = selection.directPlayUrl;
    final hasDirect = directUrl != null && directUrl.isNotEmpty;
    final onlineUrl = hasDirect ? directUrl : videoUrl;

    // 本地文件覆盖播放源：用 file:// 形式喂给内核；在线地址作为本地失效时的回退。
    final localFileSource = hasLocal ? Uri.file(localPath).toString() : null;

    // 多线程加载：仅对 Emby 服务端直传流起本地缓存预取代理（2~4 并发 Range）。
    // 跳过本地文件与 STRM/网盘直链（直链需逐流专属 headers）；转码/HLS 无固定大小自动放弃。
    final proxiedUrl = (localFileSource != null || hasDirect)
        ? null
        : await _maybeStartPrefetch(onlineUrl);

    final effectiveVideoUrl = localFileSource ?? proxiedUrl ?? onlineUrl;
    final effectiveFallbackUrl = localFileSource != null
        ? (playbackInfo != null ? onlineUrl : null)
        : (proxiedUrl != null
            ? onlineUrl
            : (hasDirect ? videoUrl : fallbackVideoUrl));

    // Emby 服务端视频端点除了 URL api_key，再同时携带两种官方兼容 Token
    // Header。部分反代/CDN 在 302 或后续 Range 请求时会丢查询参数，表现为
    // Exo/MPV 一直缓冲。STRM 外链、本地文件和本地预取代理绝不注入服务端凭据。
    final authToken = ref.read(currentServerProvider)?.authToken?.trim();
    final embyStreamHeaders = localFileSource == null &&
            proxiedUrl == null &&
            !hasDirect &&
            authToken != null &&
            authToken.isNotEmpty
        ? <String, String>{
            'X-Emby-Token': authToken,
            'X-MediaBrowser-Token': authToken,
          }
        : null;

    Duration? startPosition = startPositionOverride;
    if (startPosition == null) {
      try {
        startPosition = await resolveResumeStartPosition(ref, api, item);
      } catch (_) {
        startPosition = null;
      }
    }
    final startPositionTicks = (startPosition?.inMilliseconds ?? 0) * 10000;

    ref.read(currentPlayingItemProvider.notifier).state = item;
    ref.read(selectedMediaSourceProvider.notifier).state = mediaSource?.id;

    // 播放即自动匹配加载弹幕（动漫走弹弹Play+自定义源，非动漫仅自定义源）。
    unawaited(DanmakuAutoLoader.run(ref, api, item));

    // 自动跳过片头/片尾：联网识别本集片段（仅剧集，受设置开关控制）。
    unawaited(_introSkip.loadForItem(
      item,
      enabled: ref.read(autoSkipSegmentsProvider),
      fetchItem: (id) => api.media.getItemDetails(id),
    ));

    final coreString = normalizePlayerCore(
        _sourceCoreOverride ?? ref.read(playerCoreProvider));
    final coreType = switch (coreString) {
      'mpv' => PlayerCoreType.mpv,
      'nativeMpv' => PlayerCoreType.nativeMpv,
      _ => PlayerCoreType.exoPlayer,
    };

    // 杜比视界自动切换 gpu-next + 软解（默认开，可关）：检测到 DV 视频流且为 mpv 系内核时，
    // 强制 libplacebo(gpu-next) 渲染 + 软件解码——硬件 mediacodec 解 DV 会偏色，软解 + gpu-next
    // 才能正确映射 DV RPU。详见 dolbyAutoGpuNextSwProvider。
    final isMpvFamily =
        coreType == PlayerCoreType.mpv || coreType == PlayerCoreType.nativeMpv;
    final autoDvMode = isMpvFamily &&
        ref.read(dolbyAutoGpuNextSwProvider) &&
        (videoStream?.isDolbyVision ?? false);

    final dolbyVisionFix = coreType == PlayerCoreType.mpv
        ? (autoDvMode || ref.read(mpvDolbyVisionFixProvider))
        : false;
    // nativeMpv 的 libass 内置在 libmpv.so 中，始终启用，不需要开关
    // exoPlayer 需要通过 exoLibass 设置控制
    final useLibass = coreType == PlayerCoreType.exoPlayer
        ? ref.read(exoLibassProvider)
        : false;
    final hardwareDecoding =
        autoDvMode ? false : ref.read(hardwareDecodingProvider);

    final preferredSubtitleLanguage =
        ref.read(preferredSubtitleLanguageProvider);

    // Read gpu-next setting for nativeMpv（DV 自动模式下强制开启）
    final gpuNextEnabled = autoDvMode || ref.read(gpuNextEnabledProvider);

    // Generate a unique surfaceViewId for nativeMpv gpu-next rendering
    // This ID is used to coordinate between Flutter's AndroidView and the native plugin
    final int? surfaceViewId = coreType == PlayerCoreType.nativeMpv
        ? DateTime.now().microsecondsSinceEpoch
        : null;

    // 在 widget 仍 mounted 时捕获 scrobble 所需依赖：onStop 可能在退出
    // 播放页（dispose）后才触发，那时再用 widget 级 ref 会抛
    // "Cannot use ref after the widget was disposed"。
    final watchedThreshold = ref.read(watchedThresholdProvider);
    final syncController = ref.read(syncControllerProvider.notifier);
    _didScrobble = false;

    // L0 取流形态自调档：从 MediaSource 被动推断（远端/Http 直链 → 网盘 302；否则硬盘直传），
    // 据此调节签名链 TTL——网盘短效(3min)、硬盘长链接放宽(30min，近乎不触发暂停重取)。
    StreamServerKind? inferredKind;
    if (playbackInfo != null && mediaSource != null) {
      final remote = (mediaSource.isRemote ?? false) ||
          (mediaSource.protocol?.toLowerCase() == 'http');
      inferredKind =
          remote ? StreamServerKind.cloud302 : StreamServerKind.directDisk;
    }
    final effectiveKind = inferredKind ??
        (ref.read(currentServerProvider)?.streamKind ??
            StreamServerKind.unknown);
    final streamUrlTtl = switch (effectiveKind) {
      StreamServerKind.cloud302 => const Duration(minutes: 3),
      StreamServerKind.directDisk => const Duration(minutes: 30),
      StreamServerKind.unknown => null,
    };

    await _playerService.initialize(
      videoUrl: effectiveVideoUrl,
      itemId: widget.itemId,
      mediaSourceId: mediaSource?.id,
      playSessionId: selection.primaryRequest.playSessionId,
      fallbackVideoUrl: effectiveFallbackUrl,
      startPosition: startPosition,
      coreType: coreType,
      dolbyVisionFix: dolbyVisionFix,
      useLibass: useLibass,
      hardwareDecoding: hardwareDecoding,
      startWithSoftwareDecoding:
          selection.startsWithSoftwareDecoding && hardwareDecoding,
      fallbackReason: selection.fallbackReason,
      preferredSubtitleLanguage: preferredSubtitleLanguage,
      superResolutionLevel: _anime4kMode,
      surfaceViewId: surfaceViewId, // Pass for gpu-next rendering
      useGpuNext: gpuNextEnabled, // Pass gpu-next rendering mode
      httpHeaders: embyStreamHeaders,
      // L2：仅在线流注入重解析回调（本地文件/离线为 null → 退回旧行为）。
      // 断流时服务层据此重走 PlaybackInfo→重签 302→原地续播。
      streamUrlResolver: (localFileSource == null && playbackInfo != null)
          ? () => _resolveOnlineStreamUrls(api)
          : null,
      streamUrlTtl: streamUrlTtl,
      onStart: (info) async {
        try {
          await api.playback.reportPlaybackStart(info);
        } catch (_) {}
        await _writeWatchHistoryForItem(
          item: item,
          positionTicks: startPositionTicks,
          incrementPlayCount: true,
          force: true,
        );
        // Trakt scrobble/start：账号显示「正在观看」（续播时带上起播进度）。
        final runtime = item.runTimeTicks;
        final startProgress = (runtime != null && runtime > 0)
            ? (startPositionTicks / runtime * 100).clamp(0, 100).toDouble()
            : 0.0;
        unawaited(syncController.scrobbleStart(item, progress: startProgress));
      },
      onProgress: (info) async {
        // 让出当前帧：progress 上报（网络请求构造/历史写入的同步段）在
        // 5 秒 Timer tick 同步执行会阻塞主线程丢帧——弹幕 Ticker 丢一帧
        // 位移跳 ~2px（表现为每 5 秒弹幕轻跳一两个像素）。endOfFrame 等当
        // 帧渲染完成后再执行上报，避免阻塞弹幕 ticker。
        await WidgetsBinding.instance.endOfFrame;
        try {
          await api.playback.reportPlaybackProgress(info);
        } catch (_) {}
        await _writeWatchHistoryForItem(
          item: item,
          positionTicks: info.positionTicks,
        );
      },
      onStop: (info) async {
        try {
          await api.playback.reportPlaybackStopped(info);
        } catch (_) {}
        await _writeWatchHistoryForItem(
          item: item,
          positionTicks: info.positionTicks,
          force: true,
        );
        await _scrobbleOnStop(
            info, item, api, watchedThreshold, syncController);
        // 看完一集后刷新媒体库网格，让封面右上角"未看集数"角标随之 -1。
        if (mounted) ref.invalidate(libraryItemsProvider);
      },
    );

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    await _playerService.play();
    // L0：回填推断出的取流形态（下次播放即可据持久化值直接调档）。
    if (inferredKind != null) {
      final server = ref.read(currentServerProvider);
      if (server != null && server.streamKind != inferredKind) {
        ref.read(serverListProvider.notifier).setStreamKind(
              server.id,
              inferredKind,
            );
      }
    }

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // 轨道相关的挑轨（字幕/音频/次字幕）挪到后台，不阻塞起播与其它初始化：libmpv 0.41
    // 对大流 demux 较慢，等内封轨道就绪可能要十几秒，绝不能卡在这条主初始化链上，
    // 否则表现为「视频加载变慢 + 内封字幕迟迟不出/选轨崩溃」。
    if (mediaSource != null) {
      unawaited(_applyTrackSelections(item, mediaSource));
    }

    _playerService.setSubtitleSize(_effectiveSubtitleSize());
    _playerService.setSubtitlePosition(ref.read(subtitlePositionProvider));
    _playerService.setSubtitleDelay(ref.read(subtitleDelayProvider));
    _playerService.setSubtitleFont(ref.read(subtitleFontProvider));
    _playerService.setSubtitleBackground(ref.read(subtitleBackgroundProvider));
    _playerService.setAspectRatio(ref.read(aspectRatioProvider));

  }

  /// 网盘/聚合源直链播放初始化：复用本播放页全部 UI/手势/弹幕/字幕能力。
  Future<void> _initializeSourcePlayer(SourcePlayback sp,
      {Duration? startPosition}) async {
    final backend = mediaSourceBackendFor(sp.server.sourceKind);
    try {
      final qualityId = ref.read(sourceSelectedQualityProvider) ?? sp.qualityId;
      final play =
          await backend.resolvePlay(sp.server, sp.entry, qualityId: qualityId);
      final cfg = resolveSourcePlayerConfig(
        ref,
        coreOverride: _sourceCoreOverride,
      );
      final spItem = sp.toMediaItem();
      ref.read(currentPlayingItemProvider.notifier).state = spItem;
      unawaited(DanmakuAutoLoader.run(ref, null, spItem));
      ref.read(sourcePlayQualitiesProvider.notifier).state = play.qualities;
      if (ref.read(sourceSelectedQualityProvider) == null) {
        ref.read(sourceSelectedQualityProvider.notifier).state =
            play.selectedQualityId;
      }
      _sourcePlayMetadata = play.sourceMetadata.isEmpty
          ? null
          : Map<String, dynamic>.from(play.sourceMetadata);
      final effectiveStart =
          sp.startPosition ?? startPosition ?? play.resumePosition;
      await _playerService.initialize(
        videoUrl: play.url,
        itemId: sp.syntheticItemId,
        startPosition: effectiveStart,
        coreType: cfg.coreType,
        hardwareDecoding: cfg.hardwareDecoding,
        useLibass: cfg.useLibass,
        useGpuNext: cfg.useGpuNext,
        surfaceViewId: cfg.surfaceViewId,
        httpHeaders: play.httpHeaders.isEmpty ? null : play.httpHeaders,
        userAgentOverride: play.userAgentOverride,
        // 网盘短效直链：过期后按当前选中清晰度重解析续播。
        streamUrlResolver: () async {
          final q = ref.read(sourceSelectedQualityProvider) ?? sp.qualityId;
          final fresh =
              await backend.resolvePlay(sp.server, sp.entry, qualityId: q);
          return (url: fresh.url, fallbackUrl: null);
        },
        streamUrlTtl: const Duration(minutes: 3),
      );
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await _playerService.play();
      _startSourceProgressReporting(sp);
      // 媒体信息统一源头：/source-player 路径（飞牛库页/播放器聚合切换等
      // 非详情页入口）下 unifiedResource 可能为空或残留旧媒体值；异步拉
      // mediaDetails 填充当前媒体的完整流信息（失败静默，不阻塞播放），
      // 保证右上角媒体信息菜单与详情页底部同源。
      unawaited(() async {
        try {
          final details = await FeiniuBackend().mediaDetails(sp.server, sp.entry);
          if (!mounted) return;
          ref.read(unifiedResourceProvider.notifier).state =
              unifiedResourceFromFeiniuDetails(details);
        } catch (_) {
          // 流信息拉取失败不影响播放本身。
        }
      }());
      if (play.subtitles.isNotEmpty) {
        try {
          await _playerService.loadLibassSubtitle(play.subtitles.first.url);
        } catch (_) {}
      }
      unawaited(_applySourceTrackPreferences(sp));
      _playerService.setSubtitleSize(_effectiveSubtitleSize());
      _playerService.setSubtitlePosition(ref.read(subtitlePositionProvider));
      _playerService.setSubtitleDelay(ref.read(subtitleDelayProvider));
      _playerService.setSubtitleFont(ref.read(subtitleFontProvider));
      _playerService
          .setSubtitleBackground(ref.read(subtitleBackgroundProvider));
      _playerService.setAspectRatio(ref.read(aspectRatioProvider));
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '播放失败: $e',
            kind: AppToastKind.error, position: AppToastPosition.topCenter);
        Navigator.of(context).maybePop();
      }
    }
  }

  Future<void> _applySourceTrackPreferences(SourcePlayback sp) async {
    final audioIndex = sp.preferredAudioListIndex;
    var subtitleIndex = sp.preferredSubtitleListIndex;
    // 历史/聚合切换直进播放器未携带字幕列表索引时，恢复上次手动选择
    // （列表索引；-1=显式关闭保持关闭，null=未手动选过不干预内核默认）。
    if (subtitleIndex == null) {
      subtitleIndex =
          (await PlaybackPrefsStore.instance.read(widget.itemId)).subtitleIndex;
    }

    // 所有直播放入口都等待内核真实轨道，随后同步选择状态和右下角面板。
    for (var attempt = 0; attempt < 100; attempt++) {
      if (!mounted) return;
      final tracks = _playerService.tracksInfo;
      final audios = tracks.where((t) => t['type'] == 'audio').toList();
      final subtitles = tracks
          .where((t) => t['type'] == 'text' || t['type'] == 'bitmap')
          .toList();
      final audioReady = audios.isNotEmpty;
      final subtitleReady = subtitles.isNotEmpty || attempt >= 15;
      if (audioReady && subtitleReady) {
        if (audioIndex != null && audioIndex >= 0 && audios.length > audioIndex) {
          await _playerService
              .selectAudioTrack(audios[audioIndex]['id'].toString());
        }
        final selectedAudio = audios.where((track) =>
            track['isSelected'] == true || track['selected'] == true).firstOrNull;
        ref.read(audioTrackProvider.notifier).state =
            int.tryParse('${selectedAudio?['id']}');
        if (subtitleIndex != null) {
          if (subtitleIndex < 0) {
            await _playerService.deselectSubtitleTrack();
          } else if (subtitles.length > subtitleIndex) {
            await _playerService
                .selectSubtitleTrack(subtitles[subtitleIndex]['id'].toString());
          }
        }
        final selectedSubtitle = subtitles.where((track) =>
            track['isSelected'] == true || track['selected'] == true).firstOrNull;
        ref.read(subtitleTrackProvider.notifier).state = selectedSubtitle == null
            ? -1
            : int.tryParse('${selectedSubtitle['id']}');
        if (mounted) setState(() {});
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    AppLogger().w('FeiniuTracks', '等待飞牛音轨/字幕轨就绪超时');
  }

  void _startSourceProgressReporting(SourcePlayback sp) {
    _sourceProgressTimer?.cancel();
    _lastSourceProgressSecond = -1;
    _sourceCompletionReported = false;
    if (sp.server.sourceKind != SourceKind.feiniu ||
        _sourcePlayMetadata == null) {
      return;
    }
    _sourceProgressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_reportSourceProgress(sp));
    });
  }

  Future<void> _writeSourceWatchHistory(SourcePlayback sp,
      {bool force = false}) async {
    // 隐藏服务器不记播放记录（历史/续播/状态栏不出现），但卡片「最近观影」
    // 时间戳独立更新——隐藏删除历史后卡片仍与其他服务器一致显示。
    if (sp.server.hidden) {
      ref
          .read(serverListProvider.notifier)
          .updateLastWatchedAt(sp.server.id, DateTime.now());
      return;
    }
    final scopeKey = buildWatchHistoryScopeKey(sp.server);
    final duration = _playerService.duration;
    if (scopeKey == null || duration <= Duration.zero || !mounted) return;
    final item = sp.toMediaItem(
      runTimeTicks: duration.inMilliseconds * 10000,
    );
    try {
      await ref.read(watchHistoryProvider).capturePlayback(
            scopeKey: scopeKey,
            api: ref.read(apiClientProvider),
            item: item,
            positionTicks: _playerService.position.inMilliseconds * 10000,
            source: WatchHistoryWriteSource.internalPlayer,
            watchedThresholdPercent: ref.read(watchedThresholdProvider),
            sourceEntryId: sp.entry.id,
            sourcePosterUrl: sp.entry.thumbUrl,
            playerCore: _currentCore,
            incrementPlayCount: _lastSourceProgressSecond < 0,            force: force,
          );
      // 播放成功写历史 → 更新服务器配置上的「最近观影」时间戳
      // （独立于历史存储，隐藏服务器删除历史后卡片仍显示）。
      ref
          .read(serverListProvider.notifier)
          .updateLastWatchedAt(sp.server.id, DateTime.now());
    } catch (_) {
      // 本地记录失败不能中断来源播放和服务端进度回传。
    }
  }

  /// 当前生效的播放内核（来源覆盖优先，其次全局偏好）。
  String get _currentCore => normalizePlayerCore(
      _sourceCoreOverride ?? ref.read(playerCoreProvider));

  Future<void> _reportSourceProgress(SourcePlayback sp,
      {bool force = false}) async {
    if (sp.server.sourceKind != SourceKind.feiniu ||
        _sourcePlayMetadata == null ||
        _sourceProgressWriteInFlight) {
      return;
    }
    final position = _playerService.position;
    final duration = _playerService.duration;
    if (duration <= Duration.zero) return;
    final second = position.inSeconds;
    if (!force && second == _lastSourceProgressSecond) return;

    _sourceProgressWriteInFlight = true;
    try {
      await _writeSourceWatchHistory(sp, force: force);
      await FeiniuBackend().recordPlayback(
        sp.server,
        playMetadata: _sourcePlayMetadata!,
        position: position,
        duration: duration,
      );
      _lastSourceProgressSecond = second;
    } catch (error, stackTrace) {
      AppLogger().eWithStack('FeiniuProgress', '飞牛播放进度回传失败', error, stackTrace);
    } finally {
      _sourceProgressWriteInFlight = false;
    }
  }

  /// 播放内切换清晰度：记当前进度，按新档重解析并续播。
  Future<void> _switchSourceQuality(String qualityId) async {
    final sp = _activeSourcePlay;
    if (sp == null) return;
    final pos = _playerService.position;
    ref.read(sourceSelectedQualityProvider.notifier).state = qualityId;
    await _initializeSourcePlayer(sp, startPosition: pos);
  }

  /// mpv 内核（nativeMpv）**未调节过**字幕大小时用 mpv 标准 1.0：
  /// 同一字幕 exo 显示正常、mpv 只有 50%，根因是 sub-scale 收到默认
  /// 0.5（Kotlin 注释意图为 1.0）；exo 渲染基准不同，保持 0.5 默认不动。
  /// 用户在滑块上调过（subtitleSizeTouchedProvider=true）后一律用用户值。
  double _effectiveSubtitleSize() {
    if (ref.read(subtitleSizeTouchedProvider)) {
      final v = ref.read(subtitleSizeProvider);
      AppLogger().i('Player', '字幕大小(用户已调): $v');
      return v;
    }
    final v = _playerService.coreType == PlayerCoreType.nativeMpv
        ? 1.0
        : ref.read(subtitleSizeProvider);
    AppLogger().i('Player', '字幕大小(默认): core=${_playerService.coreType} -> $v');
    return v;
  }

  /// 后台挑轨：等内封轨道就绪（仅在有内封字幕时才等）后，依次应用字幕/音频/次字幕选择。
  /// 从初始化主链拆出来，避免 0.41 的慢 demux 把起播后的 UI 初始化卡住十几秒，也让
  /// 内封字幕在轨道就绪后可靠选中（[_waitForTracksReady] 现在不阻塞主链，可放心等久些）。
  Future<void> _applyTrackSelections(
      MediaItem item, MediaSource mediaSource) async {
    final expectsInternalSub = mediaSource.mediaStreams
        .any((s) => s.isSubtitle && !(s.isExternal ?? false));
    if (expectsInternalSub) await _waitForTracksReady();
    if (!mounted) return;

    // 字幕（内封/外挂）：未手动选轨时按正则/首选语言自动挑，已选轨的实际选择在下方完成。
    await _loadSubtitles(item, mediaSource);
    if (!mounted) return;

    // 音频：正则自动挑轨（用户未手动选时）。
    final audioStreams =
        mediaSource.mediaStreams.where((stream) => stream.isAudio).toList();
    var selectedAudioIndex = ref.read(audioTrackProvider);
    if (selectedAudioIndex == null && audioStreams.isNotEmpty) {
      final audioMatch = matchPreferredStream(
          audioStreams, ref.read(preferredAudioRegexProvider));
      if (audioMatch != null) {
        selectedAudioIndex = audioMatch.index;
        ref.read(audioTrackProvider.notifier).state = audioMatch.index;
      } else {
        // 未配置正则/无命中：按内核策略默认选轨——ExoPlayer 兼容优先（先选
        // Media3 必可解码的 AAC/Opus/…，DTS 系垫底），MPV 音质优先（先选
        // TrueHD/DTS-HD/DTS）。与详情页音频按钮同一套排序（track_preference）。
        final preferQuality = normalizePlayerCore(
                _sourceCoreOverride ?? ref.read(playerCoreProvider)) !=
            'exoPlayer';
        final sorted = sortAudioIndexes(
          audioStreams.length,
          (i) => audioCodecOf(audioStreams[i]),
          preferQuality: preferQuality,
        );
        if (sorted.isNotEmpty) {
          selectedAudioIndex = audioStreams[sorted.first].index;
          ref.read(audioTrackProvider.notifier).state = selectedAudioIndex;
        }
      }
    }
    if (selectedAudioIndex != null) {
      await _applyInitialAudioTrack(audioStreams, selectedAudioIndex);
    }
    if (!mounted) return;

    final selectedSubtitleIndex = ref.read(subtitleTrackProvider);
    if (selectedSubtitleIndex != null) {
      await _onSubtitleTrackChanged(null, selectedSubtitleIndex);
    }
    if (!mounted) return;

    final selectedSecondarySubtitleIndex =
        ref.read(secondarySubtitleTrackProvider);
    if (selectedSecondarySubtitleIndex != null) {
      await _onSecondarySubtitleTrackChanged(selectedSecondarySubtitleIndex);
    }
  }

  Future<void> _waitForTracksReady() async {
    // 现在跑在后台（不阻塞主初始化链），可放心等久些：0.41 大流 demux 可能十几秒才吐出
    // 内封字幕轨。返回条件是「轨道已出现」，一旦就绪立即返回，不会白等满。
    for (int i = 0; i < 100; i++) {
      final tracks = _playerService.tracksInfo;
      final subtitleTracks = tracks
          .where((t) =>
              (t['type'] == 'text' || t['type'] == 'bitmap') &&
              t['id'] != 'auto' &&
              t['id'] != 'no')
          .toList();
      if (subtitleTracks.isNotEmpty) return;
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
    }
    AppLogger().w('Player', '等待轨道就绪超时，继续加载');
  }

  MediaStream _pickPreferredChineseSubtitle(
      List<MediaStream> streams, String? preferredLanguage) {
    const simplified = ['简体', '简中', '简日', 'chs', 'zh-hans', 'sc'];
    const chineseLanguages = ['chs', 'chi', 'zho', 'zh', 'zh-cn', 'zh-hans'];
    bool textContains(MediaStream stream, List<String> words) {
      final text =
          '${stream.displayTitle ?? ''} ${stream.title ?? ''} ${stream.language ?? ''}'
              .toLowerCase();
      return words.any(text.contains);
    }

    for (final stream in streams) {
      if (textContains(stream, simplified)) return stream;
    }
    for (final stream in streams) {
      if (chineseLanguages.contains(stream.language?.toLowerCase()) ||
          textContains(stream, const ['中文', '中字'])) {
        return stream;
      }
    }
    for (final stream in streams) {
      if (stream.language?.toLowerCase() == preferredLanguage?.toLowerCase()) {
        return stream;
      }
    }
    return streams.first;
  }

  Future<void> _loadSubtitles(MediaItem item, MediaSource mediaSource) async {
    final logger = AppLogger();
    final api = ref.read(apiClientProvider);
    final subtitleStreams =
        mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();

    logger.i('Player', '开始加载字幕 - 可用字幕流: ${subtitleStreams.length} 个');

    if (subtitleStreams.isEmpty) {
      logger.w('Player', '没有可用字幕流');
      return;
    }

    final userSelectedSubtitleIndex = ref.read(subtitleTrackProvider);
    if (userSelectedSubtitleIndex != null) {
      logger.i('Player', '保留用户在详情页中选择的字幕轨道: $userSelectedSubtitleIndex');
      return;
    }

    // 跨会话恢复上次手动选择的字幕（Emby/离线播放链；飞牛 source-player 走
    // _applySourceTrackPreferences，不经此路径）：记录缺失(null)时走下方自动
    // 猜测；-1=显式关闭保持关闭；>=0=上次选中的流索引，当前媒体源仍有该流
    // 则直接恢复（由 _applyTrackSelections 统一应用），换版本/资源导致流
    // 不存在时回退自动猜测。
    if (widget.sourcePlay == null) {
      final remembered =
          await PlaybackPrefsStore.instance.read(widget.itemId);
      final rememberedSubtitle = remembered.subtitleIndex;
      if (rememberedSubtitle == -1) {
        logger.i('Player', '恢复上次字幕选择: 显式关闭');
        ref.read(subtitleTrackProvider.notifier).state = -1;
        return;
      }
      if (rememberedSubtitle != null &&
          rememberedSubtitle >= 0 &&
          subtitleStreams.any((s) => s.index == rememberedSubtitle)) {
        logger.i('Player', '恢复上次字幕选择: 流索引 $rememberedSubtitle');
        ref.read(subtitleTrackProvider.notifier).state = rememberedSubtitle;
        return;
      }
    }

    for (final stream in subtitleStreams) {
      logger.d('Player',
          '字幕流: index=${stream.index}, codec=${stream.codec}, language=${stream.language}, external=${stream.isExternal}, title=${stream.displayTitle}');
    }

    final preferredLang = ref.read(preferredSubtitleLanguageProvider);
    // 「字幕选择」正则优先：命中则用正则结果，否则回退到首选字幕语言。
    final subtitleRegex = ref.read(preferredSubtitleRegexProvider);
    final regexMatched = matchPreferredStream(subtitleStreams, subtitleRegex);
    logger.i('Player',
        '首选字幕语言: $preferredLang, 字幕正则: "$subtitleRegex", 正则命中: ${regexMatched?.index}');

    final target = regexMatched ??
        _pickPreferredChineseSubtitle(subtitleStreams, preferredLang);

    final codec = target.codec?.toLowerCase() ?? 'ass';
    final isExternal = target.isExternal ?? false;
    final targetIndex = target.index;
    final isGraphical = _isGraphicalSubtitleCodec(codec);
    final isAss = _isAssSubtitleCodec(codec);
    logger.i('Player',
        '选择字幕: index=$targetIndex, codec=$codec, language=${target.language}, external=$isExternal, graphical=$isGraphical, isAss=$isAss');

    ref.read(subtitleTrackProvider.notifier).state = targetIndex;

    if (!isExternal) {
      final isExoAss = isAss &&
          !isGraphical &&
          _playerService.coreType == PlayerCoreType.exoPlayer;

      if (isExoAss) {
        logger.i('Player', 'EXO内核: 内封ASS字幕直接走Media3轨道选择，由原生ASS管线处理');
        try {
          await _selectInternalSubtitleEXO(target, preferredLang, logger);
        } catch (e, stackTrace) {
          logger.eWithStack('Player', 'EXO内封ASS轨道选择失败，回退原生选择', e, stackTrace);
          await _selectInternalSubtitleEXO(target, preferredLang, logger);
        }
      } else {
        logger.i('Player', '内封字幕，通过播放器轨道选择');
        try {
          if (_playerService.coreType == PlayerCoreType.mpv ||
              _playerService.coreType == PlayerCoreType.nativeMpv) {
            await _selectInternalSubtitleMPV(target, preferredLang, logger);
          } else {
            await _selectInternalSubtitleEXO(target, preferredLang, logger);
          }
        } catch (e, stackTrace) {
          logger.eWithStack('Player', '内封字幕轨道选择失败', e, stackTrace);
        }
      }
      return;
    }

    try {
      if (_playerService.coreType == PlayerCoreType.mpv ||
          _playerService.coreType == PlayerCoreType.nativeMpv) {
        final embyCodec = _embySubtitleCodec(codec);
        final subUrl = api.playback.getSubtitleStreamUrl(
          widget.itemId,
          mediaSource.id,
          targetIndex,
          embyCodec,
        );
        if (isGraphical) {
          final ext = _subtitleFileExtension(codec, _playerService.coreType);
          final subFile = await _downloadSubtitleToTempFile(
            subtitleUrl: subUrl,
            fileName: 'subtitle_${widget.itemId}_$targetIndex.$ext',
          );
          logger.i('Player', 'MPV内核: 图形外挂字幕使用本地文件: ${subFile.path}');
          if (subFile.existsSync() && await subFile.length() > 0) {
            await _playerService.loadLibassSubtitle(subFile.path);
          }
        } else {
          logger.i('Player', 'MPV内核: 直接加载Emby字幕URL: $subUrl');
          await _playerService.loadLibassSubtitle(subUrl);
        }
        logger.i('Player', 'MPV外挂字幕加载成功');

        if (mounted) {
          AppToast.show(context,
              '外挂字幕: ${target.language ?? '默认'} (${codec.toUpperCase()})',
              position: AppToastPosition.topCenter);
        }
      } else {
        final embyCodec = _embySubtitleCodec(codec);
        final subUrl = api.playback.getSubtitleStreamUrl(
          widget.itemId,
          mediaSource.id,
          targetIndex,
          embyCodec,
        );
        logger.i('Player', 'EXO内核: 下载字幕后再加载: $subUrl');

        final ext = _subtitleFileExtension(codec, _playerService.coreType);
        final subFile = await _prepareSubtitleFileForPlayer(
          subtitleUrl: subUrl,
          fileName: 'subtitle_${widget.itemId}_$targetIndex.$ext',
          codec: codec,
          coreType: _playerService.coreType,
          logger: logger,
        );
        logger.i('Player', '字幕下载完成/使用缓存 (${await subFile.length()} bytes)');

        if (subFile.existsSync() && await subFile.length() > 0) {
          await _playerService.loadLibassSubtitle(subFile.path);
          logger.i('Player', 'EXO外挂字幕加载成功');

          if (mounted) {
            AppToast.show(context,
                '外挂字幕: ${target.language ?? '默认'} (${codec.toUpperCase()})',
                position: AppToastPosition.topCenter);
          }
        }
      }
    } catch (e, stackTrace) {
      logger.eWithStack('Player', '外挂字幕加载失败', e, stackTrace);
      if (mounted) {
        AppToast.show(context, '字幕加载失败: $e',
            kind: AppToastKind.error, position: AppToastPosition.topCenter);
      }
    }
  }

  // 字幕编解码归一收敛到公共 [PlayerSubtitleLoader]（三端共用，逻辑一致）。
  String _embySubtitleCodec(String codec) =>
      PlayerSubtitleLoader.embySubtitleCodec(codec, _playerService.coreType);

  String _subtitleFileExtension(String codec, PlayerCoreType coreType) =>
      PlayerSubtitleLoader.subtitleFileExtension(codec, coreType);

  bool _isAssSubtitleCodec(String codec) =>
      PlayerSubtitleLoader.isAssSubtitleCodec(codec);

  bool _isGraphicalSubtitleCodec(String codec) =>
      PlayerSubtitleLoader.isGraphicalSubtitleCodec(codec);

  Future<File> _prepareSubtitleFileForPlayer({
    required String subtitleUrl,
    required String fileName,
    required String codec,
    required PlayerCoreType coreType,
    required AppLogger logger,
  }) async {
    final sourceFile = await _downloadSubtitleToTempFile(
      subtitleUrl: subtitleUrl,
      fileName: fileName,
    );

    if (coreType != PlayerCoreType.exoPlayer) {
      return sourceFile;
    }

    if (_isAssSubtitleCodec(codec)) {
      final preferLibass = ref.read(exoLibassProvider);
      if (preferLibass) {
        logger.i('Player', 'EXO内核: ASS/SSA 保留原文件，交给Media3原生ASS管线处理');
        return sourceFile;
      }

      final convertedPath = await SubtitleProcessor.convertAssToSrt(
        sourceFile.path,
        outputPath: sourceFile.path.replaceFirst(RegExp(r'\.[^.]+$'), '.srt'),
      );
      logger.i('Player', 'EXO内核: ASS/SSA 已转换为 SRT 兼容播放: $convertedPath');
      return File(convertedPath);
    }

    if (_isGraphicalSubtitleCodec(codec)) {
      logger.w('Player', 'EXO内核: 图形字幕仍依赖 Media3 设备侧解析，若不显示请切换 MPV');
    }

    return sourceFile;
  }

  Future<File> _downloadSubtitleToTempFile({
    required String subtitleUrl,
    required String fileName,
  }) async {
    final server = ref.read(currentServerProvider);
    final tempDir = await getTemporaryDirectory();
    final subFile = File('${tempDir.path}/$fileName');

    if (!subFile.existsSync() || await subFile.length() == 0) {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ));
      if (server?.authToken != null) {
        dio.options.headers['X-Emby-Token'] = server!.authToken;
        dio.options.headers['X-MediaBrowser-Token'] = server.authToken;
      }
      await dio.download(subtitleUrl, subFile.path);
    }

    return subFile;
  }

  Future<void> _selectInternalSubtitleMPV(
      MediaStream target, String? preferredLang, AppLogger logger) async {
    final tracks = _playerService.tracksInfo;
    final subtitleTracks = tracks
        .where((t) =>
            (t['type'] == 'text' || t['type'] == 'bitmap') &&
            t['id'] != 'auto' &&
            t['id'] != 'no')
        .toList();
    logger.i('Player', 'MPV 可用字幕轨道: ${subtitleTracks.length} 个');
    for (final track in subtitleTracks) {
      logger.d('Player',
          '  轨道: id=${track['id']}, title=${track['title']}, language=${track['language']}, codec=${track['codec']}, type=${track['type']}');
    }

    if (subtitleTracks.isEmpty) {
      logger.w('Player', 'MPV 无可用字幕轨道 - 回退到 auto 选择');
      await _playerService.selectSubtitleTrack('auto');
      return;
    }

    String? trackId;
    final codec = target.codec?.toLowerCase() ?? '';
    final isGraphical = codec == 'pgssub' ||
        codec == 'sup' ||
        codec == 'pgs' ||
        codec == 'dvdsub' ||
        codec == 'vobsub' ||
        codec.contains('hdmv') ||
        codec.contains('pgs');

    if (isGraphical) {
      final bitmapMatches = subtitleTracks
          .where((t) => t['type'] == 'bitmap' || (t['isBitmap'] == true))
          .toList();
      if (bitmapMatches.isNotEmpty) {
        final targetTitle = target.displayTitle ?? target.title;
        if (targetTitle != null && targetTitle.isNotEmpty) {
          for (final t in bitmapMatches) {
            final tTitle = t['title']?.toString() ?? '';
            if (tTitle.isNotEmpty && _titlesMatch(targetTitle, tTitle)) {
              trackId = t['id']?.toString();
              break;
            }
          }
        }
        if (trackId == null) {
          final langMatch = bitmapMatches
              .where((t) =>
                  t['language'] == preferredLang ||
                  t['language'] == 'chi' ||
                  t['language'] == 'zh')
              .toList();
          trackId = (langMatch.isNotEmpty ? langMatch : bitmapMatches)
              .first['id']
              ?.toString();
        }
      }
    }

    trackId ??= _matchMpvSubtitleTrack(
      subtitleTracks,
      target.language,
      target.displayTitle ?? target.title,
      target.codec,
      target.index,
    );

    if (trackId != null) {
      await _playerService.selectSubtitleTrack(trackId);
      logger.i('Player', 'MPV 已选择内封字幕轨道: $trackId');
    } else {
      logger.w('Player', 'MPV 未找到匹配的字幕轨道');
    }
  }

  Future<void> _selectInternalSubtitleEXO(
      MediaStream target, String? preferredLang, AppLogger logger) async {
    final tracks = _playerService.tracksInfo;
    var subtitleTracks = tracks
        .where((t) => t['type'] == 'text' || t['type'] == 'bitmap')
        .toList();
    logger.i('Player', 'EXO 可用字幕轨道: ${subtitleTracks.length} 个');

    if (subtitleTracks.isEmpty) {
      logger.w('Player', 'EXO 无可用字幕轨道 - 等待轨道就绪后重试');
      for (int i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 300));
        final retryTracks = _playerService.tracksInfo
            .where((t) => t['type'] == 'text' || t['type'] == 'bitmap')
            .toList();
        if (retryTracks.isNotEmpty) {
          subtitleTracks = retryTracks;
          logger.i('Player', 'EXO 轨道就绪 - 可用字幕轨道: ${subtitleTracks.length} 个');
          break;
        }
      }
      if (subtitleTracks.isEmpty) {
        logger.w('Player', 'EXO 等待轨道超时，放弃字幕选择');
        return;
      }
    }

    final codec = target.codec?.toLowerCase() ?? '';
    final isGraphical = codec == 'pgssub' ||
        codec == 'sup' ||
        codec == 'pgs' ||
        codec == 'dvdsub' ||
        codec == 'vobsub' ||
        codec.contains('hdmv') ||
        codec.contains('pgs');

    String? trackId;

    if (isGraphical) {
      final bitmapTracks = subtitleTracks
          .where((t) => t['type'] == 'bitmap' || t['isBitmap'] == true)
          .toList();
      if (bitmapTracks.isNotEmpty) {
        final targetTitle = target.displayTitle ?? target.title;
        if (targetTitle != null && targetTitle.isNotEmpty) {
          for (final t in bitmapTracks) {
            final tTitle =
                t['title']?.toString() ?? t['label']?.toString() ?? '';
            if (tTitle.isNotEmpty && _titlesMatch(targetTitle, tTitle)) {
              trackId = t['id']?.toString();
              break;
            }
          }
        }
        if (trackId == null) {
          final langMatch = bitmapTracks
              .where((t) =>
                  t['language'] == preferredLang ||
                  t['language'] == 'chi' ||
                  t['language'] == 'zh')
              .toList();
          final targetList = langMatch.isNotEmpty ? langMatch : bitmapTracks;
          trackId = targetList.first['id']?.toString();
        }
      }
    }

    trackId ??= _matchExoSubtitleTrack(
      subtitleTracks,
      target.language,
      target.displayTitle ?? target.title,
      target.codec,
      target.index,
    );

    if (trackId != null && trackId.isNotEmpty) {
      await _playerService.selectSubtitleTrack(trackId);
      logger.i('Player', 'EXO 已选择内封字幕轨道: id=$trackId');

      // PGS 字幕提示：显示能力依赖设备侧 Media3 解码输出，异常时建议切换 MPV
      if (isGraphical && mounted) {
        AppToast.show(context, 'PGS字幕加载中，如无法显示请切换MPV内核',
            position: AppToastPosition.topCenter);
      }
    }
  }

  // 内封字幕匹配统一委托公共 [PlayerSubtitleLoader]（三端一致、单一来源）。
  String? _matchMpvSubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks,
    String? targetLang,
    String? targetTitle,
    String? targetCodec,
    int targetStreamIndex,
  ) =>
      PlayerSubtitleLoader.matchMpvSubtitleTrack(subtitleTracks, targetLang,
          targetTitle, targetCodec, targetStreamIndex);

  String? _matchMpvSecondarySubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks,
    MediaStream target,
    String? primaryTrackId,
  ) =>
      PlayerSubtitleLoader.matchMpvSecondarySubtitleTrack(
          subtitleTracks, target, primaryTrackId);

  String? _matchExoSubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks,
    String? targetLang,
    String? targetTitle,
    String? targetCodec,
    int targetStreamIndex,
  ) =>
      PlayerSubtitleLoader.matchExoSubtitleTrack(subtitleTracks, targetLang,
          targetTitle, targetCodec, targetStreamIndex);

  bool _titlesMatch(String embyTitle, String playerTitle) =>
      PlayerSubtitleLoader.titlesMatch(embyTitle, playerTitle);

  Future<void> _selectInternalSubtitleViaTrack(
      MediaStream target, int next, AppLogger logger) async {
    final tracks = _playerService.tracksInfo;
    final subtitleTracks = tracks
        .where((t) =>
            (t['type'] == 'text' || t['type'] == 'bitmap') &&
            t['id'] != 'auto' &&
            t['id'] != 'no')
        .toList();

    String? trackId;
    final targetDisplayTitle = target.displayTitle ?? target.title;

    if (_playerService.coreType == PlayerCoreType.mpv ||
        _playerService.coreType == PlayerCoreType.nativeMpv) {
      trackId = _matchMpvSubtitleTrack(
        subtitleTracks,
        target.language,
        targetDisplayTitle,
        target.codec,
        next,
      );
    } else {
      trackId = _matchExoSubtitleTrack(
        subtitleTracks,
        target.language,
        targetDisplayTitle,
        target.codec,
        next,
      );
    }

    if (trackId != null) {
      await _playerService.selectSubtitleTrack(trackId);
      logger.i('Player', '切换字幕轨道: id=$trackId');
    } else {
      logger.w('Player',
          '切换字幕轨道: 未找到匹配轨道, targetIndex=$next, lang=${target.language}, title=$targetDisplayTitle');
    }
  }

  /// 内封字幕无法整轨下载时，启动流式翻译（边播边译，叠加层按双语排版显示）。
  void _startStreamingTranslate(TranslationEngine engine, MediaStream stream) {
    _streamTranslator?.stop();
    final translator = StreamingSubtitleTranslator(
      engine: engine,
      sourceLang:
          (stream.language?.isNotEmpty ?? false) ? stream.language! : 'auto',
      targetLang: ref.read(translationTargetLangProvider),
      layout: ref.read(bilingualLayoutProvider),
    );
    translator.errorMessage.addListener(() {
      final msg = translator.errorMessage.value;
      if (msg != null && mounted) {
        AppToast.show(context, '流式翻译引擎错误: $msg',
            kind: AppToastKind.error, position: AppToastPosition.topCenter);
      }
    });
    _streamTranslator = translator;
    translator.start(_playerService);
    if (mounted) {
      setState(() {});
      AppToast.show(context, '该字幕为内封、无法整轨下载，已改为流式翻译（边播边译）',
          position: AppToastPosition.topCenter);
    }
  }

  void _stopStreamingTranslate() {
    if (_streamTranslator == null) return;
    _streamTranslator?.stop();
    _streamTranslator = null;
    if (mounted) setState(() {});
  }

  Future<void> _onSubtitleTrackChanged(int? prev, int? next) async {
    // 用户切换/关闭字幕轨 → 结束流式翻译：清掉译文叠加层并恢复原文字幕，
    // 否则旧译文叠加层会与新选中字幕叠加，造成双字幕。
    if (_streamTranslator != null) {
      _stopStreamingTranslate();
    }
    if (next == -1) {
      await _playerService.deselectSubtitleTrack();
      return;
    }
    if (prev == next || next == null) {
      if (next == null && prev != null) {
        await _playerService.deselectSubtitleTrack();
      }
      return;
    }

    final item = ref.read(currentPlayingItemProvider);
    if (item == null) return;

    final api = ref.read(apiClientProvider);
    final logger = AppLogger();

    try {
      final playbackInfo = await api.playback.getPlaybackInfo(item.id);
      final mediaSource = _resolveMediaSource(playbackInfo);
      if (mediaSource == null) return;

      final subtitleStreams =
          mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();
      final target = subtitleStreams.where((s) => s.index == next).firstOrNull;
      if (target == null) return;

      final isExternal = target.isExternal ?? false;
      final codec = target.codec?.toLowerCase() ?? 'ass';
      final isGraphical = _isGraphicalSubtitleCodec(codec);

      if (!isExternal) {
        final isAss = _isAssSubtitleCodec(codec);
        final isExoAss = _playerService.coreType == PlayerCoreType.exoPlayer &&
            isAss &&
            !isGraphical;

        if (isExoAss) {
          try {
            logger.i('Player', 'EXO内核: 内封ASS切换直接走Media3轨道选择');
            await _selectInternalSubtitleViaTrack(target, next, logger);
          } catch (e, stackTrace) {
            logger.eWithStack('Player', 'EXO内封ASS切换失败，回退原生轨道选择', e, stackTrace);
            await _selectInternalSubtitleViaTrack(target, next, logger);
          }
        } else {
          await _selectInternalSubtitleViaTrack(target, next, logger);
        }
      } else {
        final embyCodec = _embySubtitleCodec(codec);
        final isGraphicalExternal = _isGraphicalSubtitleCodec(codec);

        if (_playerService.coreType == PlayerCoreType.mpv ||
            _playerService.coreType == PlayerCoreType.nativeMpv ||
            isGraphicalExternal) {
          final subUrl = api.playback.getSubtitleStreamUrl(
            item.id,
            mediaSource.id,
            target.index,
            embyCodec,
          );

          await _playerService.deselectSubtitleTrack();

          if (isGraphicalExternal) {
            final ext = _subtitleFileExtension(codec, _playerService.coreType);
            final subFile = await _prepareSubtitleFileForPlayer(
              subtitleUrl: subUrl,
              fileName: 'subtitle_${item.id}_${target.index}.$ext',
              codec: codec,
              coreType: _playerService.coreType,
              logger: logger,
            );
            if (subFile.existsSync() && await subFile.length() > 0) {
              await _playerService.loadLibassSubtitle(subFile.path);
            }
          } else {
            final ext = _subtitleFileExtension(codec, _playerService.coreType);
            final subFile = await _prepareSubtitleFileForPlayer(
              subtitleUrl: subUrl,
              fileName: 'subtitle_${item.id}_${target.index}.$ext',
              codec: codec,
              coreType: _playerService.coreType,
              logger: logger,
            );

            if (subFile.existsSync() && await subFile.length() > 0) {
              await _playerService.loadLibassSubtitle(subFile.path);
            }
          }
        } else {
          final subUrl = api.playback.getSubtitleStreamUrl(
            item.id,
            mediaSource.id,
            target.index,
            embyCodec,
          );
          if (_playerService.coreType == PlayerCoreType.exoPlayer) {
            final ext = _subtitleFileExtension(codec, _playerService.coreType);
            final subFile = await _prepareSubtitleFileForPlayer(
              subtitleUrl: subUrl,
              fileName: 'subtitle_${item.id}_${target.index}.$ext',
              codec: codec,
              coreType: _playerService.coreType,
              logger: logger,
            );

            if (subFile.existsSync() && await subFile.length() > 0) {
              await _playerService.loadLibassSubtitle(subFile.path);
            }
          } else {
            await _playerService.loadLibassSubtitle(subUrl);
          }
        }
      }
    } catch (e) {
      logger.e('Player', '切换字幕轨道失败: $e');
    }
  }

  Future<void> _onSecondarySubtitleTrackChanged(int? next) async {
    if (next == null) {
      await _playerService.deselectSecondarySubtitle();
      return;
    }

    final item = ref.read(currentPlayingItemProvider);
    if (item == null) return;

    final api = ref.read(apiClientProvider);
    final server = ref.read(currentServerProvider);
    final logger = AppLogger();

    if (_playerService.coreType != PlayerCoreType.mpv &&
        _playerService.coreType != PlayerCoreType.nativeMpv) {
      logger.w('Player', '次字幕仅支持MPV内核');
      if (mounted) {
        AppToast.show(context, '次字幕功能需要MPV内核，请在设置中切换',
            position: AppToastPosition.topCenter);
      }
      return;
    }

    try {
      final playbackInfo = await api.playback.getPlaybackInfo(item.id);
      final mediaSource = _resolveMediaSource(playbackInfo);
      if (mediaSource == null) return;

      final subtitleStreams =
          mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();
      final target = subtitleStreams.where((s) => s.index == next).firstOrNull;
      if (target == null) return;

      final isExternal = target.isExternal ?? false;
      final codec = target.codec?.toLowerCase() ?? 'ass';
      final isGraphical = codec == 'pgssub' ||
          codec == 'sup' ||
          codec == 'pgs' ||
          codec.contains('hdmv') ||
          codec.contains('pgs');

      if (isGraphical) {
        logger.w('Player', '次字幕: 图形字幕暂不支持作为次字幕');
        if (mounted) {
          AppToast.show(context, '图形字幕(PGS/SUP)暂不支持作为次字幕',
              position: AppToastPosition.topCenter);
        }
        return;
      }

      if (!isExternal) {
        logger.i('Player', '次字幕: 内封字幕，通过MPV轨道ID直接设置');
        final tracks = _playerService.tracksInfo;
        final subtitleTracks = tracks
            .where((t) =>
                (t['type'] == 'text' || t['type'] == 'bitmap') &&
                t['id'] != 'auto' &&
                t['id'] != 'no')
            .toList();
        final currentPrimaryIndex = ref.read(subtitleTrackProvider);
        String? primaryTrackId;
        if (currentPrimaryIndex != null) {
          final primaryTarget = subtitleStreams
              .where((s) => s.index == currentPrimaryIndex)
              .firstOrNull;
          if (primaryTarget != null) {
            primaryTrackId = _matchMpvSubtitleTrack(
              subtitleTracks,
              primaryTarget.language,
              primaryTarget.displayTitle ?? primaryTarget.title,
              primaryTarget.codec,
              primaryTarget.index,
            );
          }
        }

        final trackId = _matchMpvSecondarySubtitleTrack(
          subtitleTracks,
          target,
          primaryTrackId,
        );

        if (trackId != null && trackId.isNotEmpty) {
          await _playerService.selectSecondarySubtitleTrack(trackId);
          await _applySecondarySubtitleSettings();
          logger.i('Player', '内封次字幕已设置: trackId=$trackId');
        } else {
          logger.w('Player', '未找到匹配的MPV字幕轨道');
        }
        return;
      }

      final embyCodec = _embySubtitleCodec(codec);
      final subUrl = api.playback.getSubtitleStreamUrl(
        item.id,
        mediaSource.id,
        target.index,
        embyCodec,
      );

      final tempDir = await getTemporaryDirectory();
      final ext = _subtitleFileExtension(codec, _playerService.coreType);
      final subFile = File(
          '${tempDir.path}/secondary_subtitle_${item.id}_${target.index}.$ext');

      if (!subFile.existsSync() || await subFile.length() == 0) {
        final dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
        ));
        if (server?.authToken != null) {
          dio.options.headers['X-Emby-Token'] = server!.authToken;
          dio.options.headers['X-MediaBrowser-Token'] = server.authToken;
        }
        await dio.download(subUrl, subFile.path);
      }

      if (subFile.existsSync() && await subFile.length() > 0) {
        await _playerService.loadSecondarySubtitle(subFile.path);
        await _applySecondarySubtitleSettings();
        logger.i('Player', '次字幕加载成功: ${subFile.path}');
      }
    } catch (e) {
      logger.e('Player', '加载次字幕失败: $e');
    }
  }

  /// 次字幕启用后套用当前位置/延迟设置（让新视频沿用上次的次字幕位置，libmpv 0.41+）。
  Future<void> _applySecondarySubtitleSettings() async {
    await _playerService.setSecondarySubtitlePosition(
        ref.read(secondarySubtitlePositionProvider));
    await _playerService
        .setSecondarySubtitleDelay(ref.read(secondarySubtitleDelayProvider));
  }

  void _onPlayerUpdate() {
    setState(() {});
    // ExoPlayer 解码器初始化失败（DTS 等硬件不支持）时自动切 MPV 兜底
    // （内部自带一次性防重 + postFrame，安全）。
    _maybeAutoFallbackCore();
    _checkSkipOpening();
    _introSkip.onPosition(_playerService.position);
    // 弹幕调度：按播放位置喂当前秒弹幕；暂停/恢复同步弹幕动画。
    _feedDanmakuAt(_playerService.position);
    if (_lastPlayingState != _playerService.isPlaying) {
      _lastPlayingState = _playerService.isPlaying;
      if (_playerService.isPlaying) {
        _danmakuController?.resume();
      } else {
        _danmakuController?.pause();
      }
    }
    final sp = _activeSourcePlay;
    if (sp != null &&
        _playerService.isCompleted &&
        !_sourceCompletionReported) {
      _sourceCompletionReported = true;
      unawaited(_reportSourceProgress(sp, force: true));
    }
    // 播放完毕自动连播下一集：isCompleted 置位后触发一次（防重复），
    // 重新起播/seek 后自动复位（!isCompleted 分支）。
    if (_playerService.isCompleted) {
      if (!_autoNextHandled) {
        _autoNextHandled = true;
        unawaited(_autoPlayNextIfEnabled());
      }
    } else {
      _autoNextHandled = false;
    }
  }

  /// 自动连播：设置开启且有下一集时切换；电影/最后一集静默（不打扰）。
  Future<void> _autoPlayNextIfEnabled() async {
    if (!ref.read(autoPlayNextProvider)) return;
    final sourcePlay = _activeSourcePlay;
    if (sourcePlay != null && sourcePlay.playlist.isNotEmpty) {
      final index = sourcePlay.playlistIndex;
      if (index >= 0 && index < sourcePlay.playlist.length - 1) {
        await _switchSourceEpisode(sourcePlay.playlist[index + 1]);
      }
      return;
    }
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId == null) return; // 电影等单集：不自动切
    try {
      final episodes = await ref.read(apiClientProvider).media.getEpisodes(
            currentItem!.seriesId!,
            seasonId: currentItem.seasonId,
          );
      final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
      if (currentIndex >= 0 && currentIndex < episodes.length - 1) {
        final nextEpisode = episodes[currentIndex + 1];
        if (mounted) context.replace('/player/${nextEpisode.id}');
      }
    } catch (_) {
      // 拉取剧集列表失败：静默放弃自动连播（不打断观看）。
    }
  }

  /// 弹幕按滑动窗口喂入：交给 DanmakuLoader 处理（游标+二分+去重）。
  /// 位置跳变（seek/回退 >1.5s）时由 loader.onSeek 清空重喂；弹幕延迟
  /// （danmakuDelay）作用在喂入位置前，与旧实现语义一致。
  void _feedDanmakuAt(Duration rawPosition) {
    final loader = _danmakuLoader;
    if (loader == null) return;
    final position = rawPosition -
        Duration(
            milliseconds:
                (ref.read(danmakuDelayProvider) * 1000).round());
    if (position < Duration.zero) return;
    if (position - _lastFeedPosition > const Duration(milliseconds: 1500) ||
        position < _lastFeedPosition) {
      // seek / 回退：清空当前弹幕，重新从当前位置开始喂。
      loader.reset(position);
    }
    _lastFeedPosition = position;
    loader.onPositionChanged(position.inMilliseconds);
  }

  /// 弹幕设置 → canvas_danmaku DanmakuOption：
  /// 字号 12-36（0-1 因子）、速度 → 动画时长（0.5 默认 10s，越快 duration 越短）、
  /// 透明度/显示区域/描边/自定义字体直传。
  DanmakuOption _buildDanmakuOption({
    required double fontSize,
    required double opacity,
    required double area,
    required bool stroke,
    required double speed,
    String? fontFamily,
  }) {
    return DanmakuOption(
      fontSize: 12 + 24 * fontSize.clamp(0.0, 1.0),
      area: area.clamp(0.0, 1.0),
      opacity: opacity.clamp(0.0, 1.0),
      // 速度因子 0.5 默认 → 10s；越大越快（duration 越短）。
      duration: 10.0 / (0.5 + speed.clamp(0.0, 1.0)).clamp(0.4, 1.5),
      strokeWidth: stroke ? 1.5 : 0,
      lineHeight: 1.6,
      fontFamily: fontFamily,
      safeArea: false,
    );
  }

  /// 弹幕列表变化（加载/重过滤/切集）时：重建滑动窗口 loader 并重喂。
  void _indexDanmaku(List<DanmakuItem> items) {
    _lastIndexedDanmaku = items;
    final controller = _danmakuController;
    _danmakuLoader?.dispose();
    _danmakuLoader = null;
    if (controller == null || items.isEmpty) return;
    // 逐条过滤：悬浮/滚动 × 彩色/白色 四开关 + 密度过滤在喂入时实时读取
    //（切换后新弹幕自然生效，无感），语义与旧实现一致。
    _danmakuLoader = DanmakuLoader(
      items: items,
      controller: controller,
      initialPositionMs: _playerService.position.inMilliseconds,
      feedFilter: _danmakuFeedFilter,
    );
    // 不在此立即喂弹幕：_indexDanmaku 可能在 build 期间（_buildVideoArea 的
    // identical 分支）被调用，同步 addDanmaku 会触发 TextPainter 布局等昂贵
    // 操作导致渲染中断白屏。由 _onPlayerUpdate 的 _feedDanmakuAt（非 build
    // 路径，每 200ms）自然喂入当前窗口。
    _lastFeedPosition = _playerService.position;
  }

  /// 弹幕喂入过滤：彩色/白 × 悬浮/滚动四开关 + 密度保持。返回 false 表示丢弃。
  bool _danmakuFeedFilter(DanmakuItem item) {
    if (item.text.isEmpty) return false;
    // 顶部/底部/滚动 × 彩色/白色 开关：白色 = color == 16777215；
    // 同一类两个开关都关则该类弹幕不显示。
    final white = item.color == 16777215;
    if (item.type == 5) {
      // 顶部弹幕
      if (white
          ? !ref.read(danmakuFloatingWhiteProvider)
          : !ref.read(danmakuFloatingColorfulProvider)) {
        return false;
      }
    } else if (item.type == 4) {
      // 底部弹幕
      if (white
          ? !ref.read(danmakuBottomWhiteProvider)
          : !ref.read(danmakuBottomColorfulProvider)) {
        return false;
      }
    } else if (white
        ? !ref.read(danmakuScrollWhiteProvider)
        : !ref.read(danmakuScrollColorfulProvider)) {
      // 滚动弹幕
      return false;
    }
    // 密度过滤：保留比例 = 0.3 + density×0.7，按 time 散列均匀丢弃。
    final keepPercent =
        0.3 + ref.read(danmakuDensityProvider).clamp(0.0, 1.0) * 0.7;
    if (((item.time * 7919) % 1000) / 1000 > keepPercent) return false;
    return true;
  }

  /// ExoPlayer 解码器初始化失败（DTS 等手机 MediaCodec 不支持）时自动切
  /// MPV 内核重试一次。SDR 片源通常已由音轨兼容排序（track_preference）选中
  /// 可解码音轨而不会走到这里；走到这里说明整片没有可解音轨（如全 DTS 蓝光
  /// 原盘）或解码器初始化失败，切 MPV 软解兜底。HDR/DV 片源在详情页已默认
  /// MPV 内核，也不会走到这里。
  void _maybeAutoFallbackCore() {
    if (_autoCoreFallbackTried) return;
    final currentCore = normalizePlayerCore(
        _sourceCoreOverride ?? ref.read(playerCoreProvider));
    if (currentCore != 'exoPlayer') return;
    final message = _playerService.errorMessage ?? '';
    if (!_isDecoderInitFailure(message)) return;
    _autoCoreFallbackTried = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppToast.show(context, '当前内核无法解码该媒体，已自动切换到 MPV 内核重试',
          position: AppToastPosition.topCenter);
      _switchCore('nativeMpv');
    });
  }

  bool _isDecoderInitFailure(String message) {
    final lower = message.toLowerCase();
    return lower.contains('decoder_init_failed') ||
        lower.contains('decoder init failed') ||
        lower.contains('no decoder') ||
        (lower.contains('codec') && lower.contains('unsupported')) ||
        lower.contains('audio/vnd.dts') ||
        lower.contains('audio/vnd.dts.hd') ||
        lower.contains('audio/true-hd') ||
        lower.contains('audio/eac3');
  }

  /// 点按「跳过片头/片尾」：片尾且开启自动连播则切下一集，否则 seek 到段末。
  void _onIntroSkipPressed(SkipPrompt prompt) {
    if (prompt.kind == SkipKind.outro &&
        ref.read(autoPlayNextProvider) &&
        ref.read(currentPlayingItemProvider)?.seriesId != null) {
      _playNext();
    } else {
      _playerService.seekTo(prompt.target);
      _introSkip.onPosition(prompt.target); // 立即收起按钮
    }
  }

  bool _showSkipButton = false;
  Timer? _skipButtonTimer;

  /// 跳过片头片尾按影视存储：剧集用 seriesId（同剧各集共用），
  /// 源直链用服务器+条目，其余用条目 id。
  String get _skipTimesKey {
    final item = ref.read(currentPlayingItemProvider);
    if (item != null && item.seriesId != null && item.seriesId!.isNotEmpty) {
      return 'series:${item.seriesId}';
    }
    final sp = _activeSourcePlay;
    if (sp != null) return 'src:${sp.server.id}:${sp.entry.id}';
    return 'item:${widget.itemId}';
  }

  SkipTimes get _skipTimes =>
      ref.read(skipTimesProvider.notifier).forKey(_skipTimesKey);

  void _checkSkipOpening() {
    final t = _skipTimes;
    if (!t.hasOpening) return;
    final openingStart = t.openingStart;
    final openingEnd = t.openingEnd;
    final autoSkip = t.autoSkip;

    final pos = _playerService.position.inSeconds;
    final inOpening = pos >= openingStart && pos < openingEnd;

    if (inOpening && autoSkip) {
      _playerService.seekTo(Duration(seconds: openingEnd));
      AppToast.show(context, '已自动跳过片头', position: AppToastPosition.topCenter);
    } else if (inOpening && !_showSkipButton) {
      setState(() => _showSkipButton = true);
      _skipButtonTimer?.cancel();
      _skipButtonTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) {
          setState(() => _showSkipButton = false);
        }
      });
    } else if (!inOpening && _showSkipButton) {
      setState(() => _showSkipButton = false);
      _skipButtonTimer?.cancel();
    }
  }

  void _onSkipOpeningPressed() {
    final openingEnd = _skipTimes.openingEnd;
    _playerService.seekTo(Duration(seconds: openingEnd));
    setState(() => _showSkipButton = false);
    _skipButtonTimer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 离开播放界面（切任务栏/回桌面/切到其它 app）即恢复系统亮度与音量；
    // 回到前台再重新应用播放器内调节的值。退出播放器页面由 dispose 的
    // restoreSystemControls 负责（销毁会话并恢复）。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      final sp = _activeSourcePlay;
      if (sp != null) unawaited(_reportSourceProgress(sp, force: true));
      _playerService.pause();
      unawaited(_playerService.restoreForBackground());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_playerService.reapplyForForeground());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (isTvPlatform) {
      unregisterGlobalKeyHandler(_handleTvRemoteKey);
      _tvSeekAnchor = null;
      _tvSeekTimer?.cancel();
      _tvSeekTimer = null;
      _tvLongPressTimer?.cancel();
      _tvLongPressTimer = null;
      for (final node in _tvBottomNodes) {
        node.dispose();
      }
      for (final node in _tvTopNodes) {
        node.dispose();
      }
    }
    _tvEpisodeScrollController.dispose();
    // 离开播放器恢复系统息屏策略。
    WakelockPlus.disable();
    _accelSub?.cancel();
    _accelSub = null;
    _pendingTapToggle?.cancel();
    _danmakuLoader?.dispose();
    _danmakuLoader = null;
    _danmakuController = null;
    _statusTimer?.cancel();
    SystemInfoService.instance.stop();
    _streamTranslator?.stop();
    _streamTranslator = null;
    _introSkip.dispose();
    if (_activeState == this) _activeState = null;
    _activePlayerService = null;
    _playerService.removeListener(_onPlayerUpdate);
    _sourceProgressTimer?.cancel();
    final sp = _activeSourcePlay;
    if (sp != null) unawaited(_reportSourceProgress(sp, force: true));
    unawaited(PrefetchProxy.instance.stop());
    unawaited(_playerService.restoreSystemControls());
    _playerService.dispose();
    _longPressTimer?.cancel();
    _speedRampTimer?.cancel();
    _skipButtonTimer?.cancel();
    _sleepTimer?.cancel();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  /// TV 遥控播放控制（仅 TV 平台注册；对齐 Netflix/YouTube/腾讯 TV 播放页）：
  ///   - 左/右：快退/快进 step 秒（单击单次；长按 KeyRepeat 连续推进）
  ///   - 上键：单击=呼出控制栏；**长按=倍速播放**（手机端长按倍速的 TV 映射，
  ///     按住加速、松开恢复默认速度）
  ///   - 下键：呼出/收起控制栏（TV 不做音量/亮度调节——电视/投影有物理键）
  ///   - OK（enter/select）：播放/暂停
  ///   - MENU：呼出/收起控制栏（native+Flutter 双通道去抖）
  ///   - 返回：不拦截，系统 back 退出播放器（dispose 自动保存进度/恢复系统控制）
  KeyEventResult _handleTvRemoteKey(
    LogicalKeyboardKey key,
    KeyEventSource source,
    bool isRepeat,
    bool isUp,
  ) {
    final service = _playerService;
    if (!service.isInitialized) return KeyEventResult.ignored;

    // 选集栏打开：方向键/OK 全部交给选集导航（左/右=滚动聚焦、OK=选集、
    // 上/下/MENU=关闭），不落到播放控制。
    if (_tvEpisodeBarOpen) {
      switch (key) {
        case LogicalKeyboardKey.arrowLeft:
          if (!isUp && !isRepeat) _moveTvEpisode(-1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowRight:
          if (!isUp && !isRepeat) _moveTvEpisode(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
          if (!isUp && !isRepeat) _selectTvEpisode();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
        case LogicalKeyboardKey.arrowDown:
          if (!isUp && !isRepeat) _closeTvEpisodeBar();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.contextMenu:
          if (!isUp) _closeTvEpisodeBar();
          return KeyEventResult.handled;
        default:
          return KeyEventResult.handled;
      }
    }

    // 控制栏聚焦模式（UI 显示、无二级菜单时）：
    //   · 底部区：0=进度条（左右=调节）、1..3=传输、4..=操作按钮
    //   · 顶部区：0=返回、1..=顶部操作按钮
    //   · 上键：底部区 → 顶部区；下键：顶部区 → 底部区（双向切换）
    //   · 左右：区域内移动；OK：激活；底部按钮行下键：关闭 UI
    //   · 二级/三级菜单打开时方向键/OK 交还 Flutter 默认遍历（菜单项聚焦）
    if (service.showControls) {
      // 菜单打开：方向键/OK 交给 Flutter 默认遍历（菜单项可聚焦、上下移动、
      // OK 激活）；MENU/返回关闭菜单并恢复按钮焦点。
      if (_overlayMenuOpen) {
        switch (key) {
          case LogicalKeyboardKey.contextMenu:
            if (!isUp) {
              _overlayKey.currentState?.closeMenu();
              _restoreTvControlsFocus();
            }
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowLeft:
          case LogicalKeyboardKey.arrowRight:
          case LogicalKeyboardKey.arrowUp:
          case LogicalKeyboardKey.arrowDown:
          case LogicalKeyboardKey.enter:
          case LogicalKeyboardKey.select:
            return KeyEventResult.ignored; // Flutter 默认遍历操作菜单。
          default:
            return KeyEventResult.ignored;
        }
      }
      switch (key) {
        case LogicalKeyboardKey.arrowLeft:
        case LogicalKeyboardKey.arrowRight:
          if (isUp) {
            _tvSeekTimer?.cancel();
            _tvSeekTimer = null;
            _tvSeekAnchor = null;
            return KeyEventResult.handled;
          }
          service.pokeControls();
          if (_tvUiFocusRegion == 0 && _tvUiFocusItem == 0) {
            // 底部进度条聚焦：左右调节进度（复用连续快进）。
            _handleTvSeek(key == LogicalKeyboardKey.arrowRight, isRepeat);
          } else if (_tvUiFocusRegion >= 0 && !isRepeat) {
            _moveTvUiFocus(key == LogicalKeyboardKey.arrowRight ? 1 : -1);
          }
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
          if (!isUp && !isRepeat && _tvUiFocusRegion >= 0) {
            _activateTvUiFocus();
          }
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          // 底部区 → 顶部区（双向切换；顶部区按上停留）。
          if (isUp || isRepeat) return KeyEventResult.handled;
          if (_tvUiFocusRegion == 0) {
            setState(() {
              _tvUiFocusRegion = 1;
              _tvUiFocusItem = _tvUiFocusItem.clamp(0, _tvTopMaxIndex());
            });
            _requestTvControlsFocus();
          }
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          if (isUp || isRepeat) return KeyEventResult.handled;
          if (_tvUiFocusRegion == 1) {
            // 顶部区 → 底部区。
            setState(() {
              _tvUiFocusRegion = 0;
              _tvUiFocusItem = _tvUiFocusItem.clamp(0, _tvBottomMaxIndex());
            });
            _requestTvControlsFocus();
          } else if (_tvUiFocusItem == 0) {
            // 底部进度条 → 下一集按钮（再按下默认聚焦下一集）。
            setState(() => _tvUiFocusItem = 3);
            _requestTvControlsFocus();
          } else {
            // 底部按钮行 → 关闭 UI 回播放控制。
            _toggleTvControls();
          }
          service.pokeControls();
          return KeyEventResult.handled;
        default:
          break; // MENU 等落到主逻辑。
      }
    }

    switch (key) {
      case LogicalKeyboardKey.contextMenu:
        if (isUp) return KeyEventResult.handled;
        // native 通道与 Flutter 通道双触发去抖。
        final now = DateTime.now();
        if (_lastMenuKeyTime != null &&
            now.difference(_lastMenuKeyTime!) <
                const Duration(milliseconds: 350)) {
          return KeyEventResult.handled;
        }
        _lastMenuKeyTime = now;
        // MENU：打开/关闭底部选集胶囊栏（不再绑定控制栏显隐）。
        if (_tvEpisodeBarOpen) {
          _closeTvEpisodeBar();
        } else {
          _openTvEpisodeBar();
        }
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowRight:
        if (isUp) {
          // 松开：停止拖动、清理锚点（下次按下重新锚定）。
          _tvSeekTimer?.cancel();
          _tvSeekTimer = null;
          _tvSeekAnchor = null;
          return KeyEventResult.handled;
        }
        // UI 隐藏时：快进快退（交互重置 UI 自动隐藏计时）。
        service.pokeControls();
        _handleTvSeek(key == LogicalKeyboardKey.arrowRight, isRepeat);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowUp:
        if (isUp) {
          // 松开上键：取消单击 toggle 延迟；若正处于长按倍速 → 恢复默认速度。
          _tvLongPressTimer?.cancel();
          _tvLongPressTimer = null;
          if (_tvSpeedBoostActive) {
            _tvSpeedBoostActive = false;
            unawaited(service.setSpeed(ref.read(defaultPlaybackSpeedProvider)));
          }
          return KeyEventResult.handled;
        }
        if (isRepeat) {
          // 长按上键：进入倍速（与手机端长按倍速语义一致）。
          _tvLongPressTimer?.cancel();
          _tvLongPressTimer = null;
          if (!_tvSpeedBoostActive) {
            _tvSpeedBoostActive = true;
            unawaited(service.setSpeed(ref.read(longPressSpeedProvider)));
            // 长按倍速时隐藏 UI（避免遮挡画面）。
            if (service.showControls) service.hideControlsTemporarily();
          }
          return KeyEventResult.handled;
        }
        // 单击（按下后 400ms 内无 repeat 判定为单击）：呼出/收起控制栏。
        // 给长按判定留窗口，避免单击先 toggle 再被长按打断。
        _tvLongPressTimer?.cancel();
        _tvLongPressTimer = Timer(const Duration(milliseconds: 400), () {
          _tvLongPressTimer = null;
          if (mounted && !_tvSpeedBoostActive) _toggleTvControls();
        });
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowDown:
        // 下键：打开 UI（聚焦进度条）/ 收起控制栏。
        if (!isUp && !isRepeat) _toggleTvControls();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.select:
        if (!isUp && !isRepeat) {
          // 交互重置 UI 自动隐藏计时。
          service.pokeControls();
          unawaited(service.togglePlay());
        }
        return KeyEventResult.handled;

      default:
        return KeyEventResult.ignored;
    }
  }

  // ─── TV 选集栏（底部胶囊）───

  /// 快进/快退（进度条聚焦与 UI 隐藏共用）：
  ///   单击 = 跳 step 秒；长按（KeyRepeat）= 拖动效果——启动 120ms 周期
  ///   定时器，按「锚点 + 累计时间 × 20s/s」平滑推进（不依赖 repeat 节奏，
  ///   也不依赖轮询 position，确定性连续 seek 类似拖动进度条）。
  void _handleTvSeek(bool forward, bool isRepeat) {
    final service = _playerService;
    final step = ref.read(skipForwardStepProvider);
    if (!isRepeat) {
      // 单击：锚定当前位置，单次跳 step 秒。
      _tvSeekAnchor = service.position;
      _tvSeekForward = forward;
      unawaited(service.seekTo(
        _tvSeekAnchor! + Duration(seconds: step * (forward ? 1 : -1)),
      ));
      return;
    }
    // 长按：若拖动已启动则忽略本 repeat（定时器接管推进）。
    if (_tvSeekAnchor == null || _tvSeekTimer != null) return;
    // 拖动从「单击已跳转」的位置继续（锚点 + step），避免回跳。
    final dragAnchor =
        _tvSeekAnchor! + Duration(seconds: step * (forward ? 1 : -1));
    var tick = 0;
    _tvSeekTimer = Timer.periodic(const Duration(milliseconds: 120), (t) {
      if (_tvSeekAnchor == null) {
        t.cancel();
        _tvSeekTimer = null;
        return;
      }
      tick++;
      // 20s/s：每 tick（120ms）推进 2400ms，平滑连续。
      final deltaMs = tick * 120 * 20;
      unawaited(service.seekTo(
        dragAnchor +
            Duration(milliseconds: deltaMs * (forward ? 1 : -1)),
      ));
    });
  }

  /// 切换控制栏显隐并同步 TV 焦点：打开 → 聚焦底部进度条；关闭 → 无焦点。
  void _toggleTvControls() {
    final wasShown = _playerService.showControls;
    _playerService.toggleControls();
    setState(() {
      if (wasShown) {
        _tvUiFocusRegion = -1;
      } else {
        _tvUiFocusRegion = 0;
        _tvUiFocusItem = 0; // 进度条
      }
    });
    _requestTvControlsFocus();
  }

  /// 底部区/顶部区可聚焦项上限。
  int _tvBottomMaxIndex() => 3 + 5; // 进度条0 + 传输3 + 操作5（TV 端无选集按钮）
  int _tvTopMaxIndex() => 1 + 7 - 1; // 返回 + 顶部操作（最多 7 个）

  /// 区域内左右移动焦点。
  void _moveTvUiFocus(int delta) {
    final maxIndex = _tvUiFocusRegion == 1 ? _tvTopMaxIndex() : _tvBottomMaxIndex();
    setState(() {
      _tvUiFocusItem =
          (_tvUiFocusItem + delta).clamp(0, maxIndex).toInt();
    });
    _requestTvControlsFocus();
    _playerService.pokeControls();
  }

  /// 聚焦当前区域/项对应的按钮节点（postFrame，等按钮挂载/重建）。
  void _requestTvControlsFocus() {
    if (_tvUiFocusRegion < 0) return;
    final nodes =
        _tvUiFocusRegion == 1 ? _tvTopNodes : _tvBottomNodes;
    final item = _tvUiFocusItem.clamp(0, nodes.length - 1).toInt();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (item < nodes.length && nodes[item].context != null) {
        nodes[item].requestFocus();
      }
    });
  }

  /// 菜单关闭后恢复原按钮焦点。
  void _restoreTvControlsFocus() {
    _requestTvControlsFocus();
  }

  /// OK 激活聚焦项：顶部（返回/顶部操作）；底部（传输/操作按钮）。
  void _activateTvUiFocus() {
    final service = _playerService;
    final overlay = _overlayKey.currentState;
    if (_tvUiFocusRegion == 1) {
      // 顶部区：0=返回；1..=顶部操作（打开菜单/切换开关）。
      overlay?.activateTopFocus(_tvUiFocusItem);
    } else if (_tvUiFocusItem == 0) {
      // 进度条聚焦：OK 无操作（左右调节）。
    } else {
      // 底部区：1 上一集 / 2 播放暂停 / 3 下一集 / 4..=操作按钮。
      switch (_tvUiFocusItem) {
        case 1:
          _playPrevious();
          break;
        case 2:
          unawaited(service.togglePlay());
          break;
        case 3:
          _playNext();
          break;
        default:
          overlay?.activateBottomFocus(_tvUiFocusItem);
          break;
      }
    }
    service.pokeControls();
  }

  /// 打开选集栏：无选集（电影等）不打开；定位到当前集；暂停 UI 自动隐藏。
  void _openTvEpisodeBar() {
    final episodes =
        _overlayEpisodesFor(ref.read(currentPlayingItemProvider));
    if (episodes.isEmpty) return;
    final current = _currentEpisodeNumber(ref.read(currentPlayingItemProvider));
    final initIndex = episodes.indexWhere((e) => e.index == current);
    setState(() {
      _tvEpisodeBarOpen = true;
      _tvEpisodeIndex = initIndex >= 0 ? initIndex : 0;
    });
    _playerService.setControlsAutoHidePaused(true);
    if (_playerService.showControls) _playerService.hideControlsTemporarily();
  }

  /// 关闭选集栏：恢复 UI 自动隐藏计时。
  void _closeTvEpisodeBar() {
    if (!_tvEpisodeBarOpen) return;
    setState(() => _tvEpisodeBarOpen = false);
    _playerService.setControlsAutoHidePaused(false);
    _playerService.pokeControls();
  }

  /// 左右移动胶囊聚焦（clamp），并滚动到可见。
  void _moveTvEpisode(int delta) {
    final episodes =
        _overlayEpisodesFor(ref.read(currentPlayingItemProvider));
    if (episodes.isEmpty) return;
    final target =
        (_tvEpisodeIndex + delta).clamp(0, episodes.length - 1).toInt();
    if (target == _tvEpisodeIndex) return;
    setState(() => _tvEpisodeIndex = target);
    _ensureTvEpisodeVisible(target);
  }

  /// 横向滚动到目标胶囊（胶囊定宽 216 + 间隔 10）。
  void _ensureTvEpisodeVisible(int index) {
    if (!_tvEpisodeScrollController.hasClients) return;
    final target = (index * 226.0 - 40).clamp(
      0.0,
      _tvEpisodeScrollController.position.maxScrollExtent,
    );
    _tvEpisodeScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  /// OK：选集当前聚焦胶囊并关闭选集栏。
  void _selectTvEpisode() {
    final episodes =
        _overlayEpisodesFor(ref.read(currentPlayingItemProvider));
    if (_tvEpisodeIndex < 0 || _tvEpisodeIndex >= episodes.length) return;
    final ep = episodes[_tvEpisodeIndex];
    _closeTvEpisodeBar();
    unawaited(_switchEpisode(ep.index));
  }

  /// TV 底部选集胶囊栏（仅 TV 渲染）：横向滚动胶囊，聚焦高亮，OK 选集。
  /// 打开时从屏幕下方滑出（高度 = 屏幕 1/5），关闭时滑出屏幕外。
  Widget _buildTvEpisodeBar(List<PopupEpisodeOption> episodes) {
    final scheme = Theme.of(context).colorScheme;
    final current = _currentEpisodeNumber(ref.read(currentPlayingItemProvider));
    final barHeight = MediaQuery.sizeOf(context).height * 0.2;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedSlide(
        offset: _tvEpisodeBarOpen ? Offset.zero : const Offset(0, 1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: Container(
          height: barHeight,
          color: Colors.black.withValues(alpha: 0.82),
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: ListView.separated(
            controller: _tvEpisodeScrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: episodes.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, index) {
              final ep = episodes[index];
              final focused = index == _tvEpisodeIndex;
              final isCurrent = ep.index == current;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                // 长方形胶囊：定宽 + 圆角矩形（非圆形）。
                width: 216,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: focused
                      ? scheme.primary
                      : isCurrent
                          ? scheme.primary.withValues(alpha: 0.28)
                          : Colors.white12,
                  borderRadius: BorderRadius.circular(14),
                  border: focused
                      ? Border.all(color: Colors.white, width: 2)
                      : Border.all(color: Colors.transparent, width: 2),
                ),
                child: Row(
                  children: [
                    // 集封面缩略图（Thumb 横幅优先；无图不占位）。
                    if (ep.thumbUrl != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 64,
                          height: 36,
                          child: MediaImage(
                            imageUrl: ep.thumbUrl!,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '第 ${ep.index} 集',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: focused ? Colors.black : Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                          if (ep.name.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              ep.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: focused
                                    ? Colors.black.withValues(alpha: 0.75)
                                    : Colors.white70,
                                fontSize: 10.5,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 多线程加载预取代理：仅在「开关开 + 已确认服主允许 + 在线 http 源」时启动，
  /// 返回本地播放 URL（失败/不满足条件返回 null，调用方回退在线直链）。
  Future<String?> _maybeStartPrefetch(String onlineUrl) async {
    try {
      if (!onlineUrl.startsWith('http')) return null;
      // 仅对用户加入「多线程加载」白名单（已确认获服主允许）的当前服务器启用。
      final serverId = ref.read(currentServerProvider)?.id;
      if (serverId == null ||
          !ref.read(multiThreadLoadingServersProvider).contains(serverId)) {
        return null;
      }
      final limitMb = await CacheService.getVideoCacheMaxSizeMB();
      return await PrefetchProxy.instance.start(
        upstreamUrl: onlineUrl,
        threads: ref.read(multiThreadLoadingThreadsProvider),
        cacheLimitBytes: limitMb * 1024 * 1024,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(currentPlayingItemProvider);
    final server = ref.watch(currentServerProvider);
    final mediaInfo = item != null && !item.id.startsWith('src:')
        ? ref.watch(playbackInfoProvider(item.id)).valueOrNull
        : null;
    final mediaSource = _currentMediaSource(item, mediaInfo);
    final aggregateVersions = item != null &&
            !item.id.startsWith('src:')
        ? ref.watch(episodeAggregationProvider(item.id)).valueOrNull ??
            const <AggregatedVersion>[]
        : const <AggregatedVersion>[];
    _scheduleOverlayEpisodes(item);
    final overlayEpisodes = _overlayEpisodesFor(item);
    final lineName = _currentLineName(server);

    return PopScope(
      // TV 返回键语义：选集栏/二级菜单打开时 canPop=false（拦截，返回键
      // 关闭覆盖层）；其余情况 canPop=true 放行系统返回（正常退出播放器，
      // dispose 自动保存进度/恢复系统控制）。旧实现 TV 恒 canPop=false +
      // maybePop() 被 PopScope 拦截 → 返回键/顶部返回按钮全部失效。
      canPop: isTvPlatform
          ? !(_tvEpisodeBarOpen || _overlayMenuOpen)
          : true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // canPop=false 分支（TV 覆盖层打开）：返回键关闭覆盖层，不退出。
        if (isTvPlatform && _tvEpisodeBarOpen) {
          _closeTvEpisodeBar();
          return;
        }
        if (isTvPlatform && _overlayMenuOpen) {
          _overlayKey.currentState?.closeMenu();
          return;
        }
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 陀螺仪翻转改为切换系统方向（方案A）：Android 旋转整个 Activity，
          // 状态栏/控制栏/亮度音量滑块随系统重排，不再用 AnimatedRotation 假装翻转。
          return Stack(
              fit: StackFit.expand,
              children: [
                _buildPlayerBody(item, constraints),
              // 新播放器控制层：视频层之上叠加 PlayerOverlay（TopBar/BottomBar/
              // SideButtons/PopupMenuOverlay + 状态栏），替换原胶囊菜单控制层。
              Positioned.fill(
                child: PlayerOverlay(
                  key: _overlayKey,
                  // TV 控制栏焦点：底部区编码（-2=进度条、0..N=按钮）/
                  // 顶部区（0=返回、1..=操作）；-1=另一区或无焦点。
                  tvFocusIndex: _tvUiFocusRegion == 0
                      ? (_tvUiFocusItem == 0 ? -2 : _tvUiFocusItem - 1)
                      : -1,
                  tvTopFocusIndex: _tvUiFocusRegion == 1
                      ? _tvUiFocusItem
                      : -1,
                  tvFocusNodes: _tvBottomNodes,
                  tvTopFocusNodes: _tvTopNodes,
                  visible: _playerService.showControls,
                  isLocked: _playerService.isLocked,
                  isPlaying: _playerService.isPlaying,
                  position: _playerService.position,
                  duration: _playerService.duration,
                  bufferedProgress: _playerService.bufferedProgress,
                  isScrubbingPosition: _playerService.isScrubbingPosition,
                  dragPreviewProgress: _playerService.isScrubbingPosition
                      ? _playerService.displayProgress
                      : _playerService.isSeekSettling
                          ? _playerService.displayProgress
                          : null,
                  isSeekSettling: _playerService.isSeekSettling,
                  title: item?.name ?? '',
                  episode: _episodeLabel(item),
                  meta: _metaLabel(item, mediaSource),
                  serverName: server?.name ?? '',
                  serverLine: lineName,
                  serverIcon: server != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: server.iconUrl?.isNotEmpty == true
                                ? MediaImage(
                                    imageUrl: server.iconUrl,
                                    width: 22,
                                    height: 22,
                                    fit: BoxFit.contain,
                                    useDefaultUserAgent: true,
                                    errorWidget: const Icon(
                                        Icons.dns_outlined,
                                        size: 14,
                                        color: Colors.white70),
                                  )
                                // 未设置自定义图标：按服务器类型显示类型图标
                                // （飞牛→fnico / Emby→emby_default），与
                                // 服务器列表页同款，统一 22×22 缩放。
                                : server.sourceKind == SourceKind.feiniu
                                    ? Image.asset(
                                        'assets/images/fnico.png',
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, __, ___) =>
                                            const Icon(Icons.movie,
                                                size: 14,
                                                color: Colors.white70),
                                      )
                                    : Image.asset(
                                        EmbyDefaultIcon.asset,
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, __, ___) =>
                                            const Icon(Icons.dns_outlined,
                                                size: 14,
                                                color: Colors.white70),
                                      ),
                          ),
                        )
                      : null,
                  logoText: _logoText(item),
                  logoImage: _activeSourcePlay?.logoUrl?.isNotEmpty == true
                      ? NetworkImage(_activeSourcePlay!.logoUrl!)
                      : _logoImage(item),
                  mediaInfoTitle: item?.name ?? '',
                  encoder: _mediaEncoder(mediaSource),
                  resolution: _mediaResolution(mediaSource),
                  frameRate: _mediaFrameRate(mediaSource),
                  bitrate: _mediaBitrate(mediaSource),
                  mediaSize: _mediaSize(mediaSource),
                  initialDanmakuEnabled: ref.watch(danmakuEnabledProvider),
                  initialDanmakuDeduplication: ref.watch(danmakuDedupProvider),
                  initialDanmakuDedupWindow:
                      ref.watch(danmakuDedupWindowProvider),
                  initialDanmakuFloatingColorful:
                      ref.watch(danmakuFloatingColorfulProvider),
                  initialDanmakuFloatingWhite:
                      ref.watch(danmakuFloatingWhiteProvider),
                  initialDanmakuScrollColorful:
                      ref.watch(danmakuScrollColorfulProvider),
                  initialDanmakuScrollWhite:
                      ref.watch(danmakuScrollWhiteProvider),
                  initialDanmakuBottomColorful:
                      ref.watch(danmakuBottomColorfulProvider),
                  initialDanmakuBottomWhite:
                      ref.watch(danmakuBottomWhiteProvider),
                  initialDanmakuStroke: ref.watch(danmakuStrokeProvider),
                  initialAutoSkip: ref.watch(autoSkipSegmentsProvider),
                  initialDanmakuOpacity: ref.watch(danmakuOpacityProvider),
                  initialDanmakuFontSize: ref.watch(danmakuFontSizeProvider),
                  initialDanmakuSpeed: ref.watch(danmakuSpeedProvider),
                  initialDanmakuDensity: ref.watch(danmakuDensityProvider),
                  initialDanmakuArea: ref.watch(danmakuDisplayAreaProvider),
                  initialDanmakuDelay: ref.watch(danmakuDelayProvider),
                  initialSpeed: _playerService.speed,
                  initialEpisode: _currentEpisodeNumber(item),
                  episodeCount: overlayEpisodes.length,
                  initialSource: _aggregateSourceKey(item, mediaSource),
                  initialCore: _currentCore,
                  initialAnime4kEnabled: _anime4kMode != 'off',
                  initialHardwareDecoding: ref.watch(hardwareDecodingProvider),
                  initialAspectRatio: _aspectRatioValue(),
                  initialLine: lineName,
                  initialAudioTrack: _currentAudioTrackLabel(),
                  initialSubtitleTrack: _currentSubtitleTrackLabel(),
                  initialIntroTime: _formatSkipTime(
                      ref.watch(skipTimesProvider)[_skipTimesKey]?.openingEnd ?? 0),
                  initialOutroTime: _formatSkipTime(
                      ref.watch(skipTimesProvider)[_skipTimesKey]?.endingStart ?? 0),
                  sources: _overlayAggregateSources(
                    item,
                    mediaInfo,
                    mediaSource,
                    aggregateVersions,
                  ),
                  cores: _supportedPlayerCores(),
                  lines: _lineOptions(server),
                  episodes: overlayEpisodes,
                  onUiVisibilityChanged: (visible) {
                    if (visible != _playerService.showControls) {
                      _playerService.toggleControls();
                    }
                  },
                  onMenuVisibilityChanged: (menuOpen) {
                    _overlayMenuOpen = menuOpen;
                    _playerService.setControlsAutoHidePaused(menuOpen);
                    // 菜单关闭：恢复原按钮焦点（菜单打开时焦点交给菜单项）。
                    if (!menuOpen && isTvPlatform && mounted) {
                      _restoreTvControlsFocus();
                    }
                  },
                  onBack: () => Navigator.maybePop(context),
                  onPrevious: _playPrevious,
                  onNext: _playNext,
                  onPlayPause: () => _playerService.togglePlay(),
                  onSeek: (progress) {
                    // 拖动过程中只由 Slider 本地状态和 Overlay 预览更新；
                    // 不在每个 onChanged 帧向播放器发 seek。
                  },
                  onSeekChangeEnd: (progress) =>
                      _playerService.commitSeek(_durationFromProgress(progress)),
                  onPlaybackRateChanged: (speed) =>
                      _playerService.setSpeed(speed),
                  onAspectRatioChanged: _setAspectRatioValue,
                  onSourceChanged: (sourceId) =>
                      _switchOverlaySource(sourceId, item, aggregateVersions),
                  onAggregationSearch: _showAggregationSearch,
                  onCrossServerMatchSelected: (match) {
                    // 关闭聚合菜单后切服务器播放该资源（复用详情页同款播放链路）。
                    _playerService.setControlsAutoHidePaused(false);
                    _switchToCrossServerMatch(match);
                  },
                  onCoreChanged: _switchCore,
                  onLineChanged: _switchLine,
                  onAudioTrackChanged: _switchAudioTrackByName,
                  onSubtitleChanged: _switchSubtitleTrackByName,
                  onEpisodeChanged: _switchEpisode,
                  onDanmakuChanged: (value) =>
                      ref.read(danmakuEnabledProvider.notifier).state = value,
                  onDanmakuDeduplicationChanged: (value) {
                    ref.read(danmakuDedupProvider.notifier).state = value;
                    // 去重开关立即生效：用缓存重载已加载弹幕并重新过滤。
                    unawaited(_reapplyDanmakuFilter());
                  },
                  onDanmakuDedupWindowChanged: (value) {
                    ref.read(danmakuDedupWindowProvider.notifier).state =
                        value;
                    unawaited(_reapplyDanmakuFilter());
                  },
                  onDanmakuFloatingColorfulChanged: (value) =>
                      ref.read(danmakuFloatingColorfulProvider.notifier)
                          .state = value,
                  onDanmakuFloatingWhiteChanged: (value) =>
                      ref.read(danmakuFloatingWhiteProvider.notifier)
                          .state = value,
                  onDanmakuScrollColorfulChanged: (value) =>
                      ref.read(danmakuScrollColorfulProvider.notifier)
                          .state = value,
                  onDanmakuScrollWhiteChanged: (value) =>
                      ref.read(danmakuScrollWhiteProvider.notifier)
                          .state = value,
                  onDanmakuBottomColorfulChanged: (value) =>
                      ref.read(danmakuBottomColorfulProvider.notifier)
                          .state = value,
                  onDanmakuBottomWhiteChanged: (value) =>
                      ref.read(danmakuBottomWhiteProvider.notifier)
                          .state = value,
                  onDanmakuStrokeChanged: (value) =>
                      ref.read(danmakuStrokeProvider.notifier).state = value,
                  onDanmakuOpacityChanged: (value) =>
                      ref.read(danmakuOpacityProvider.notifier).state = value,
                  onDanmakuFontSizeChanged: (value) =>
                      ref.read(danmakuFontSizeProvider.notifier).state = value,
                  onDanmakuSpeedChanged: (value) =>
                      ref.read(danmakuSpeedProvider.notifier).state = value,
                  onDanmakuDensityChanged: (value) =>
                      ref.read(danmakuDensityProvider.notifier).state = value,
                  onDanmakuAreaChanged: (value) =>
                      ref.read(danmakuDisplayAreaProvider.notifier).state = value,
                  onDanmakuDelayChanged: (value) =>
                      ref.read(danmakuDelayProvider.notifier).state = value,
                  onLock: () => _playerService.toggleLock(),
                  onRotate: _toggleRotation,
                  onAnime4k: _showAnime4kPanel,
                  onHardwareDecoding: _toggleHardwareDecoding,
                  onAutoSkipChanged: _setAutoSkip,
                  onSearchDanmaku: _showDanmakuSearch,
                  onSkipTimeRecorded: _recordSkipTime,
                  onClearIntro: _clearOpeningSkip,
                  onClearOutro: _clearEndingSkip,
                  onExternalSubtitleRequested: _pickExternalSubtitle,
                ),
              ),
              // 网盘转码源（夸克等）清晰度切换：仅源直链播放且有多档时显示。
              if (_activeSourcePlay != null &&
                  _playerService.showControls &&
                  !_playerService.isLocked)
                Positioned(
                  right: 16,
                  bottom: 92,
                  child: SourceQualityButton(onSelect: _switchSourceQuality),
                ),
              // TV 选集栏：MENU 键打开，底部胶囊左右滚动聚焦，OK 选集。
              // 始终渲染（关闭时滑出屏幕外），保证滑入/滑出动画。
              if (isTvPlatform && overlayEpisodes.isNotEmpty)
                _buildTvEpisodeBar(overlayEpisodes),
              ],
            );
        },
      ),
    ),
    );
  }

  Widget _buildPlayerBody(MediaItem? item, BoxConstraints constraints) {
    // 轻点判定 Listener 放 GestureDetector **外层**（translucent）：全屏任何
    // 位置点击都先经过它（不被 child Stack 上层短路），同时透传给下层
    // GestureDetector 保证双击/长按/拖动照常。onTap 不注册——onTap 与
    // onDoubleTapDown 共存时单击需等双击超时(~300ms)，且微动>slop 会被
    // scale 抢走，表现为"点了没反应"；改用原始指针事件立即 toggle。
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onTapDown,
      onPointerUp: _onTapUp,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: _onDoubleTapDown,
        onLongPressStart: (_) => _onLongPressStart(),
        onLongPressEnd: (_) => _onLongPressEnd(),
        // 用 Scale 手势统一处理：单指→沿用亮度/音量/进度拖动；双指→缩放画面。
        // GestureDetector 不允许同时挂 pan(drag) 与 scale，故由 scale 分流。
        onScaleStart: (details) => _onScaleStart(details, constraints),
        onScaleUpdate: (details) =>
            _onScaleUpdate(details, constraints),
        onScaleEnd: _onScaleEnd,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_playerService.coreType == PlayerCoreType.exoPlayer)
              ClipRect(
                child: Transform.scale(
                  scale: _videoZoom,
                  child: _buildVideoArea(),
                ),
              )
            else
              _buildVideoArea(),
            // Exo 字幕固定在播放器层，不参与视频比例/填充/裁剪。
            if (_playerService.coreType == PlayerCoreType.exoPlayer)
              _buildExoSubtitleOverlay(),
            if (!Platform.isAndroid && _playerService.brightness < 1.0)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(
                    alpha: (1.0 - _playerService.brightness)
                        .clamp(0.0, 0.9),
                  ),
                ),
              ),
            ),
          // 流式翻译叠加层（按双语排版显示原文/译文，位于控制条之下）。
          if (_streamTranslator != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 64,
              child: IgnorePointer(
                child: ValueListenableBuilder<String>(
                  valueListenable: _streamTranslator!.displayText,
                  builder: (context, text, _) {
                    if (text.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Center(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          text,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(
                                  blurRadius: 4, color: Colors.black),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          if (_playerService.isBuffering)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          if (_playerService.hasError)
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.white, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      friendlyPlaybackError(
                          _playerService.errorMessage),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      kPlaybackErrorFeedbackHint,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 11.5,
                          height: 1.6),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    const SelectableText(
                      kFeedbackChannelUrl,
                      style: TextStyle(
                          color: Color(0xFF5B8DEF),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _initializePlayer,
                      child: const Text('重试'),
                    ),
                    // L3：断流自动恢复耗尽后，把现成的手动切线入口摆到用户面前。
                    // 仅多线路服务器显示；不自动切线（由用户决定换哪条）。
                    if ((ref
                                .watch(currentServerProvider)
                                ?.lines
                                .length ??
                            0) >
                        1) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _showLineSelector,
                        child: const Text(
                          '切换线路',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (_playerService.isAdjustingLevel)
            _buildGestureIndicator(),
          if (_isLongPressing) _buildLongPressIndicator(),
          if (_showSkipButton)
            Positioned(
              top: 100,
              right: 24,
              child: ElevatedButton.icon(
                onPressed: _onSkipOpeningPressed,
                icon: const Icon(Icons.skip_next, size: 18),
                label: const Text('跳过片头'),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      Colors.black.withValues(alpha: 0.7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                ),
              ),
            ),
        ],
      ),
    ),
  );
  }

  Widget _buildVideoArea() {
    final videoWidget = _playerService.buildVideo();
    final danmakuItems = ref.watch(loadedDanmakuProvider);
    final danmakuEnabled = ref.watch(danmakuEnabledProvider);
    final danmakuOpacity = ref.watch(danmakuOpacityProvider);
    final danmakuFontSize = ref.watch(danmakuFontSizeProvider);
    final danmakuDelay = ref.watch(danmakuDelayProvider);
    final danmakuDisplayArea = ref.watch(danmakuDisplayAreaProvider);
    final danmakuStroke = ref.watch(danmakuStrokeProvider);
    final danmakuFontFamily = ref.watch(customDanmakuFontPathProvider).isEmpty
        ? null
        : FontService.danmakuFontFamily;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Exo 和 MPV 都使用同一套“媒体原始比例 + 自适应留黑边”布局。
        // MPV Texture 不再单独铺满窗口，避免切换内核后出现比例不同。
        final contentRect = _computeContentRect(
          Size(constraints.maxWidth, constraints.maxHeight),
        );
        final isMpv = _playerService.coreType == PlayerCoreType.mpv ||
            _playerService.coreType == PlayerCoreType.nativeMpv;
        // 弹幕列表变化（加载/去重重过滤）→ 重建按秒索引（幂等引用比较）。
        if (!identical(_lastIndexedDanmaku, danmakuItems)) {
          _lastIndexedDanmaku = danmakuItems;
          _indexDanmaku(danmakuItems);
        }
        // 设置变化同步到引擎：canvas_danmaku 的 widget.option 只在 initState
        // 生效，动态修改必须走 controller.updateOption（幂等，引擎内部比较）。
        _danmakuController?.updateOption(_buildDanmakuOption(
          fontSize: danmakuFontSize,
          opacity: danmakuOpacity,
          area: danmakuDisplayArea,
          stroke: danmakuStroke,
          speed: _playerService.speed > 0
              ? ref.read(danmakuSpeedProvider)
              : ref.read(danmakuSpeedProvider),
          fontFamily: danmakuFontFamily,
        ));
        return Stack(
          fit: StackFit.expand,
          children: [
            if (isMpv)
              Positioned.fromRect(rect: contentRect, child: videoWidget)
            else
              Positioned.fromRect(rect: contentRect, child: videoWidget),
            if (danmakuEnabled && danmakuItems.isNotEmpty)
              Positioned.fill(
                // canvas_danmaku 渲染引擎：固定动画时长（宽弹幕更快，B 站
                // 语义）+ 逐条防重叠；弹幕按滑动窗口由 _feedDanmakuAt 喂入。
                // 引擎内部已用 RepaintBoundary.wrap 隔离弹幕层重绘，无需外层再包。
                child: DanmakuScreen<dynamic>(
                    createdController: (c) {
                      _danmakuController = c;
                      // 只绑定 controller 并确保 loader 关联到新 controller，
                      // 不在 initState 阶段立即喂弹幕：此时轨道/宽度尚未初始化，
                      // addDanmaku 会被丢弃。弹幕由 _onPlayerUpdate 的
                      // _feedDanmakuAt 每 200ms 自然喂入。
                      _danmakuLoader?.dispose();
                      _danmakuLoader = null;
                      _indexDanmaku(_lastIndexedDanmaku ?? const []);
                    },
                    option: _buildDanmakuOption(
                      fontSize: danmakuFontSize,
                      opacity: danmakuOpacity,
                      area: danmakuDisplayArea,
                      stroke: danmakuStroke,
                      speed: ref.read(danmakuSpeedProvider),
                      fontFamily: danmakuFontFamily,
                    ),
                  ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildExoSubtitleOverlay() {
    final adapter = _playerService.adapter;
    if (adapter is! ExoPlayerAdapter) return const SizedBox.shrink();
    final size = ref.watch(subtitleSizeProvider);
    final position = ref.watch(subtitlePositionProvider);
    final background = ref.watch(subtitleBackgroundProvider);
    final font = ref.watch(subtitleFontProvider);
    return ValueListenableBuilder<List<BitmapSubtitleCue>>(
      valueListenable: adapter.bitmapNotifier,
      builder: (context, cues, _) {
        if (cues.isNotEmpty) {
          return Positioned(
            left: 0,
            right: 0,
            bottom: 24 + position * 180,
            child: IgnorePointer(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: cues
                    .map((cue) => Image.memory(
                          cue.bytes,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                          gaplessPlayback: true,
                        ))
                    .toList(),
              ),
            ),
          );
        }
        return ValueListenableBuilder<String>(
          valueListenable: adapter.subtitleNotifier,
          builder: (context, text, _) {
            final clean = text.replaceAll(RegExp(r'\\{[^}]*\\}'), '').trim();
            if (clean.isEmpty) return const SizedBox.shrink();
            return Positioned(
              left: 20,
              right: 20,
              bottom: 24 + position * 180,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: background
                        ? BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(4),
                          )
                        : null,
                    child: Text(
                      clean,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16 + size * 10,
                        fontFamily: font == '默认' ? null : font,
                        height: 1.25,
                        shadows: const [
                          Shadow(offset: Offset(1, 1), blurRadius: 2, color: Colors.black),
                          Shadow(offset: Offset(-1, -1), blurRadius: 2, color: Colors.black),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }


  void _onScaleStart(ScaleStartDetails details, BoxConstraints constraints) {
    if (_playerService.isLocked) return;
    if (_gestureIsZoom) {
      _zoomStartScale = _videoZoom;
    } else {
      // 用最新的交互区设置驱动本次手势（左右半屏亮度/音量、横向是否调进度）。
      _playerService.configureGestures(
        leftVerticalAction: ref.read(leftVerticalGestureProvider),
        rightVerticalAction: ref.read(rightVerticalGestureProvider),
        horizontalSeekEnabled: ref.read(horizontalSeekGestureProvider),
      );
      _playerService.onDragStart(
        DragStartDetails(globalPosition: details.focalPoint),
        constraints,
      );
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details, BoxConstraints constraints) {
    if (_playerService.isLocked) return;
    if (_gestureIsZoom) {
      setState(() {
        _videoZoom = (_zoomStartScale * details.scale).clamp(1.0, 4.0);
      });
    } else if (details.pointerCount < 2) {
      // 单指拖动：复用既有亮度/音量/进度逻辑（合成 Drag 详情传给 service）。
      _playerService.onDragUpdate(
        DragUpdateDetails(
          globalPosition: details.focalPoint,
          delta: details.focalPointDelta,
        ),
        constraints,
      );
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (!_gestureIsZoom) {
      final adjustingLevel = _playerService.isAdjustingLevel;
      _playerService.onDragEnd(DragEndDetails());
      if (adjustingLevel && !_playerService.isLocked) {
        _playerService.hideControlsTemporarily();
      }
    }
    _gestureIsZoom = false;
  }

  /// 陀螺仪画面翻转：仅在**横屏**下生效。监听加速度计 X 轴，
  /// 手机左右旋转 180°（landscapeLeft ↔ landscapeRight，x 符号翻转）→ 切换系统方向。
  /// 由 Android 旋转整个 Activity（状态栏/控制栏/亮度音量滑块/文字全部随手持转正），
  /// 不再用 Transform 假装翻转。竖屏不自动翻转（用户可手动点击旋转按钮）。
  /// 带死区（>4 m/s²）防抖动；传感器不可用/无权限时静默（画面不变）。
  void _startAccelerometerFlipDetection() {
    // 上次陀螺仪翻转方向（方法级闭包状态，订阅生命周期内持续有效）。
    var lastGyroFlipped = false;
    try {
      _accelSub = accelerometerEventStream(
        samplingPeriod: SensorInterval.normalInterval,
      ).listen((event) {
        if (!mounted) return;
        // 仅横屏生效：重力在 X 轴为主（|x| > |y|）才判定为横屏。
        // 不用「基线+符号比较」：翻转瞬间 x 过零会被误判竖屏、基线重置，
        // 导致首次翻转不生效、二次才翻转的滞后。直接由 x 符号判定方向：
        // x > 0（手机右侧朝下）与 x < 0（左侧朝下）互为 180°。
        final ax = event.x.abs();
        final ay = event.y.abs();
        if (ax <= ay) return; // 竖屏（或翻转瞬间）：不干预画面方向
        // 死区：重力分量太小时传感器噪声大，保持当前方向不抖。
        if (ax < 4.0) return;
        final flipped = event.x < 0;
        // 翻转=切换系统方向（方案A）。用静态变量记住当前翻转态做去抖比较，
        // 无需 setState：系统方向变化会触发 Activity 旋转重排（状态栏/控制栏/
        // 亮度音量滑块/文字全部随手持转正）。
        if (flipped != lastGyroFlipped) {
          lastGyroFlipped = flipped;
          SystemChrome.setPreferredOrientations([
            flipped
                ? DeviceOrientation.landscapeRight
                : DeviceOrientation.landscapeLeft,
          ]);
        }
      }, onError: (_) {
        _accelSub?.cancel();
        _accelSub = null;
      });
    } catch (_) {
      // 传感器不可用：保持画面不变。
    }
  }

  void _onTapDown(PointerDownEvent event) {
    if (_playerService.isLocked) return;
    // 双击/连点的后续一击（300ms 窗口内）：取消延迟中的单击 toggle，
    // 并标记这一击为「双击第二击」——其抬起不再触发 toggle（UI 零变化）。
    if (_pendingTapToggle != null) {
      _pendingTapToggle!.cancel();
      _pendingTapToggle = null;
      _tapWasDoubleTap = true;
      _tapDownPosition = event.position;
      _tapDownTime = DateTime.now();
      return;
    }
    _tapDownPosition = event.position;
    _tapDownTime = DateTime.now();
  }

  /// 全屏轻点抬起：位移 <20px 且时长 <150ms（非拖动/长按）→ 延迟 300ms
  /// 执行 toggle。窗口内被第二击取消的（双击场景）本方法不再建定时器——
  /// 语义：窗口内检测到「非单击」（双击/连点）则 UI 完全不管；只有真正
  /// 的单击（300ms 无第二击）才切换控制栏显隐。
  void _onTapUp(PointerUpEvent event) {
    if (_playerService.isLocked || _isLongPressing) return;
    if (_tapWasDoubleTap) {
      // 双击第二击：第一击的 toggle 已被取消，这里也不再 toggle。
      _tapWasDoubleTap = false;
      return;
    }
    final now = DateTime.now();
    final dt = now.difference(_tapDownTime);
    final dist = (event.position - _tapDownPosition).distance;
    if (dt > const Duration(milliseconds: 150) || dist > 20) return;
    _pendingTapToggle?.cancel();
    _pendingTapToggle = Timer(const Duration(milliseconds: 300), () {
      _pendingTapToggle = null;
      if (mounted) _playerService.toggleControls();
    });
  }

  void _onDoubleTapDown(TapDownDetails details) {
    if (_playerService.isLocked) return;
    // 双击快进/快退关闭时，双击中部仍可播放/暂停，但两侧不再快进快退。
    if (!ref.read(doubleTapSeekGestureProvider)) {
      _playerService.togglePlay();
      return;
    }
    final screenWidth = MediaQuery.of(context).size.width;
    final tapX = details.globalPosition.dx;
    final step = ref.read(skipForwardStepProvider);
    // 四等分手势：左 1/4 快退，中间 1/2 播放/暂停，右 1/4 快进。
    if (tapX < screenWidth / 4) {
      _playerService.seekBy(Duration(seconds: -step));
    } else if (tapX > screenWidth * 3 / 4) {
      _playerService.seekBy(Duration(seconds: step));
    } else {
      _playerService.togglePlay();
    }
  }

  void _onLongPressStart() {
    if (_playerService.isLocked) return;
    setState(() => _isLongPressing = true);
    _longPressTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_isLongPressing) {
        _playerService.setSpeed(ref.read(longPressSpeedProvider));
      }
    });
  }

  void _onLongPressEnd() {
    setState(() => _isLongPressing = false);
    _longPressTimer?.cancel();
    _playerService.setSpeed(ref.read(defaultPlaybackSpeedProvider));
  }

  Widget _buildGestureIndicator() {
    String label;
    double value;

    IconData icon;
    if (_playerService.activeVerticalAction == 'brightness') {
      label = '亮度';
      icon = Icons.brightness_high;
      value = _playerService.brightness;
    } else {
      label = '音量';
      icon = Icons.volume_up;
      value = _playerService.volume;
    }

    return Align(
      alignment: const Alignment(0, -0.72),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 24),
          const SizedBox(width: 10),
          SizedBox(
            width: 120,
            child: LinearProgressIndicator(
              value: value,
              minHeight: 3,
              backgroundColor: Colors.white38,
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${(value * 100).round()}%',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildLongPressIndicator() => Align(
        alignment: const Alignment(0, -0.72),
        child: IgnorePointer(
          child: Text(
            _formatSpeed(ref.read(longPressSpeedProvider)),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              shadows: [Shadow(blurRadius: 4, color: Colors.black)],
            ),
          ),
        ),
      );

  Widget _buildControlsOverlay(MediaItem? item) {
    // 上下渐变蒙版：让顶/底栏文字在任意画面上都清晰，中间画面不被遮。
    return Stack(
      fit: StackFit.expand,
      children: [
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x99000000),
                  Color(0x00000000),
                  Color(0x00000000),
                  Color(0xB3000000),
                ],
                stops: [0.0, 0.22, 0.7, 1.0],
              ),
            ),
          ),
        ),
        // 布局：中央=快退/播放/快进；左侧竖排=锁定/截屏；右侧=倍速条；
        // 底栏左下=上一集/下一集，右下=弹幕/字幕/音轨/选集。全部随控制栏一并显隐。
        SafeArea(
          child: Column(
            children: [
              _buildTopBar(item),
              // v3：屏幕中央不显示播放按键。
              const Expanded(child: SizedBox.shrink()),
              _buildMediaInfoLine(item),
              _buildProgressBar(),
              _buildBottomControlsRow(item),
            ],
          ),
        ),
        // 左侧竖排：锁定 + 截屏。
        Positioned(
          left: 24,
          top: 0,
          bottom: 0,
          child: SafeArea(child: Center(child: _buildSideButtons())),
        ),
        // 右侧倍速条 + 底部旋转按钮。
        Positioned(
          right: 24,
          top: 0,
          bottom: 0,
          child: SafeArea(child: Center(child: _buildSpeedBar())),
        ),
        // 右下角（右 8% 内）：旋转按钮。
        Positioned(
          right: 24,
          bottom: 76,
          child: SafeArea(
            child: Material(
              color: Colors.black.withValues(alpha: 0.35),
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: IconButton(
                icon: const Icon(Icons.screen_rotation_rounded,
                    color: Colors.white),
                iconSize: 22,
                tooltip: '旋转',
                onPressed: _toggleRotation,
              ),
            ),
          ),
        ),
        // 自动跳过片头/片尾按钮：左下、底栏之上。
        Positioned(
          left: 16,
          bottom: 108,
          child: SafeArea(
            child: ValueListenableBuilder<SkipPrompt?>(
              valueListenable: _introSkip.prompt,
              builder: (context, prompt, _) {
                if (prompt == null) return const SizedBox.shrink();
                return _IntroSkipButton(
                  label: prompt.label,
                  onTap: () => _onIntroSkipPressed(prompt),
                );
              },
            ),
          ),
        ),
      ],
    ).animate().fadeIn(duration: AppMotion.fast);
  }

  /// 锁定/解锁按钮：未锁定与锁定态复用同一样式与位置（左侧居中），避免两颗按钮跑到不同角落。
  Widget _lockButton() {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        icon: Icon(_playerService.isLocked ? Icons.lock : Icons.lock_open,
            color: Colors.white),
        iconSize: 20,
        tooltip: _playerService.isLocked ? '解锁' : '锁定',
        onPressed: _playerService.toggleLock,
      ),
    );
  }

  /// 左侧竖排功能：锁定 + 截屏（随控制栏显隐）。
  Widget _buildSideButtons() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _lockButton(),
        const SizedBox(height: 12),
        Material(
          color: Colors.black.withValues(alpha: 0.35),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: IconButton(
            icon: const Icon(Icons.camera_alt_outlined, color: Colors.white),
            iconSize: 20,
            tooltip: '截图',
            onPressed: _takeScreenshot,
          ),
        ),
      ],
    );
  }

  static const double _kSpeedMin = 0.25;
  static const double _kSpeedMax = 10.0;
  static const double _kSpeedStep = 0.25;
  Timer? _speedRampTimer;

  /// 按 0.25 档对齐步进倍速（单点用），并夹在 [0.25, 4.0]。
  void _stepSpeed(double delta) {
    final next =
        ((_playerService.speed + delta) / _kSpeedStep).round() * _kSpeedStep;
    final clamped = next.clamp(_kSpeedMin, _kSpeedMax);
    if ((clamped - _playerService.speed).abs() < 0.001) return;
    _playerService.setSpeed(clamped);
    setState(() {});
  }

  /// 长按连续线性加/减速：每 120ms 步进一档，松手停在当前速度。
  void _startSpeedRamp(double delta) {
    _stepSpeed(delta);
    _speedRampTimer?.cancel();
    _speedRampTimer = Timer.periodic(
        const Duration(milliseconds: 120), (_) => _stepSpeed(delta));
  }

  void _stopSpeedRamp() {
    _speedRampTimer?.cancel();
    _speedRampTimer = null;
  }

  String _formatSpeed(double s) {
    final str = s.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    return '${str}x';
  }

  /// 右侧倍速条：上「＋」下「－」，中间显示当前倍速。单点 ±0.25，长按线性连续加/减速。
  /// 竖排居中显示，做得小巧，避开底部总时长进度条。
  Widget _buildSpeedBar() {
    Widget stepBtn(IconData icon, double delta) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _stepSpeed(delta),
        onLongPressStart: (_) => _startSpeedRamp(delta),
        onLongPressEnd: (_) => _stopSpeedRamp(),
        onLongPressCancel: _stopSpeedRamp,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          stepBtn(Icons.add, _kSpeedStep),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
            child: Text(
              _formatSpeed(_playerService.speed),
              style: const TextStyle(
                color: Color(0xFF5B8DEF),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          stepBtn(Icons.remove, -_kSpeedStep),
        ],
      ),
    );
  }

  Widget _buildTopBar(MediaItem? item) {
    final server = ref.watch(currentServerProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 状态栏：左上时间、右上电量+网速
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              children: [
                Text(
                  _timeNow(),
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w500),
                ),
                const Spacer(),
                // 电量 + 网速
                _buildStatusIcons(),
              ],
            ),
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                iconSize: 20,
                tooltip: '返回',
                onPressed: () => context.pop(),
              ),
              // 媒体 logo 图（poster 缩略图），替代文字标题
              if (item != null && _currentLogoUrl(item) != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: MediaImage(
                    imageUrl: _currentLogoUrl(item)!,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                  ),
                )
              else
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: const LinearGradient(
                      colors: [Color(0xFFE94560), Color(0xFFFF6B6B)],
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    item?.name?.isNotEmpty == true
                        ? item!.name!.characters.first
                        : '影',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800),
                  ),
                ),
              const SizedBox(width: 10),
              // 服务器图标 + 名称 + 线路名（唯一一处）
              if (server != null)
                Flexible(
                  child: Row(
                    children: [
                      if (server.iconUrl != null &&
                          server.iconUrl!.isNotEmpty)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: MediaImage(
                            imageUrl: server.iconUrl!,
                            width: 16,
                            height: 16,
                          ),
                        ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          server.name +
                              (server.lines.isNotEmpty
                                  ? ' · ${server.lines[server.activeLineIndex.clamp(0, server.lines.length - 1)].name}'
                                  : ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              const Spacer(),
              // 右上角操作按钮（从右到左）：媒体信息 / 画面比例 / 跳过片头片尾 / 倍速 / 弹幕设置 / 弹幕
              // 全部改为居中深色胶囊菜单（对应 HTML 播放器 UI 原型二级菜单）。
              _TopActionButton(
                icon: Icons.subtitles_rounded,
                tooltip: '弹幕',
                onTap: _showDanmakuCapsule,
              ),
              if (_isMpvCore)
                _TopActionButton(
                  icon: _anime4kMode == 'off'
                      ? Icons.auto_awesome_rounded
                      : Icons.auto_awesome,
                  tooltip: 'Anime4K 超分',
                  onTap: _showAnime4kPanel,
                ),
              _TopActionButton(
                icon: Icons.settings_overscan_rounded,
                tooltip: '软解/硬解',
                onTap: _toggleHardwareDecoding,
              ),
              _TopActionButton(
                icon: Icons.closed_caption_rounded,
                tooltip: '弹幕设置',
                onTap: _showDanmakuSetCapsule,
              ),
              _TopActionButton(
                icon: Icons.speed_rounded,
                tooltip: '倍速',
                onTap: _showSpeedCapsule,
              ),
              _TopActionButton(
                icon: Icons.fast_forward_rounded,
                tooltip: '跳过片头/片尾',
                onTap: _showSkipCapsule,
              ),
              _TopActionButton(
                icon: Icons.aspect_ratio_rounded,
                tooltip: '画面比例',
                onTap: _showAspectCapsule,
              ),
              _TopActionButton(
                icon: Icons.info_outline_rounded,
                tooltip: '媒体信息',
                onTap: _showInfoCapsule,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 当前内核是否为 mpv（Anime4K 超分仅 mpv 支持）。
  bool get _isMpvCore {
    final core = normalizePlayerCore(ref.read(playerCoreProvider));
    return core == 'mpv' || core == 'nativeMpv';
  }

  /// 当前时间字符串（HH:mm）。
  String _timeNow() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  /// 状态栏：电量 + 网速下行图标。
  Widget _buildStatusIcons() {
    final info = SystemInfoService.instance;
    final battery = info.battery;
    final speed = info.rxSpeed;
    final speedText = speed > 1000000
        ? '${(speed / 1000000).toStringAsFixed(1)}MB/s'
        : speed > 1000
            ? '${(speed / 1000).toStringAsFixed(0)}KB/s'
            : '${speed.toStringAsFixed(0)}B/s';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.wifi_rounded, size: 12, color: Colors.white60),
        const SizedBox(width: 3),
        Text(speedText,
            style: const TextStyle(
                color: Colors.white60,
                fontSize: 10,
                fontWeight: FontWeight.w500)),
        const SizedBox(width: 10),
        Icon(
          battery >= 80
              ? Icons.battery_full_rounded
              : battery >= 40
                  ? Icons.battery_std_rounded
                  : Icons.battery_alert_rounded,
          size: 14,
          color: battery < 20 ? Colors.orangeAccent : Colors.white60,
        ),
        const SizedBox(width: 3),
        Text('$battery%',
            style: const TextStyle(
                color: Colors.white60,
                fontSize: 10,
                fontWeight: FontWeight.w500)),
      ],
    );
  }
  String? _currentLogoUrl(MediaItem item) {
    final sourceLogo = _activeSourcePlay?.logoUrl;
    if (sourceLogo?.isNotEmpty == true) return sourceLogo;
    return _mediaLogoUrl(item);
  }

  String? _mediaLogoUrl(MediaItem item) {
    final api = ref.read(apiClientProvider);
    try {
      // 播放器左上角必须优先使用 Logo（艺术字），不能把海报当 Logo。
      // 剧集/单集可能只在父级或系列上有 Logo，MediaItem 已在解析层回填对应 ID/tag。
      final logoItemId = item.logoItemId;
      final logoTag = item.logoImageTag;
      if (logoItemId?.isNotEmpty == true && logoTag?.isNotEmpty == true) {
        return api.image.getLogoImageUrl(
          logoItemId!,
          tag: logoTag,
          maxWidth: 360,
        );
      }
      if (item.primaryImageTag != null) {
        return api.image.getPrimaryImageUrl(item.id,
            tag: item.primaryImageTag, maxWidth: 160);
      }
      if (item.parentPrimaryImageItemId?.isNotEmpty == true &&
          item.parentPrimaryImageTag?.isNotEmpty == true) {
        return api.image.getPrimaryImageUrl(item.parentPrimaryImageItemId!,
            tag: item.parentPrimaryImageTag, maxWidth: 160);
      }
      if (item.seriesId?.isNotEmpty == true &&
          item.seriesPrimaryImageTag?.isNotEmpty == true) {
        return api.image.getPrimaryImageUrl(item.seriesId!,
            tag: item.seriesPrimaryImageTag, maxWidth: 160);
      }
      if (item.backdropImageTag != null) {
        return api.image.getBackdropImageUrl(item.backdropItemId ?? item.id,
            tag: item.backdropImageTag, maxWidth: 160);
      }
    } catch (_) {}
    return null;
  }

  /// 中央主控件：快退 · 播放/暂停 · 快进。上一集/下一集移到底栏左下。
  Widget _buildCenterControls() {
    final isPlaying = _playerService.isPlaying;
    final step = ref.read(skipForwardStepProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CenterControlButton(
          icon: Icons.replay_10_rounded,
          size: 44,
          tooltip: '快退 ${step}s',
          onTap: () => _playerService.seekBy(Duration(seconds: -step)),
        ),
        const SizedBox(width: 44),
        _CenterControlButton(
          icon: isPlaying
              ? Icons.pause_circle_filled_rounded
              : Icons.play_circle_fill_rounded,
          size: 72,
          tooltip: '播放/暂停',
          onTap: _playerService.togglePlay,
        ),
        const SizedBox(width: 44),
        _CenterControlButton(
          icon: Icons.forward_10_rounded,
          size: 44,
          tooltip: '快进 ${step}s',
          onTap: () => _playerService.seekBy(Duration(seconds: step)),
        ),
      ],
    );
  }

  /// 切换硬解/软解：改 provider 后重建播放器并恢复进度。
  /// （原先内联在顶栏按钮里，重构后挪进「更多」菜单，逻辑保持一致。）
  Future<void> _toggleHardwareDecoding() async {
    final current = ref.read(hardwareDecodingProvider);
    ref.read(hardwareDecodingProvider.notifier).state = !current;
    final savedPosition = _playerService.position;
    await _playerService.dispose();
    _playerService = VideoPlayerService();
    _activePlayerService = _playerService;
    _playerService.addListener(_onPlayerUpdate);
    await _initializePlayer(startPositionOverride: savedPosition);
    if (mounted) {
      AppToast.show(context, !current ? '已切换硬件解码' : '已切换软件解码',
          position: AppToastPosition.topCenter);
    }
  }

  /// Anime4K 超分档位面板（仅 mpv 内核）：6 档 + 关闭。
  /// 纯去噪放大梯子（无 Restore/锐化，不拖影）：核显→壮机，越往后越清晰越吃显卡。
  void _showAnime4kPanel() {
    const gears = <(String, String)>[
      ('off', '关闭'),
      ('modeA', 'Mode A · Restore'),
      ('modeB', 'Mode B · Restore Soft'),
      ('modeC', 'Mode C · Denoise'),
      ('modeAA', 'Mode A+A'),
      ('modeBB', 'Mode B+B'),
      ('modeAC', 'Mode C+A'),
    ];
    _showRightPanel(
      title: 'Anime4K 超分',
      children: [
        for (final (mode, label) in gears)
          PanelOptionTile(
            label: label,
            leading: Icon(mode == 'off' ? Icons.block : Icons.auto_awesome),
            selected: _anime4kMode == mode,
            onTap: () async {
              Navigator.of(context).maybePop();
              await _playerService.applySuperResolutionLevel(mode);
              if (!mounted) return;
              setState(() => _anime4kMode = mode);
              // 同步全局设置，保持设置页开关一致。
              ref.read(anime4KLevelProvider.notifier).state = mode;
              final n = _playerService.activeGlslShaderCount;
              AppToast.show(
                  context,
                  mode == 'off'
                      ? '已关闭超分'
                      : n > 0
                          ? '已应用 Anime4K Mode $label（$n 个 shader）'
                          : '⚠️ Anime4K shader 未进入内核，超分未生效',
                  kind: mode != 'off' && n == 0
                      ? AppToastKind.error
                      : AppToastKind.info,
                  position: AppToastPosition.topCenter);
            },
          ),
      ],
    );
  }

  Widget _buildProgressBar() {
    final durationMs = _playerService.duration.inMilliseconds;
    final gestureProgress = _playerService.isScrubbingPosition && durationMs > 0
        ? (_playerService.dragPreviewPosition.inMilliseconds / durationMs)
            .clamp(0.0, 1.0)
        : null;
    final effectiveProgress = _isSliderDragging
        ? (_sliderDragValue ?? _playerService.progress).clamp(0.0, 1.0)
        : (gestureProgress ?? _playerService.progress).clamp(0.0, 1.0);
    final effectivePosition = Duration(
      milliseconds:
          (effectiveProgress * _playerService.duration.inMilliseconds).round(),
    );
    final currentTime = _formatDuration(effectivePosition);
    final remaining = _playerService.duration - effectivePosition;
    final remainingTime = _formatDuration(
      remaining.isNegative ? Duration.zero : remaining,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => setState(() => _showRemaining = !_showRemaining),
                child: Text(
                  _showRemaining ? '-$remainingTime' : currentTime,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xFF5B8DEF),
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                    // 已缓冲区间：介于「已播放」蓝与「未加载」淡灰之间的半透明白。
                    secondaryActiveTrackColor:
                        Colors.white.withValues(alpha: 0.5),
                    thumbColor: const Color(0xFF5B8DEF),
                    overlayColor:
                        const Color(0xFF5B8DEF).withValues(alpha: 0.2),
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    value: effectiveProgress,
                    secondaryTrackValue:
                        _playerService.bufferedProgress.clamp(0.0, 1.0),
                    onChanged: (value) {
                      setState(() {
                        _isSliderDragging = true;
                        _sliderDragValue = value;
                      });
                    },
                    onChangeEnd: (value) async {
                      final position = Duration(
                        milliseconds:
                            (value * _playerService.duration.inMilliseconds)
                                .round(),
                      );
                      setState(() {
                        _isSliderDragging = false;
                        _sliderDragValue = null;
                      });
                      await _playerService.seekTo(position);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _formatDuration(_playerService.duration),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 底栏：左下=上一集/下一集，右下=弹幕/字幕/音轨/选集。
  /// 倍速→右侧倍速条；旋转→顶栏；截屏/锁定→左侧竖排；其余进「更多」。
  Widget _buildMediaInfoLine(MediaItem? item) {
    final coreLabel = _currentCore == 'exoPlayer' ? 'EXO' : 'MPV';
    final format = '—';
    final bps = '—';
    final frame = '—';

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 媒体名称
          Text(
            item?.name ?? widget.itemId,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
            ),
          ),
          const SizedBox(height: 2),
          // 集数及集标题
          if (item?.type == 'Episode' && item?.seriesName != null)
            Text(
              '${item!.seriesName} · ${_episodeNumberLabel(item)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          const SizedBox(height: 2),
          // 内核 / 格式 / 码率 / 帧数
          Text(
            '$coreLabel $format $bps $frame',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white60, fontSize: 11),
          ),
        ],
      ),
    );
  }

  String _episodeNumberLabel(MediaItem item) {
    final season = item.parentIndexNumber;
    final ep = item.indexNumber;
    if (season == null || ep == null) return item.name;
    return '第${season}季 第$ep集';
  }

  Widget _buildBottomControlsRow(MediaItem? item) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 2, 24, 8),
      child: Row(
        children: [
          _BottomBarAction(
            icon: Icons.skip_previous_rounded,
            label: '上一集',
            onTap: _playPrevious,
          ),
          // v3：左下角居中为播放/暂停键
          GestureDetector(
            onTap: _playerService.togglePlay,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.45),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.85), width: 1.6),
              ),
              child: Icon(
                _playerService.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
          ),
          _BottomBarAction(
            icon: Icons.skip_next_rounded,
            label: '下一集',
            onTap: _playNext,
          ),
          const Spacer(),
          // 右下角（右→左）：聚合搜索 / 内核 / 线路 / 音频 / 字幕 / 选集
          // 全部改为居中深色胶囊菜单（对应 HTML 播放器 UI 原型二级菜单）。
          _BottomBarAction(
            icon: Icons.travel_explore_rounded,
            label: '聚合',
            onTap: _showAggregationCapsule,
          ),
          _BottomBarAction(
            icon: Icons.memory_rounded,
            label: '内核',
            onTap: _showCoreCapsule,
          ),
          _BottomBarAction(
            icon: Icons.route_rounded,
            label: '线路',
            onTap: _showLineCapsule,
          ),
          _BottomBarAction(
            icon: Icons.audiotrack_rounded,
            label: '音频',
            onTap: _showAudioCapsule,
          ),
          _BottomBarAction(
            icon: Icons.subtitles_outlined,
            label: '字幕',
            onTap: _showSubtitleCapsule,
          ),
          _BottomBarAction(
            icon: Icons.playlist_play_rounded,
            label: '选集',
            onTap: () => _showEpisodeCapsule(item),
          ),
        ],
      ),
    );
  }

  void _showAggregationSearch() {
    // 用当前媒体做一次聚合搜索：跨服务器匹配，胶囊横向排布，点击即切换资源。
    // 优先复用详情页实际使用的跨服检索关键词（TMDB 标题优先，已写入
    // crossServerQueryProvider）——否则用 currentItem.name 原始名会与详情页
    // query 不一致，出现「详情页能搜到、聚合搜索为空」。
    // 无详情页来源时回退 currentItem.name 并做标题主干规范化。
    final currentItem = ref.read(currentPlayingItemProvider);
    final fromDetail = ref.read(crossServerQueryProvider);
    final title = (fromDetail != null && fromDetail.isNotEmpty)
        ? fromDetail
        : normalizeSearchTitle(currentItem?.name ?? widget.itemId);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return FutureBuilder<List<ServerMatchInfo>>(
          future: ref.read(rankingCrossServerMatchProvider(title).future),
          builder: (context, snapshot) {
            final matches = snapshot.data ?? const <ServerMatchInfo>[];
            if (snapshot.hasError) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Text('聚合搜索失败，请稍后重试'),
              );
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (matches.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Text('未找到其他服务器的同媒体资源'),
              );
            }
            return SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: matches.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final match = matches[index];
                  final server = ref
                          .read(serverListProvider)
                          .where((s) => s.id == match.sourceServerId)
                          .firstOrNull ??
                      (match.item.sourceServerId != null
                          ? ref
                              .read(serverListProvider)
                              .where(
                                  (s) => s.id == match.item.sourceServerId)
                              .firstOrNull
                          : null);
                  return ActionChip(
                    avatar: const Icon(Icons.cloud_done_rounded, size: 17),
                    label: Text(server?.name ?? '未知服务器'),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _switchToCrossServerMatch(match);
                    },
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  bool _playerNavInFlight = false;

  void _switchToCrossServerMatch(ServerMatchInfo match) {
    if (_playerNavInFlight) return;
    // 切换聚合资源：播放进度与内核保持不变，仅换源起播。
    // 与详情页一致：优先 match.sourceServerId（飞牛打标），
    // 缺失时回退 match.item.sourceServerId（Emby 由公共链路在 item 上打标）。
    final server = ref
            .read(serverListProvider)
            .where((s) => s.id == match.sourceServerId)
            .firstOrNull ??
        (match.item.sourceServerId != null
            ? ref
                .read(serverListProvider)
                .where((s) => s.id == match.item.sourceServerId)
                .firstOrNull
            : null);
    if (server == null) return;
    // 切换前把当前进度写入本地历史（force）：Emby 新播放器/详情页 autoPlay
    // 均从历史记录续播，保证"切换后同进度"（本地续播优先于服务端续播点）。
    final savedPosition = _playerService.position;
    final sourcePlay = _activeSourcePlay;
    if (sourcePlay != null) {
      unawaited(_reportSourceProgress(sourcePlay, force: true));
    } else {
      final item = ref.read(currentPlayingItemProvider);
      if (item != null) {
        unawaited(_writeWatchHistoryForItem(
          item: item,
          positionTicks: savedPosition.inMilliseconds * 10000,
          force: true,
        ));
      }
    }
    // 顶层剧集（Emby Series / 飞牛 tv|series）没有可直接播放的媒体流：
    // 直接 source-player/player 必然失败（飞牛 resolvePlay 拿不到 media_guid
    // 抛「未获取到播放媒体」；Emby Series 无媒体源）。与详情页一致，进该
    // 服务器详情页选集播放，并 toast 说明去向；播放器保留在栈中，从详情页
    // 返回可继续播放。
    final feiniuType = match.sourceEntry
        ?.raw?['type']
        ?.toString()
        .trim()
        .toLowerCase();
    final isTopLevelTv = match.sourceEntry != null
        ? (feiniuType == 'tv' || feiniuType == 'series')
        : match.item.type == 'Series';
    if (isTopLevelTv) {
      // 点击聚合剧集资源 = 直接播放：进该服务器详情页并自动开播当前集
      // （与 BCD 详情页点击播放一致）。
      _playerNavInFlight = true;
      context.push(
        '/detail/${Uri.encodeComponent(match.item.id)}',
        extra: UnifiedMediaDetailRouteExtra(
          server: server,
          entry: UnifiedMediaEntry(
            id: match.item.id,
            name: match.item.name,
            type: match.item.type,
          ),
          autoPlay: true,
          targetEpisodeNumber:
              ref.read(currentPlayingItemProvider)?.indexNumber,
        ),
      );
      _playerNavInFlight = false;
      return;
    }
    _playerNavInFlight = true;
    if (match.sourceEntry != null) {
      // 飞牛/直链源：完整重建播放器（保证服务/纹理/轨道都正确初始化），
      // 携带当前进度续播（sp.startPosition 优先于服务端续播点）。
      context.pushReplacement('/source-player',
          extra: SourcePlayback(
            server: server,
            entry: match.sourceEntry!,
            httpHeaders: match.sourceEntry!.thumbHeaders,
            playerCoreOverride: _currentCore,
            startPosition: savedPosition,
          ));
      return;
    }
    if (match.item.type == 'Movie' || match.item.type == 'Episode') {
      final origin = match.item.sourceServerId;
      if (origin != null) {
        ref.read(currentServerProvider.notifier).syncWithAvailableServers(
            ref.read(serverListProvider),
            preferredServerId: origin);
      } else {
        ref.read(currentServerProvider.notifier).state = server;
      }
      // 携带当前进度（start=秒）续播。
      context.pushReplacement(
          '/player/${match.item.id}?core=${Uri.encodeQueryComponent(_currentCore)}&start=${savedPosition.inSeconds}');
      return;
    }
    // 其它兜底类型：进该服务器媒体详情页（详情页内选集播放）。
    openMediaItem(ref, context, match.item);
    _playerNavInFlight = false;
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// 写本地观看记录（续播 / 跨服务器续播的数据来源），并在看完/停止时回传到其它服务器。
  Future<void> _writeWatchHistoryForItem({
    required MediaItem item,
    required int positionTicks,
    bool incrementPlayCount = false,
    bool force = false,
  }) async {
    // 播放器进度/停止回调可能在播放页销毁后仍触发，此时严禁再用 ref。
    if (!mounted) return;
    final current = ref.read(currentServerProvider);
    // 隐藏服务器不记播放记录（历史/续播/状态栏不出现），但卡片「最近观影」
    // 时间戳独立更新——隐藏删除历史后卡片仍与其他服务器一致显示。
    if (current?.hidden == true) {
      if (current != null) {
        ref
            .read(serverListProvider.notifier)
            .updateLastWatchedAt(current.id, DateTime.now());
      }
      return;
    }
    final scopeKey = buildWatchHistoryScopeKey(current);
    if (scopeKey == null) {
      return;
    }
    try {
      final record = await ref.read(watchHistoryProvider).capturePlayback(
            scopeKey: scopeKey,
            api: ref.read(apiClientProvider),
            item: item,
            positionTicks: positionTicks,
            source: WatchHistoryWriteSource.internalPlayer,
            watchedThresholdPercent: ref.read(watchedThresholdProvider),
            playerCore: _currentCore,
            incrementPlayCount: incrementPlayCount,
            force: force,
          );
      _maybeWriteBackCrossServer(
        scopeKey: scopeKey,
        item: item,
        record: record,
        force: force,
      );
      // 播放成功写历史 → 更新服务器配置上的「最近观影」时间戳
      // （独立于历史存储，隐藏服务器删除历史后卡片仍显示）。
      if (current != null) {
        ref
            .read(serverListProvider.notifier)
            .updateLastWatchedAt(current.id, DateTime.now());
      }
    } catch (_) {
      // 本地观看记录失败不应中断播放。
    }
  }

  /// 看完 / 停止时，把进度与「已看完」回传到其它服务器（受设置开关控制）。
  void _maybeWriteBackCrossServer({
    required String scopeKey,
    required MediaItem item,
    required WatchHistoryRecord? record,
    required bool force,
  }) {
    if (record == null || !mounted) return;
    if (!ref.read(crossServerWritebackEnabledProvider)) return;
    // 仅在「看完」或显式停止时回传，避免每个进度回调都打其它服务器。
    if (!record.played && !force) return;
    unawaited(
      ref.read(watchHistoryWritebackServiceProvider).propagate(
            currentScopeKey: scopeKey,
            currentApi: ref.read(apiClientProvider),
            item: item,
            positionTicks: record.lastPositionTicks,
            played: record.played,
            servers: ref.read(serverListProvider),
            range: ref.read(crossServerWritebackRangeProvider),
            includeProgress: ref.read(crossServerWritebackProgressProvider),
          ),
    );
  }

  /// 播放停止时上报同步服务：Trakt 总是发 scrobble/stop（由其按进度自动判定看过/
  /// 续播点）；Bangumi 仅在进度达到统一观看阈值时标记「在看 + 单集看过」。
  /// onStop 可能因显式停止 + dispose 触发两次，用 [_didScrobble] 去重。
  Future<void> _scrobbleOnStop(
    PlaybackStopInfo info,
    MediaItem item,
    ApiClientFactory api,
    int thresholdPercent,
    SyncController syncController,
  ) async {
    if (_didScrobble) return;
    _didScrobble = true;
    final runtime = item.runTimeTicks;
    if (runtime == null || runtime <= 0) return;
    final progress =
        (info.positionTicks / runtime * 100).clamp(0, 100).toDouble();
    // 「观看阈值」（wjplayer_watched_threshold，75~95，默认90）已在
    // _initializePlayer 里 widget 仍 mounted 时捕获，避免 dispose 后用 ref。
    final reachedThreshold = progress >= thresholdPercent;

    // 剧集需要所属剧的 ProviderIds 才能给 Bangumi 取 subject_id——仅在达到阈值
    // （会写 Bangumi）时才做这次查询，未达阈值只发 Trakt stop 无需它。
    Map<String, String>? seriesProviderIds;
    if (reachedThreshold && item.type == 'Episode' && item.seriesId != null) {
      try {
        final series = await api.media.getItemDetails(item.seriesId!);
        seriesProviderIds = series.providerIds;
      } catch (_) {}
    }

    try {
      await syncController.scrobbleStop(item,
          progress: progress,
          reachedThreshold: reachedThreshold,
          seriesProviderIds: seriesProviderIds);
    } catch (_) {}
  }

  Future<void> _switchSourceEpisode(SourceEntry entry) async {
    final current = _activeSourcePlay;
    if (current == null || current.entry.id == entry.id) return;
    await _reportSourceProgress(current, force: true);
    _activeSourcePlay = current.withEntry(entry);
    ref.read(sourceSelectedQualityProvider.notifier).state = null;
    await _playerService.dispose();
    _playerService = VideoPlayerService();
    _activePlayerService = _playerService;
    _playerService.addListener(_onPlayerUpdate);
    await _initializeSourcePlayer(_activeSourcePlay!);
    if (mounted) setState(() {});
  }

  Future<void> _playPrevious() async {
    final sourcePlay = _activeSourcePlay;
    if (sourcePlay != null && sourcePlay.playlist.isNotEmpty) {
      final index = sourcePlay.playlistIndex;
      if (index > 0) {
        await _switchSourceEpisode(sourcePlay.playlist[index - 1]);
      } else if (mounted) {
        AppToast.show(context, '已经是第一集了', position: AppToastPosition.topCenter);
      }
      return;
    }
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId != null) {
      try {
        final episodes = await ref.read(apiClientProvider).media.getEpisodes(
              currentItem!.seriesId!,
              seasonId: currentItem.seasonId,
            );
        final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
        if (currentIndex > 0) {
          final prevEpisode = episodes[currentIndex - 1];
          if (mounted) {
            context.replace('/player/${prevEpisode.id}');
          }
        } else {
          if (mounted) {
            AppToast.show(context, '已经是第一集了',
                position: AppToastPosition.topCenter);
          }
        }
      } catch (e) {
        if (mounted) {
          AppToast.show(context, '加载失败: $e',
              kind: AppToastKind.error, position: AppToastPosition.topCenter);
        }
      }
    }
  }

  Future<void> _playNext() async {
    final sourcePlay = _activeSourcePlay;
    if (sourcePlay != null && sourcePlay.playlist.isNotEmpty) {
      final index = sourcePlay.playlistIndex;
      if (index >= 0 && index < sourcePlay.playlist.length - 1) {
        await _switchSourceEpisode(sourcePlay.playlist[index + 1]);
      } else if (mounted) {
        AppToast.show(context, '已经是最后一集了',
            position: AppToastPosition.topCenter);
      }
      return;
    }
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId != null) {
      try {
        final episodes = await ref.read(apiClientProvider).media.getEpisodes(
              currentItem!.seriesId!,
              seasonId: currentItem.seasonId,
            );
        final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
        if (currentIndex >= 0 && currentIndex < episodes.length - 1) {
          final nextEpisode = episodes[currentIndex + 1];
          if (mounted) {
            context.replace('/player/${nextEpisode.id}');
          }
        } else {
          if (mounted) {
            AppToast.show(context, '已经是最后一集了',
                position: AppToastPosition.topCenter);
          }
        }
      } catch (e) {
        if (mounted) {
          AppToast.show(context, '加载失败: $e',
              kind: AppToastKind.error, position: AppToastPosition.topCenter);
        }
      }
    }
  }

  void _showMoreMenu() {
    void go(VoidCallback action) {
      Navigator.pop(context);
      action();
    }

    final hwOn = ref.read(hardwareDecodingProvider);

    _showRightPanel(
      title: '更多选项',
      children: [
        const PanelSectionTitle('播放'),
        PanelOptionTile(
          label: '跳过片头/片尾',
          leading: const Icon(Icons.fast_forward_rounded),
          selected: false,
          onTap: () => go(_showSkipDialog),
        ),
        PanelOptionTile(
          label: '画面比例',
          leading: const Icon(Icons.aspect_ratio),
          selected: false,
          onTap: () => go(_showAspectRatioDialog),
        ),
        const PanelSectionTitle('画质 / 解码'),
        PanelOptionTile(
          label: hwOn ? '硬件解码（点击切软解）' : '软件解码（点击切硬解）',
          leading: Icon(hwOn ? Icons.memory : Icons.slow_motion_video),
          selected: false,
          onTap: () => go(_toggleHardwareDecoding),
        ),
        const PanelSectionTitle('弹幕 / 其它'),
        PanelOptionTile(
          label: '搜索弹幕',
          leading: const Icon(Icons.search_rounded),
          selected: false,
          onTap: () => go(_showDanmakuSearch),
        ),
        PanelOptionTile(
          label: '线路切换',
          leading: const Icon(Icons.route),
          selected: false,
          onTap: () => go(_showLineSelector),
        ),
        PanelOptionTile(
          label: '定时关闭',
          leading: const Icon(Icons.timer),
          selected: false,
          onTap: () => go(_showTimerDialog),
        ),
        if (!isDesktopPlatform)
          PanelOptionTile(
            label: '内核切换',
            leading: const Icon(Icons.memory),
            selected: false,
            onTap: () => go(_showCoreSwitchDialog),
          ),
        PanelOptionTile(
          label: '统计信息',
          leading: const Icon(Icons.analytics),
          selected: false,
          onTap: () => go(_showStats),
        ),
      ],
    );
  }

  void _showRightPanel(
      {required String title,
      required List<Widget> children,
      double? width,
      double? maxWidthFraction}) {
    // 统一走共享的右侧设置面板（透明遮罩 + 局部毛玻璃 + 宽度≤1/3 + 深浅自适应）。
    showPlayerSettingsPanel(
      context: context,
      title: title,
      width: width,
      maxWidthFraction: maxWidthFraction,
      children: children,
    );
  }

  // =====================================================================
  // 胶囊菜单（对应挂载目录 HTML 播放器 UI 原型的二级/三级菜单）。
  // 全部使用统一的居中深色半透明胶囊弹层，可嵌套二级/三级。
  // =====================================================================

  void _showDanmakuCapsule() {
    _showCapsuleMenu(
      title: '弹幕',
      items: [
        capsuleSwitch(
          label: '开启弹幕',
          value: ref.read(danmakuEnabledProvider),
          onChanged: (v) =>
              ref.read(danmakuEnabledProvider.notifier).state = v,
        ),
        capsuleOption(
          label: '来源',
          subLabel: '自动',
          onTap: () {
            AppToast.show(context, '弹幕来源暂仅支持自动',
                position: AppToastPosition.topCenter);
          },
        ),
        capsuleSlider(
          label: '不透明度',
          value: ref.read(danmakuOpacityProvider),
          valueLabel:
              '${(ref.read(danmakuOpacityProvider) * 100).round()}%',
          onChanged: (v) => ref.read(danmakuOpacityProvider.notifier).state = v,
        ),
        capsuleSlider(
          label: '字号',
          value: ref.read(danmakuFontSizeProvider),
          valueLabel: ref.read(danmakuFontSizeProvider).toStringAsFixed(2),
          onChanged: (v) =>
              ref.read(danmakuFontSizeProvider.notifier).state = v,
        ),
        capsuleSwitch(
          label: '滚动弹幕',
          value: true,
          onChanged: (v) => AppToast.show(context, '滚动弹幕 $v',
              position: AppToastPosition.topCenter),
        ),
        capsuleSwitch(
          label: '顶部弹幕',
          value: true,
          onChanged: (v) => AppToast.show(context, '顶部弹幕 $v',
              position: AppToastPosition.topCenter),
        ),
        capsuleSwitch(
          label: '底部弹幕',
          value: true,
          onChanged: (v) => AppToast.show(context, '底部弹幕 $v',
              position: AppToastPosition.topCenter),
        ),
      ],
    );
  }

  void _showDanmakuSetCapsule() {
    _showCapsuleMenu(
      title: '弹幕设置',
      items: [
        capsuleOption(
          label: '弹幕颜色过滤',
          trailingLabel: '设置',
          next: CapsuleMenuLevel('弹幕颜色过滤', [
            capsuleSwitch(
              label: '过滤彩色弹幕',
              value: ref.read(danmakuDedupProvider),
              onChanged: (v) =>
                  ref.read(danmakuDedupProvider.notifier).state = v,
            ),
            capsuleSwitch(
              label: '仅显示白色弹幕',
              value: ref.read(danmakuStrokeProvider),
              onChanged: (v) =>
                  ref.read(danmakuStrokeProvider.notifier).state = v,
            ),
            capsuleSlider(
              label: '过滤等级',
              value: ref.read(danmakuDensityProvider),
              valueLabel:
                  '${(ref.read(danmakuDensityProvider) * 100).round()}%',
              onChanged: (v) =>
                  ref.read(danmakuDensityProvider.notifier).state = v,
            ),
          ]),
        ),
        capsuleOption(
          label: '关键词屏蔽',
          trailingLabel: '管理',
          next: CapsuleMenuLevel('关键词屏蔽', [
            capsuleOption(
              label: '打开屏蔽词管理',
              trailingLabel: '›',
              onTap: () {
                Navigator.of(context).maybePop();
                showDanmakuBlockwordManager(context);
              },
            ),
            capsuleInfo(
              label: '当前屏蔽词',
              subLabel: '${ref.read(danmakuBlockwordsProvider).length} 条',
            ),
          ]),
        ),
        capsuleOption(
          label: '弹幕密度',
          subLabel: '1.0x',
          next: CapsuleMenuLevel('弹幕密度', [
            capsuleSlider(
              label: '密度',
              value: ref.read(danmakuDensityProvider),
              valueLabel:
                  '${(ref.read(danmakuDensityProvider) * 100).round()}%',
              onChanged: (v) =>
                  ref.read(danmakuDensityProvider.notifier).state = v,
            ),
            capsuleSwitch(
              label: '防抖动',
              value: false,
              onChanged: (v) => AppToast.show(context, '防抖动 $v',
                  position: AppToastPosition.topCenter),
            ),
          ]),
        ),
        capsuleSwitch(
          label: '防抖动',
          value: false,
          onChanged: (v) => AppToast.show(context, '防抖动 $v',
              position: AppToastPosition.topCenter),
        ),
      ],
    );
  }

  void _showSpeedCapsule() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    _showCapsuleMenu(
      title: '播放倍速',
      items: [
        for (final speed in speeds)
          capsuleOption(
            label: speed == 1.0 ? '正常' : '${speed}x',
            selected: (_playerService.speed - speed).abs() < 0.01,
            onTap: () {
              Navigator.of(context).maybePop();
              _playerService.setSpeed(speed);
            },
          ),
      ],
    );
  }

  void _showSkipCapsule() {
    final t = _skipTimes;
    final hasOpening = t.hasOpening;
    final hasEnding = t.hasEnding;
    final notifier = ref.read(skipTimesProvider.notifier);
    final key = _skipTimesKey;
    _showCapsuleMenu(
      title: '跳过片头片尾',
      items: [
        capsuleSwitch(
          label: '片头跳过',
          value: hasOpening,
          onChanged: (v) {
            if (v) {
              // 用当前播放位置作为片头结束点。
              final pos = _playerService.position.inSeconds;
              if (pos > 5) {
                notifier.update(
                    key, _skipTimes.copyWith(openingStart: 5, openingEnd: pos));
              }
              AppToast.show(context, '片头跳过已开启',
                  position: AppToastPosition.topCenter);
            } else {
              notifier.update(
                  key, _skipTimes.copyWith(openingStart: 0, openingEnd: 0));
              AppToast.show(context, '片头跳过已关闭',
                  position: AppToastPosition.topCenter);
            }
          },
        ),
        capsuleSwitch(
          label: '片尾跳过',
          value: hasEnding,
          onChanged: (v) {
            if (v) {
              final pos = _playerService.position.inSeconds;
              final duration = _playerService.duration.inSeconds;
              if (duration > 0 && pos < duration - 5) {
                notifier.update(
                    key,
                    _skipTimes.copyWith(
                        endingStart: pos, endingEnd: duration - 3));
              }
              AppToast.show(context, '片尾跳过已开启',
                  position: AppToastPosition.topCenter);
            } else {
              notifier.update(
                  key, _skipTimes.copyWith(endingStart: 0, endingEnd: 0));
              AppToast.show(context, '片尾跳过已关闭',
                  position: AppToastPosition.topCenter);
            }
          },
        ),
        capsuleOption(
          label: '自定义范围',
          trailingLabel: '编辑',
          onTap: () {
            Navigator.of(context).maybePop();
            _showSkipDialog();
          },
        ),
        capsuleSwitch(
          label: '自动跳过',
          value: t.autoSkip,
          onChanged: (v) {
            notifier.update(key, _skipTimes.copyWith(autoSkip: v));
            ref.read(autoSkipSegmentsProvider.notifier).state = v;
          },
        ),
      ],
    );
  }

  void _showAspectCapsule() {
    final ratios = ['自适应', '铺满'];
    final current = ref.read(aspectRatioProvider);
    _showCapsuleMenu(
      title: '画面比例',
      items: [
        for (final ratio in ratios)
          capsuleOption(
            label: ratio,
            selected: current == ratio,
            onTap: () {
              Navigator.of(context).maybePop();
              ref.read(aspectRatioProvider.notifier).state = ratio;
              _playerService.setAspectRatio(ratio);
            },
          ),
      ],
    );
  }

  void _showInfoCapsule() {
    final resource = ref.read(unifiedResourceProvider);
    final video = resource?.video ?? const <String, dynamic>{};
    final audioTracks = resource?.audios ?? const <Map<String, dynamic>>[];
    final subtitleTracks =
        resource?.subtitles ?? const <Map<String, dynamic>>[];
    final isFeiniu = resource?.isFeiniu ?? false;

    String _trackLabel(Map<String, dynamic> t) {
      if (isFeiniu) {
        final name = t['displayName'] as String? ??
            t['title'] as String? ??
            t['language'] as String?;
        if (name == null || name.isEmpty) return '无音轨';
        final codec = t['codec'] as String?;
        final codecLabel = codec != null ? ' ($codec)' : '';
        final channels = t['channels'] as int?;
        final channelLabel = channels != null ? ', $channels CH' : '';
        return '$name$codecLabel$channelLabel';
      }
      final index = (t['index'] as int? ?? 0) + 1;
      final displayName = t['displayName'] as String? ?? t['language'] as String?;
      final codec = t['codec'] as String?;
      final channels = t['channels'] as int?;
      final bitrate = t['bitrate'] as int?;
      final parts = <String>['Track $index'];
      if (displayName != null) parts.add(displayName);
      final info = <String>[
        if (codec != null) codec,
        if (channels != null) '${channels}ch',
        if (bitrate != null && bitrate > 0) '${bitrate ~/ 1000}kbps',
      ];
      if (info.isNotEmpty) parts.add(info.join(', '));
      return parts.join(' · ');
    }

    final encoder = resource != null
        ? video['codec']?.toString().toUpperCase() ?? '未知'
        : '未知';
    final resolution = resource != null
        ? '${video['width']}×${video['height']}'
        : '未知';
    final frameRate = resource != null
        ? ((video['realFrameRate'] ?? video['nominalFrameRate'])
                ?.toStringAsFixed(0) ??
            '未知') +
            ' fps'
        : '未知';
    final bitrate = resource != null
        ? '${video['bitrate'] ?? '未知'} bps'
        : '未知';

    final items = <CapsuleMenuItem>[
      capsuleInfo(
        label: '标题',
        subLabel: ref.read(currentPlayingItemProvider)?.name ?? widget.itemId,
      ),
      capsuleInfo(label: '编码格式', subLabel: encoder),
      if (resource != null && video['container'] != null)
        capsuleInfo(label: '封装格式', subLabel: '${video['container']}'),
      capsuleInfo(label: '分辨率', subLabel: resolution),
      if (video['sample_aspect_ratio'] != null)
        capsuleInfo(label: 'SAR', subLabel: '${video['sample_aspect_ratio']}'),
      if (video['aspect_ratio'] != null)
        capsuleInfo(label: 'DAR', subLabel: '${video['aspect_ratio']}'),
      capsuleInfo(label: '帧率', subLabel: frameRate),
      capsuleInfo(label: '视频码率', subLabel: bitrate),
      if (video['pixel_format'] != null)
        capsuleInfo(label: '像素格式', subLabel: '${video['pixel_format']}'),
      if (video['bit_depth'] != null)
        capsuleInfo(label: '位深度', subLabel: '${video['bit_depth']} bit'),
      if (video['color_range'] != null)
        capsuleInfo(label: '色彩范围', subLabel: '${video['color_range']}'),
      if (video['color_space'] != null)
        capsuleInfo(label: '色彩空间', subLabel: '${video['color_space']}'),
      if (video['color_matrix'] != null)
        capsuleInfo(label: '色彩矩阵', subLabel: '${video['color_matrix']}'),
      if (video['color_transfer'] != null)
        capsuleInfo(label: 'HDR/传输', subLabel: '${video['color_transfer']}'),
      if (video['video_range_type'] != null)
        capsuleInfo(label: 'HDR类型', subLabel: '${video['video_range_type']}'),
      if (video['gop_size'] != null)
        capsuleInfo(label: 'GOP长度', subLabel: '${video['gop_size']}'),
      if (video['time_base'] != null)
        capsuleInfo(label: '时间基', subLabel: '${video['time_base']}'),
    ];

    for (var i = 0; i < audioTracks.length; i++) {
      final audio = audioTracks[i];
      final details = <String>[
        if (audio['codec_name'] != null) '${audio['codec_name']}',
        if (audio['sample_rate'] != null) '${audio['sample_rate']} Hz',
        if (audio['bit_depth'] != null) '${audio['bit_depth']} bit',
        if (audio['channels'] != null) '${audio['channels']} ch',
        if (audio['bitrate'] != null) _bitrateLabel(audio['bitrate']),
      ].where((s) => s.isNotEmpty).join(' · ');
      items.add(capsuleInfo(label: '音频 ${i + 1}', subLabel: details.isEmpty ? _trackLabel(audio) : details));
    }
    for (var i = 0; i < subtitleTracks.length; i++) {
      items.add(capsuleInfo(label: '字幕 ${i + 1}', subLabel: _trackLabel(subtitleTracks[i])));
    }

    _showCapsuleMenu(title: '媒体信息', items: items);
  }

  // ==================== 新播放器控制层适配辅助 ====================

  String _bitrateLabel(dynamic value) {
    final n = value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
    if (n <= 0) return '';
    return n >= 1000000
        ? '${(n / 1000000).toStringAsFixed(1)} Mbps'
        : '${(n / 1000).toStringAsFixed(0)} kbps';
  }

  String _episodeLabel(MediaItem? item) {
    if (item == null) return '';
    final number = item.indexNumber;
    if (number != null) return '第 $number 集';
    return item.name;
  }

  /// 进度条上方 meta 信息行（用户指定的固定顺序）：
  /// 内核 · 分辨率 · HDR · 编码 · 码率 · 帧率 · 封装 · 体积。
  /// Emby 走 MediaSource.primaryVideoStream；飞牛/网盘 source-player 走
  /// unifiedResource（normalizeMediaStream 归一化）兜底。
  String _metaLabel(MediaItem? item, MediaSource? source) {
    final parts = <String>[];

    // 1. 内核
    final core = _currentCore == 'exoPlayer' ? 'exo' : 'mpv';
    parts.add(core);

    // 2. 数据源：Emby 主视频流 vs 飞牛归一化 video map
    final video = source?.primaryVideoStream;
    final unified = _activeSourcePlay != null
        ? ref.read(unifiedResourceProvider)
        : null;
    final uniVideo = unified?.video;
    Object? uniPick(List<String> keys) {
      if (uniVideo == null) return null;
      for (final key in keys) {
        final value = uniVideo[key];
        if (value != null && value.toString().isNotEmpty) return value;
      }
      return null;
    }

    // 3. 分辨率（宽度为主分档，4K 宽屏电影不被裁切比例误判）
    String resolution = '';
    if (video != null && video.width != null && video.height != null) {
      resolution = video.resolution;
    } else if (uniVideo != null) {
      final w = (uniPick(['width']) as num?)?.toInt() ?? 0;
      final h = (uniPick(['height']) as num?)?.toInt() ?? 0;
      if (w > 0 && h > 0) {
        resolution = _resolutionLabelFromSize(w, h);
      }
    }
    if (resolution.isNotEmpty) parts.add(resolution);

    // 4. HDR（SDR 不显示，避免占位噪声）
    String hdr = '';
    if (video != null) {
      final range = video.videoRangeType ?? video.videoRange;
      if (range != null && range.toUpperCase() != 'SDR') {
        hdr = video.isDolbyVision
            ? 'DV'
            : (range.toUpperCase() == 'HDR10+' ? 'HDR10+' : range);
      }
    } else {
      final range =
          uniPick(['video_range_type', 'video_range', 'hdr_type'])
              ?.toString()
              .trim();
      if (range != null && range.isNotEmpty && range.toUpperCase() != 'SDR') {
        hdr = range.toUpperCase() == 'DOVI' ? 'DV' : range;
      }
    }
    if (hdr.isNotEmpty) parts.add(hdr);

    // 5. 编码（HEVC / H.264 / AV1 …）
    final enc = video?.videoCodecLabel ?? _unifiedCodecLabel(uniVideo);
    if (enc.isNotEmpty) parts.add(enc);

    // 6. 码率
    final bitrateRaw = uniPick(['bitrate', 'bit_rate', 'BitRate']);
    final bitrate = video?.bitRate ??
        (bitrateRaw is num ? bitrateRaw.toInt() : int.tryParse('${bitrateRaw ?? ''}'));
    if (bitrate != null && bitrate > 0) {
      parts.add('${(bitrate / 1000000).toStringAsFixed(1)}Mbps');
    }

    // 7. 帧率
    final fpsRaw = uniPick(['real_frame_rate', 'realFrameRate', 'fps']);
    final avgRaw = uniPick(['average_frame_rate']);
    final fps = video?.realFrameRate ??
        video?.averageFrameRate ??
        (fpsRaw is num
            ? fpsRaw.toDouble()
            : double.tryParse('${fpsRaw ?? ''}')) ??
        (avgRaw is num ? avgRaw.toDouble() : double.tryParse('${avgRaw ?? ''}'));
    if (fps != null && fps > 0) {
      parts
          .add('${fps.toStringAsFixed(fps == fps.roundToDouble() ? 0 : 1)}fps');
    }

    // 8. 封装格式
    final container = (source?.container ??
            uniPick(['container', 'format', 'file_format'])?.toString() ??
            _pathExtension(source?.path ??
                _activeSourcePlay?.entry.id ??
                item?.path))
        ?.trim();
    if (container != null && container.isNotEmpty) {
      parts.add(container.toLowerCase());
    }

    // 9. 媒体体积
    final sizeRaw = uniPick(['size', 'file_size', 'Size', 'length']);
    final size = source?.size ??
        (sizeRaw is num ? sizeRaw.toInt() : int.tryParse('${sizeRaw ?? ''}'));
    if (size != null && size > 0) {
      parts.add(_formatFileSize(size));
    }

    return parts.join(' · ');
  }

  /// 分辨率档位标签（宽度为主，高度兜底）——与 MediaStream.resolution 同规则，
  /// 供飞牛 unifiedResource（无 resolution 字段，只有 width/height）使用。
  String _resolutionLabelFromSize(int w, int h) {
    if (w >= 7600 || h >= 4300) return '8K';
    if (w >= 3600 || h >= 2000) return '4K';
    if (w >= 1800 || h >= 1000) return '1080p';
    if (w >= 1200 || h >= 700) return '720p';
    if (w >= 640 || h >= 480) return '480p';
    if (h > 0) return '${h}p';
    return '';
  }

  /// 飞牛 codec_name 规范化标签（与 Emby videoCodecLabel 同一套映射）。
  String _unifiedCodecLabel(Map<String, dynamic>? video) {
    final c = (video?['codec_name']?.toString() ?? '').trim().toLowerCase();
    if (c.isEmpty) return '';
    if (c.contains('hevc') || c.contains('h265') || c.contains('h.265')) {
      return 'HEVC';
    }
    if (c.contains('avc') || c.contains('h264') || c.contains('h.264')) {
      return 'H.264';
    }
    if (c.contains('av1')) return 'AV1';
    if (c.contains('vp9')) return 'VP9';
    if (c.contains('vp8')) return 'VP8';
    if (c.contains('mpeg4')) return 'MPEG-4';
    return c.toUpperCase();
  }

  /// 字节数 → 人类可读体积（B/KB/MB/GB/TB）。
  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 2)} ${units[unit]}';
  }

  String _logoText(MediaItem? item) =>
      item?.seriesName?.trim().isNotEmpty == true
          ? item!.seriesName!.trim()
          : item?.name ?? '';

  ImageProvider<Object>? _logoImage(MediaItem? item) {
    if (item == null) return null;
    final url = _mediaLogoUrl(item);
    return url == null || url.isEmpty ? null : NetworkImage(url);
  }

  String _mediaEncoder(MediaSource? source) =>
      source?.primaryVideoStream?.videoCodec ??
      source?.primaryVideoStream?.codec ??
      '';

  String _mediaResolution(MediaSource? source) =>
      source?.primaryVideoStream?.resolution ?? '';

  String _mediaFrameRate(MediaSource? source) {
    final fps = source?.primaryVideoStream?.realFrameRate ??
        source?.primaryVideoStream?.averageFrameRate;
    if (fps == null || fps <= 0) return '';
    return '${fps.toStringAsFixed(fps == fps.roundToDouble() ? 0 : 1)} fps';
  }

  String _mediaBitrate(MediaSource? source) {
    final value = source?.primaryVideoStream?.bitRate;
    if (value == null || value <= 0) return '';
    return '${(value / 1000000).toStringAsFixed(1)} Mbps';
  }

  String _mediaSize(MediaSource? source) {
    final bytes = source?.size ?? 0;
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 2)} ${units[unit]}';
  }

  int _currentEpisodeNumber(MediaItem? item) {
    final source = _activeSourcePlay;
    if (source != null && source.playlist.isNotEmpty) {
      final index = source.playlistIndex;
      if (index >= 0) return index + 1;
    }
    return item?.indexNumber ?? 0;
  }

  String? _pathExtension(String? path) {
    if (path == null) return null;
    final clean = path.split('?').first;
    final slash = clean.lastIndexOf('/');
    final dot = clean.lastIndexOf('.');
    if (dot <= slash || dot == clean.length - 1) return null;
    return clean.substring(dot + 1);
  }

  MediaSource? _currentMediaSource(
      MediaItem? item, PlaybackInfo? playbackInfo) {
    final sources = playbackInfo?.mediaSources ?? item?.mediaSources;
    if (sources == null || sources.isEmpty) return null;
    final selectedId = ref.read(selectedMediaSourceProvider) ??
        widget.mediaSourceId;
    if (selectedId != null) {
      for (final source in sources) {
        if (source.id == selectedId) return source;
      }
    }
    return sources.first;
  }

  String _currentLineName(ServerConfig? server) {
    if (server == null || server.lines.isEmpty) return '';
    final index = server.activeLineIndex.clamp(0, server.lines.length - 1);
    return server.lines[index].name;
  }

  List<String> _supportedPlayerCores() {
    if (Platform.isAndroid) {
      return const ['exoPlayer', 'nativeMpv'];
    }
    return const ['mpv'];
  }

  List<PopupLineOption> _lineOptions(ServerConfig? server) {
    if (server == null) return const <PopupLineOption>[];
    return [
      for (final line in server.lines)
        PopupLineOption(label: line.name, sub: line.remark ?? ''),
    ];
  }

  String _trackLabel(Map<String, dynamic> track) {
    final display = track['label']?.toString().trim();
    if (display != null && display.isNotEmpty) return display;
    final title = track['title']?.toString().trim();
    final language = track['language']?.toString().trim();
    final codec = track['codec']?.toString().trim();
    final parts = <String>[];
    if (title != null && title.isNotEmpty) parts.add(title);
    if (language != null && language.isNotEmpty && !parts.contains(language)) {
      parts.add(language);
    }
    if (codec != null && codec.isNotEmpty && !parts.contains(codec)) {
      parts.add(codec);
    }
    final id = track['id']?.toString().trim();
    if (parts.isEmpty && id != null && id.isNotEmpty) return id;
    return parts.join(' · ');
  }

  List<String> _audioTrackLabels() => [
        for (final track in _playerService.audioTracks)
          _trackLabel(track),
      ].where((label) => label.isNotEmpty).toList();

  List<String> _subtitleTrackLabels() => [
        for (final track in _playerService.subtitleTracks)
          _trackLabel(track),
      ].where((label) => label.isNotEmpty).toList();

  void _scheduleOverlayEpisodes(MediaItem? item) {
    final source = _activeSourcePlay;
    if (source != null && source.playlist.isNotEmpty) {
      return;
    }
    final seriesId = item?.seriesId;
    if (seriesId == null || seriesId.isEmpty) return;
    final key = '$seriesId:${item?.seasonId ?? ''}';
    if (_overlayEpisodeLoadKey == key) return;
    _overlayEpisodeLoadKey = key;
    unawaited(() async {
      try {
        final result = await ref.read(apiClientProvider).media.getEpisodes(
              seriesId,
              seasonId: item?.seasonId,
            );
        if (!mounted || _overlayEpisodeLoadKey != key) return;
        setState(() {
          _overlayEpisodes = [
            for (final episode in result)
              PopupEpisodeOption(
                index: episode.indexNumber ?? 0,
                name: episode.name,
                path: episode.id,
                selected: episode.id == item?.id,
                // 集封面缩略图：优先横幅 Thumb，无则 Primary；无图 null。
                thumbUrl: _episodeThumbUrl(episode),
              ),
          ].where((episode) => episode.index > 0).toList();
        });
      } catch (_) {
        if (mounted && _overlayEpisodeLoadKey == key) {
          setState(() => _overlayEpisodes = const <PopupEpisodeOption>[]);
        }
      }
    }());
  }

  List<PopupEpisodeOption> _overlayEpisodesFor(MediaItem? item) {
    final source = _activeSourcePlay;
    if (source != null && source.playlist.isNotEmpty) {
      return [
        for (var i = 0; i < source.playlist.length; i++)
          PopupEpisodeOption(
            index: i + 1,
            name: source.playlist[i].name,
            path: source.playlist[i].id,
            selected: source.playlist[i].id == source.entry.id,
            thumbUrl: source.playlist[i].thumbUrl,
          ),
      ];
    }
    return _overlayEpisodes;
  }

  /// 集封面缩略图 URL：横幅 Thumb 优先（选集胶囊横向排版更贴合），
  /// 无则 Primary；两者皆无返回 null（胶囊不显示图片）。
  String? _episodeThumbUrl(Episode episode) {
    final api = ref.read(apiClientProvider).image;
    if (episode.thumbImageTag != null) {
      return api.getImageUrl(
        itemId: episode.id,
        imageTag: episode.thumbImageTag,
        imageType: 'Thumb',
        maxWidth: 320,
        maxHeight: 180,
      );
    }
    if (episode.primaryImageTag != null) {
      return api.getImageUrl(
        itemId: episode.id,
        imageTag: episode.primaryImageTag,
        maxWidth: 320,
        maxHeight: 180,
      );
    }
    return null;
  }

  String _aggregateSourceKey(MediaItem? item, MediaSource? source) {
    final serverId = ref.read(currentServerProvider)?.id ?? '';
    final sourceId = source?.id ?? '';
    if (sourceId.isEmpty) return '';
    return '$serverId:${item?.id ?? widget.itemId}:$sourceId';
  }

  List<PopupAggregateSource> _overlayAggregateSources(
    MediaItem? item,
    PlaybackInfo? playbackInfo,
    MediaSource? currentSource,
    List<AggregatedVersion> versions,
  ) {
    final result = <PopupAggregateSource>[];
    final server = ref.read(currentServerProvider);
    final serverName = (server?.name ?? '').trim();
    final currentSources = playbackInfo?.mediaSources ??
        item?.mediaSources ??
        const <MediaSource>[];
    for (final source in currentSources) {
      final key = '${server?.id ?? ''}:${item?.id ?? widget.itemId}:${source.id}';
      final video = source.primaryVideoStream;
      result.add(
        PopupAggregateSource(
          id: key,
          // 胶囊标题位显示**服务器名**（源名如"原画/1080P"已由 resolution
          // 槽位展示），避免出现"不知道是哪个服务器的资源"。
          name: serverName.isNotEmpty ? serverName : (source.name ?? ''),
          resolution: source.qualityLabel,
          metadata: _sourceMetadata(source),
          dynamicRange: video?.videoRangeLabel,
          codec: video?.videoCodecLabel,
          size: source.size,
          bitrate: video?.bitRate,
        ),
      );
    }
    for (final version in versions) {
      final key = '${version.server.id}:${version.item.id}:${version.source.id}';
      final video = version.source.primaryVideoStream;
      final versionServerName = (version.server.name ?? '').trim();
      result.add(
        PopupAggregateSource(
          id: key,
          name: versionServerName.isNotEmpty
              ? versionServerName
              : (version.source.name ?? ''),
          resolution: version.source.qualityLabel,
          metadata: _sourceMetadata(version.source),
          dynamicRange: video?.videoRangeLabel,
          codec: video?.videoCodecLabel,
          size: version.source.size,
          bitrate: video?.bitRate,
        ),
      );
    }
    return result;
  }

  String _sourceMetadata(MediaSource source) {
    final video = source.primaryVideoStream;
    final parts = <String>[];
    if (source.protocol != null && source.protocol!.isNotEmpty) {
      parts.add(source.protocol!);
    }
    if (video?.bitRate != null && video!.bitRate! > 0) {
      parts.add('${(video.bitRate! / 1000000).toStringAsFixed(1)}Mbps');
    }
    final fps = video?.realFrameRate ?? video?.averageFrameRate;
    if (fps != null && fps > 0) {
      parts.add('${fps.toStringAsFixed(fps == fps.roundToDouble() ? 0 : 1)}fps');
    }
    return parts.join(' · ');
  }

  Future<void> _switchOverlaySource(
    String sourceKey,
    MediaItem? item,
    List<AggregatedVersion> versions,
  ) async {
    if (_playerNavInFlight) return;
    _playerNavInFlight = true;
    try {
      for (final version in versions) {
        final key = '${version.server.id}:${version.item.id}:${version.source.id}';
        if (key == sourceKey) {
          playAggregatedVersion(ref, context, version);
          return;
        }
      }
      final parts = sourceKey.split(':');
      if (parts.length < 3 || item == null) return;
      final sourceId = parts.sublist(2).join(':');
      if (sourceId.isEmpty) return;
      ref.read(selectedMediaSourceProvider.notifier).state = sourceId;
      if (mounted) {
        context.replace('/player/${item.id}?mediaSourceId=${Uri.encodeQueryComponent(sourceId)}');
      }
    } finally {
      _playerNavInFlight = false;
    }
  }

  String _sourceMetadataForCurrent(MediaSource? source) =>
      source == null ? '' : _sourceMetadata(source);

  String _aspectRatioValue() => ref.read(aspectRatioProvider);

  Future<void> _setAspectRatioValue(String value) async {
    ref.read(aspectRatioProvider.notifier).state = value;
    await _playerService.setAspectRatio(value);
    if (mounted) setState(() {});
  }

  /// 与播放器菜单同源的轨道标签：优先按**轨道身份**（title/lang+codec，
  /// 与 _switchXxxTrackByName 同源）在 unifiedResource 里找对应轨道，取
  /// 同一套菜单标签，保证打开面板时默认项正确点亮；身份未命中回退同索引，
  /// 最后回退播放器轨道标签。
  String _trackLabelForOverlay(Map<String, dynamic> track, int index) {
    final unified = ref.read(unifiedResourceProvider);
    if (unified != null) {
      final isAudio = track['type']?.toString().toLowerCase() == 'audio';
      final list = isAudio ? unified.audios : unified.subtitles;
      final wanted = _trackIdentity(track);
      for (final t in list) {
        if (_trackIdentity(t) == wanted) {
          return unifiedTrackLabel(t, unified.isFeiniu);
        }
      }
      if (index < list.length) {
        return unifiedTrackLabel(list[index], unified.isFeiniu);
      }
    }
    return _trackLabel(track);
  }

  String _currentAudioTrackLabel() {
    final audioTracks = _playerService.tracksInfo
        .where((t) => t['type']?.toString().toLowerCase() == 'audio')
        .toList();
    int? selectedIndex;
    for (var i = 0; i < audioTracks.length; i++) {
      if (audioTracks[i]['isSelected'] == true ||
          audioTracks[i]['selected'] == true) {
        selectedIndex = i;
        break;
      }
    }
    if (selectedIndex == null) return '';
    return _trackLabelForOverlay(audioTracks[selectedIndex], selectedIndex);
  }

  String _currentSubtitleTrackLabel() {
    final subtitleTracks = _playerService.tracksInfo
        .where((t) =>
            t['type']?.toString().toLowerCase() == 'text' ||
            t['type']?.toString().toLowerCase() == 'bitmap')
        .toList();
    int? selectedIndex;
    for (var i = 0; i < subtitleTracks.length; i++) {
      if (subtitleTracks[i]['isSelected'] == true ||
          subtitleTracks[i]['selected'] == true) {
        selectedIndex = i;
        break;
      }
    }
    if (selectedIndex == null) return '';
    return _trackLabelForOverlay(subtitleTracks[selectedIndex], selectedIndex);
  }

  Duration _durationFromProgress(double progress) {
    final durationMs = _playerService.duration.inMilliseconds;
    return Duration(
      milliseconds: (durationMs * progress.clamp(0.0, 1.0)).round(),
    );
  }

  Future<void> _switchLine(String lineName) async {
    final server = ref.read(currentServerProvider);
    if (server == null || server.lines.isEmpty) return;
    final index = server.lines.indexWhere((l) => l.name == lineName);
    if (index < 0 || index == server.activeLineIndex) return;
    final line = server.lines[index];
    ref.read(serverListProvider.notifier).setActiveLine(server.id, index);
    final updatedServer = ref
        .read(serverListProvider)
        .firstWhere((s) => s.id == server.id);
    ref.read(currentServerProvider.notifier).state = updatedServer;
    // 源直链（飞牛等）播放：重初始化时 resolvePlay 依赖 SourcePlayback.server
    // 的 activeLineUrl；不重建会继续用旧线路解析直链，导致切线路无效。
    final sp = _activeSourcePlay;
    if (sp != null) {
      _activeSourcePlay = sp.withServer(updatedServer);
    }
    await _reinitPlayerForLine(line.name);
  }

  Future<void> _switchEpisode(int episode) async {
    final source = _activeSourcePlay;
    if (source != null && source.playlist.isNotEmpty) {
      final index = episode - 1;
      if (index >= 0 && index < source.playlist.length) {
        await _switchSourceEpisode(source.playlist[index]);
      }
      return;
    }
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId == null) {
      AppToast.show(context, '当前资源没有可用选集',
          position: AppToastPosition.topCenter);
      return;
    }
    final episodes = await ref
        .read(apiClientProvider)
        .media
        .getEpisodes(currentItem!.seriesId!,
            seasonId: currentItem.seasonId);
    if (episodes.isEmpty) return;
    final target = episodes.firstWhere(
      (e) => e.indexNumber == episode,
      orElse: () {
        final safeIndex = (episode - 1)
            .clamp(0, episodes.length - 1)
            .toInt();
        return episodes[safeIndex];
      },
    );
    if (mounted && target.id != currentItem.id) {
      context.replace('/player/${target.id}');
    }
  }

  void _setAutoSkip(bool value) {
    ref
        .read(skipTimesProvider.notifier)
        .update(_skipTimesKey, _skipTimes.copyWith(autoSkip: value));
    ref.read(autoSkipSegmentsProvider.notifier).state = value;
    AppToast.show(context, value ? '自动跳过已开启' : '自动跳过已关闭',
        position: AppToastPosition.topCenter);
  }

  void _recordSkipTime(PopupSkipRecord record) {
    final seconds = _parseTimeToSeconds(record.time);
    final notifier = ref.read(skipTimesProvider.notifier);
    final key = _skipTimesKey;
    if (record.type == '片头') {
      notifier.update(
          key, _skipTimes.copyWith(openingStart: 5, openingEnd: seconds));
    } else {
      final duration = _playerService.duration.inSeconds;
      notifier.update(
          key,
          _skipTimes.copyWith(
              endingStart: seconds,
              endingEnd: duration > seconds ? duration - 3 : duration));
    }
    AppToast.show(context, '已记录${record.type}时间: ${record.time}',
        position: AppToastPosition.topCenter);
  }

  String? _formatSkipTime(int seconds) {
    if (seconds <= 0) return null;
    final minutes = seconds ~/ 60;
    final remain = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remain.toString().padLeft(2, '0')}';
  }

  void _clearOpeningSkip() {
    ref
        .read(skipTimesProvider.notifier)
        .update(_skipTimesKey, _skipTimes.copyWith(openingStart: 0, openingEnd: 0));
    AppToast.show(context, '已清除片头跳过时间',
        position: AppToastPosition.topCenter);
  }

  void _clearEndingSkip() {
    ref
        .read(skipTimesProvider.notifier)
        .update(_skipTimesKey, _skipTimes.copyWith(endingStart: 0, endingEnd: 0));
    AppToast.show(context, '已清除片尾跳过时间',
        position: AppToastPosition.topCenter);
  }

  int _parseTimeToSeconds(String time) {
    final parts = time.split(':');
    if (parts.length == 2) {
      return int.tryParse(parts[0])! * 60 + int.tryParse(parts[1])!;
    }
    if (parts.length == 3) {
      return int.tryParse(parts[0])! * 3600 +
          int.tryParse(parts[1])! * 60 +
          int.tryParse(parts[2])!;
    }
    return int.tryParse(time) ?? 0;
  }

  void _showCoreCapsule() {
    final currentCore = normalizePlayerCore(
        _sourceCoreOverride ?? ref.read(playerCoreProvider));
    final items = <CapsuleMenuItem>[
      if (Platform.isAndroid)
        capsuleOption(
          label: 'MPV 原生',
          selected: currentCore == 'nativeMpv',
          onTap: () {
            Navigator.of(context).maybePop();
            if (currentCore != 'nativeMpv') _switchCore('nativeMpv');
          },
        ),
      capsuleOption(
        label: 'ExoPlayer',
        selected: currentCore == 'exoPlayer',
        onTap: () {
          Navigator.of(context).maybePop();
          if (currentCore != 'exoPlayer') _switchCore('exoPlayer');
        },
      ),
      if (!Platform.isAndroid)
        capsuleOption(
          label: 'MPV 原生',
          selected: currentCore == 'mpv',
          onTap: () {
            Navigator.of(context).maybePop();
            if (currentCore != 'mpv') _switchCore('mpv');
          },
        ),
    ];
    _showCapsuleMenu(title: '播放器内核', items: items);
  }

  void _showLineCapsule() {
    final server = ref.read(currentServerProvider);
    if (server == null || server.lines.length <= 1) {
      AppToast.show(context, '当前只有一个可用线路',
          position: AppToastPosition.topCenter);
      return;
    }
    _showCapsuleMenu(
      title: '线路选择',
      items: [
        for (final entry in server.lines.asMap().entries)
          capsuleOption(
            label: entry.value.name,
            subLabel: entry.key == server.activeLineIndex ? '直连' : null,
            selected: entry.key == server.activeLineIndex,
            onTap: () {
              Navigator.of(context).maybePop();
              final idx = entry.key;
              final line = entry.value;
              ref
                  .read(serverListProvider.notifier)
                  .setActiveLine(server.id, idx);
              final updatedServer = ref
                  .read(serverListProvider)
                  .firstWhere((s) => s.id == server.id);
              ref.read(currentServerProvider.notifier).state = updatedServer;
              // 同 _switchLine：源直链播放需同步重建 SourcePlayback.server，
              // 否则重初始化 resolvePlay 仍用旧线路直链。
              final sp = _activeSourcePlay;
              if (sp != null) {
                _activeSourcePlay = sp.withServer(updatedServer);
              }
              unawaited(_reinitPlayerForLine(line.name));
            },
          ),
      ],
    );
  }

  Future<void> _reinitPlayerForLine(String lineName) async {
    final savedPosition = _playerService.position;
    await _playerService.dispose();
    _playerService = VideoPlayerService();
    _activePlayerService = _playerService;
    _playerService.addListener(_onPlayerUpdate);
    await _initializePlayer(startPositionOverride: savedPosition);
    if (mounted) {
      AppToast.show(context, '已切换到线路: $lineName',
          position: AppToastPosition.topCenter);
    }
  }

  void _showAudioCapsule() {
    _showCapsuleMenu(
      title: '音频轨道',
      items: _buildAudioCapsuleItems(),
    );
  }

  List<CapsuleMenuItem> _buildAudioCapsuleItems() {
    final item = ref.read(currentPlayingItemProvider);
    final isSourcePlayback = item?.id.startsWith('src:') == true;
    final playerTracks = _playerService.tracksInfo
        .where((t) => t['type'] == 'audio')
        .toList();
    if (isSourcePlayback || playerTracks.isNotEmpty) {
      return [
        for (final t in playerTracks)
          capsuleOption(
            label: t['label']?.toString() ??
                t['title']?.toString() ??
                '音轨',
            subLabel: t['codec']?.toString(),
            selected: t['isSelected'] == true,
            onTap: () {
              Navigator.of(context).maybePop();
              _playerService.selectAudioTrack(t['id'].toString());
            },
          ),
        if (playerTracks.isEmpty)
          capsuleOption(
            label: '暂无可用音轨',
            selected: false,
            onTap: () {},
          ),
      ];
    }
    // Emby 流场景：异步读 PlaybackInfo 再打开菜单（保底降级为全设置面板）。
    final mediaSourceId =
        widget.mediaSourceId ?? ref.read(selectedMediaSourceProvider);
    final playbackInfo = item == null
        ? null
        : ref.read(playbackInfoProvider(item.id));
    if (playbackInfo == null) {
      return [
        capsuleOption(
          label: '打开音频设置',
          trailingLabel: '›',
          selected: false,
          onTap: () {
            Navigator.of(context).maybePop();
            _showAudioSettings();
          },
        ),
      ];
    }
    final info = playbackInfo.valueOrNull;
    if (info == null) {
      return [
        capsuleOption(
          label: '打开音频设置',
          trailingLabel: '›',
          selected: false,
          onTap: () {
            Navigator.of(context).maybePop();
            _showAudioSettings();
          },
        ),
      ];
    }
    final mediaSource = mediaSourceId != null
        ? info.mediaSources.firstWhere((s) => s.id == mediaSourceId,
            orElse: () => info.mediaSources.first)
        : info.mediaSources.firstOrNull;
    final audios =
        mediaSource?.mediaStreams.where((s) => s.isAudio).toList() ?? [];
    if (audios.isEmpty) {
      return [
        capsuleOption(
          label: '暂无可用音轨',
          selected: false,
          onTap: () {},
        ),
      ];
    }
    final selectedAudioIndex = ref.read(audioTrackProvider);
    return [
      for (final stream in audios)
        capsuleOption(
          label: stream.readableLabel(),
          subLabel: stream.codec,
          selected: selectedAudioIndex == stream.index,
          onTap: () {
            Navigator.of(context).maybePop();
            ref.read(audioTrackProvider.notifier).state = stream.index;
            _switchAudioTrack(audios, stream.index);
          },
        ),
    ];
  }

  void _showSubtitleCapsule() {
    _showCapsuleMenu(
      title: '字幕轨道',
      items: _buildSubtitleCapsuleItems(),
    );
  }

  List<CapsuleMenuItem> _buildSubtitleCapsuleItems() {
    final item = ref.read(currentPlayingItemProvider);
    final isSourcePlayback = item?.id.startsWith('src:') == true;
    final playerTracks = _playerService.tracksInfo
        .where((t) =>
            (t['type'] == 'text' || t['type'] == 'bitmap') &&
            t['id'] != 'auto' &&
            t['id'] != 'no')
        .toList();
    final items = <CapsuleMenuItem>[
      capsuleOption(
        label: '关闭字幕',
        selected: playerTracks.every((t) => t['isSelected'] != true),
        onTap: () {
          Navigator.of(context).maybePop();
          _playerService.deselectSubtitleTrack();
        },
      ),
    ];
    if (isSourcePlayback || playerTracks.isNotEmpty) {
      items.addAll([
        for (final t in playerTracks)
          capsuleOption(
            label: t['label']?.toString() ??
                t['title']?.toString() ??
                '字幕',
            subLabel: t['codec']?.toString(),
            selected: t['isSelected'] == true,
            onTap: () {
              Navigator.of(context).maybePop();
              _playerService.selectSubtitleTrack(t['id'].toString());
            },
          ),
      ]);
    } else {
      items.add(
        capsuleOption(
          label: '字幕设置',
          trailingLabel: '›',
          selected: false,
          onTap: () {
            Navigator.of(context).maybePop();
            _showSubtitleSettings();
          },
        ),
      );
    }
    items.add(
      capsuleOption(
        label: '外挂字幕',
        trailingLabel: '加载',
        selected: false,
        onTap: () {
          Navigator.of(context).maybePop();
          _pickExternalSubtitle();
        },
      ),
    );
    return items;
  }

  void _showEpisodeCapsule(MediaItem? item) {
    final sourcePlay = _activeSourcePlay;
    if (sourcePlay != null && sourcePlay.playlist.isNotEmpty) {
      _showCapsuleMenu(
        title: '选集',
        items: [
          for (final entry in sourcePlay.playlist)
            capsuleOption(
              label: entry.name,
              selected: entry.id == sourcePlay.entry.id,
              onTap: () {
                Navigator.of(context).maybePop();
                _switchSourceEpisode(entry);
              },
            ),
        ],
      );
      return;
    }
    if (item?.seriesId == null) {
      AppToast.show(context, '当前资源没有可用选集',
          position: AppToastPosition.topCenter);
      return;
    }
    // 选集数量可能很大，胶囊菜单只放快捷入口，完整列表仍走右侧面板。
    _showCapsuleMenu(
      title: '选集',
      items: [
        capsuleOption(
          label: '打开选集列表',
          trailingLabel: '›',
          selected: false,
          onTap: () {
            Navigator.of(context).maybePop();
            _showEpisodeSelector(item);
          },
        ),
      ],
    );
  }

  void _showAggregationCapsule() {
    if (_overlayAggregateSources(
      ref.read(currentPlayingItemProvider),
      ref.read(playbackInfoProvider(widget.itemId)).valueOrNull,
      _currentMediaSource(
        ref.read(currentPlayingItemProvider),
        ref.read(playbackInfoProvider(widget.itemId)).valueOrNull,
      ),
      const [],
    ).isEmpty) {
      _showAggregationSearch();
      return;
    }
    _showCapsuleMenu(
      title: '聚合搜索 · 更多资源',
      items: [
        capsuleInfo(
          label: '搜索',
          subLabel: ref.read(currentPlayingItemProvider)?.name ??
              widget.itemId,
        ),
        capsuleOption(
          label: '搜索更多资源',
          trailingLabel: '›',
          selected: false,
          onTap: () {
            Navigator.of(context).maybePop();
            _showAggregationSearch();
          },
        ),
      ],
    );
  }

  /// 统一的胶囊菜单弹层（居中深色半透明，支持二级/三级嵌套导航）。
  void _showCapsuleMenu({
    required String title,
    required List<CapsuleMenuItem> items,
  }) {
    showCapsuleMenu(
      context: context,
      level: CapsuleMenuLevel(title, items),
    );
  }

  /// 切换音频轨（胶囊菜单用；逻辑与右侧面板一致）。
  Future<void> _switchAudioTrack(
      List<MediaStream> audios, int selectedStreamIndex) async {
    final tracks = _playerService.tracksInfo;
    final audioTracks = tracks.where((t) => t['type'] == 'audio').toList();
    final audioPosition =
        audios.indexWhere((stream) => stream.index == selectedStreamIndex);
    if (audioPosition < 0 || audioPosition >= audioTracks.length) {
      return;
    }
    final trackId = audioTracks[audioPosition]['id']?.toString() ?? '';
    if (trackId.isNotEmpty) {
      await _playerService.selectAudioTrack(trackId);
    }
  }

  /// 新播放器控制层：按显示名称切换音轨（名称来自 PopupMenuOverlay 音频菜单）。
  /// 轨道身份键：title/label 优先（同语言多轨靠标题消歧），缺失时退到
  /// language+规范化 codec。兼容 mpv/exo 的 tracksInfo 与 unified 归一化
  /// 数据（codec 与 codec_name 双命名、exo 的 mp4a.40.2/dts 与 ffmpeg 的
  /// aac/dca 命名差异），供跨数据源按身份匹配轨道。
  String _trackIdentity(Map<String, dynamic> track) {
    final title = (track['title'] ??
            track['label'] ??
            track['displayName'] ??
            track['display_title'] ??
            '')
        .toString()
        .trim()
        .toLowerCase();
    if (title.isNotEmpty) return 'title:$title';
    final lang =
        (track['language'] ?? track['lang'] ?? '').toString().trim().toLowerCase();
    final codec = _normCodec(
        (track['codec'] ?? track['codec_name'] ?? '').toString());
    return 'lang:$lang|codec:$codec';
  }

  String _normCodec(String codec) {
    final c = codec.toLowerCase();
    if (c.contains('mp4a') || c == 'aac') return 'aac';
    if (c.contains('ac-3') || c == 'ac3' || c == 'eac3' || c == 'ec-3') {
      return 'ac3';
    }
    if (c.contains('dts') || c == 'dca') return 'dca';
    if (c.contains('opus')) return 'opus';
    if (c.contains('flac')) return 'flac';
    if (c.contains('truehd') || c == 'mlp') return 'truehd';
    return c;
  }

  Future<void> _switchAudioTrackByName(String trackName) async {
    final audioTracks = _playerService.tracksInfo
        .where((t) => t['type'] == 'audio')
        .toList();
    // 1) 播放器轨道标签精确匹配。
    for (final track in audioTracks) {
      if (_trackLabel(track) == trackName) {
        final trackId = track['id']?.toString() ?? '';
        if (trackId.isNotEmpty) {
          await _playerService.selectAudioTrack(trackId);
        }
        return;
      }
    }
    // 2) unified 轨道标签（菜单显示格式）→ 按**轨道身份**匹配到播放器
    //    实际轨道（title / language+codec），再取其 id 切换。
    //    不能用索引一一对应：unified.audios 来自媒体流信息（mediaDetails/
    //    MediaSource），audioTracks 来自播放器实际轨道（mpv track-list/
    //    ExoPlayer groups），两者顺序可能不一致——索引错位会切错轨道
    //    （如点 DTS 实际又切回 AAC，表现为"切换无感"）。
    final unified = ref.read(unifiedResourceProvider);
    if (unified != null) {
      for (var i = 0; i < unified.audios.length; i++) {
        if (unifiedTrackLabel(unified.audios[i], unified.isFeiniu) !=
            trackName) {
          continue;
        }
        final wanted = _trackIdentity(unified.audios[i]);
        for (final track in audioTracks) {
          if (_trackIdentity(track) == wanted) {
            final trackId = track['id']?.toString() ?? '';
            if (trackId.isNotEmpty) {
              await _playerService.selectAudioTrack(trackId);
            }
            return;
          }
        }
        // 身份未命中（字段缺失/命名差异）：回退同索引（顺序一致时仍正确）。
        if (i < audioTracks.length) {
          final trackId = audioTracks[i]['id']?.toString() ?? '';
          if (trackId.isNotEmpty) {
            await _playerService.selectAudioTrack(trackId);
          }
        }
        return;
      }
    }
  }

  /// 新播放器控制层：按显示名称切换字幕（名称来自 PopupMenuOverlay 字幕菜单）。
  Future<void> _switchSubtitleTrackByName(String trackName) async {
    if (trackName == '关闭字幕') {
      await _playerService.deselectSubtitleTrack();
      // 持久化"关闭"：内核切换/重新初始化后保持关闭（_applyTrackSelections
      // 读到 -1 会再次 deselect）。
      ref.read(subtitleTrackProvider.notifier).state = -1;
      // 跨会话持久化：下次从任何入口播放同样保持关闭。
      unawaited(
          PlaybackPrefsStore.instance.writeSubtitleIndex(widget.itemId, -1));
      return;
    }
    final subtitleTracks = _playerService.tracksInfo
        .where((t) => t['type'] == 'text' || t['type'] == 'bitmap')
        .toList();
    // 1) 播放器轨道标签精确匹配。
    for (final track in subtitleTracks) {
      if (_trackLabel(track) == trackName) {
        final trackId = track['id']?.toString() ?? '';
        if (trackId.isNotEmpty) {
          await _playerService.selectSubtitleTrack(trackId);
          await _rememberSubtitleSelection(trackId, subtitleTracks);
        }
        return;
      }
    }
    // 2) unified 轨道标签 → 按轨道身份匹配到播放器实际轨道（同音频，
    //    避免 unified.subtitles 与 tracksInfo 顺序不一致切错字幕）。
    final unified = ref.read(unifiedResourceProvider);
    if (unified != null) {
      for (var i = 0; i < unified.subtitles.length; i++) {
        if (unifiedTrackLabel(unified.subtitles[i], unified.isFeiniu) !=
            trackName) {
          continue;
        }
        final wanted = _trackIdentity(unified.subtitles[i]);
        for (final track in subtitleTracks) {
          if (_trackIdentity(track) == wanted) {
            final trackId = track['id']?.toString() ?? '';
            if (trackId.isNotEmpty) {
              await _playerService.selectSubtitleTrack(trackId);
              await _rememberSubtitleSelection(trackId, subtitleTracks);
            }
            return;
          }
        }
        // 身份未命中：回退同索引（顺序一致时仍正确）。
        if (i < subtitleTracks.length) {
          final trackId = subtitleTracks[i]['id']?.toString() ?? '';
          if (trackId.isNotEmpty) {
            await _playerService.selectSubtitleTrack(trackId);
            await _rememberSubtitleSelection(trackId, subtitleTracks);
          }
        }
        return;
      }
    }
  }

  /// 播放器内选轨成功后持久化字幕选择（跨会话，下次播放恢复）：
  /// - 飞牛/直链（source-player）：按播放器字幕列表位置记录（该路径无 Emby
  ///   MediaStream 可反查；tracksInfo 字幕顺序与详情页 subtitles 一致，
  ///   _applySourceTrackPreferences 按同一列表索引选中）。
  /// - Emby：经 [_persistSubtitleSelection] 按媒体流索引（MediaStream.index）
  ///   记录，换版本/资源后按流身份恢复更稳。
  Future<void> _rememberSubtitleSelection(
      String trackId, List<Map<String, dynamic>> subtitleTracks) async {
    if (widget.sourcePlay != null) {
      final idx =
          subtitleTracks.indexWhere((t) => t['id']?.toString() == trackId);
      if (idx >= 0) {
        await PlaybackPrefsStore.instance.writeSubtitleIndex(widget.itemId, idx);
      }
      return;
    }
    await _persistSubtitleSelection(trackId);
  }

  /// 播放器菜单按显示名选字幕成功后，把选择持久化到 [subtitleTrackProvider]
  /// （媒体流索引）：内核切换（exo↔mpv）或重新初始化时，_applyTrackSelections
  /// 只认该 provider 恢复选择——否则菜单选的字幕只作用于当前内核，切内核就丢。
  /// 通过 player 轨道 id 反查媒体流：先按身份匹配（_matchMpv/_matchExo），
  /// 未命中按 player 字幕轨顺序对齐 mediaStream 顺序兜底。
  Future<void> _persistSubtitleSelection(String trackId) async {
    final item = ref.read(currentPlayingItemProvider);
    if (item == null) return;
    final api = ref.read(apiClientProvider);
    try {
      final playbackInfo = await api.playback.getPlaybackInfo(item.id);
      final mediaSource = _resolveMediaSource(playbackInfo);
      if (mediaSource == null) return;
      final subtitleStreams =
          mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();
      if (subtitleStreams.isEmpty) return;
      final tracks = _playerService.tracksInfo;
      final subtitleTracks = tracks
          .where((t) =>
              (t['type'] == 'text' || t['type'] == 'bitmap') &&
              t['id'] != 'auto' &&
              t['id'] != 'no')
          .toList();
      final isMpv = _playerService.coreType == PlayerCoreType.mpv ||
          _playerService.coreType == PlayerCoreType.nativeMpv;
      for (final stream in subtitleStreams) {
        final tid = isMpv
            ? _matchMpvSubtitleTrack(
                subtitleTracks,
                stream.language,
                stream.displayTitle ?? stream.title,
                stream.codec,
                stream.index,
              )
            : _matchExoSubtitleTrack(
                subtitleTracks,
                stream.language,
                stream.displayTitle ?? stream.title,
                stream.codec,
                stream.index,
              );
        if (tid == trackId) {
          ref.read(subtitleTrackProvider.notifier).state = stream.index;
          // 跨会话持久化：按媒体流索引记录，下次播放恢复。
          unawaited(PlaybackPrefsStore.instance
              .writeSubtitleIndex(widget.itemId, stream.index));
          return;
        }
      }
      // 反查未命中：按 player 字幕轨顺序对齐 mediaStream 顺序兜底。
      final idx =
          subtitleTracks.indexWhere((t) => t['id']?.toString() == trackId);
      if (idx >= 0 && idx < subtitleStreams.length) {
        ref.read(subtitleTrackProvider.notifier).state =
            subtitleStreams[idx].index;
        unawaited(PlaybackPrefsStore.instance
            .writeSubtitleIndex(widget.itemId, subtitleStreams[idx].index));
      }
    } catch (_) {
      // 持久化失败不影响本次切换。
    }
  }

  /// 导入外挂字幕（胶囊菜单用；逻辑与右侧面板一致）。
  Future<void> _pickExternalSubtitle() async {
    try {
      // Android SAF 按 MIME 过滤时 ass/ssa/sup 等无标准关联的扩展名会被
      // 文件管理器灰显/过滤导致「无法选择 ASS」，改用 FileType.any 后自行校验。
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result == null || result.files.single.path == null) {
        return;
      }
      final pickedPath = result.files.single.path!;
      final logger = AppLogger();
      final lowerExt = pickedPath.split('.').last.toLowerCase();
      const allowedExtensions = {'srt', 'ass', 'ssa', 'vtt', 'sup', 'pgs'};
      if (!allowedExtensions.contains(lowerExt)) {
        if (mounted) {
          AppToast.show(context, '仅支持 srt/ass/ssa/vtt/sup/pgs 字幕文件',
              kind: AppToastKind.error, position: AppToastPosition.topCenter);
        }
        return;
      }
      logger.i('Player', '导入外部字幕: $pickedPath');

      // 拷贝到应用私有临时目录（保留扩展名）：消除 SAF content:// 与作用域
      // 存储路径权限问题，保证 EXO/MPV 都能稳定读取。
      final tempDir = await getTemporaryDirectory();
      final safeName =
          'ext_subtitle_${DateTime.now().millisecondsSinceEpoch}.$lowerExt';
      final localFile = await File(pickedPath).copy('${tempDir.path}/$safeName');

      var pathToLoad = localFile.path;
      if (_playerService.coreType == PlayerCoreType.exoPlayer &&
          (lowerExt == 'ass' || lowerExt == 'ssa') &&
          !ref.read(exoLibassProvider)) {
        pathToLoad = await SubtitleProcessor.convertAssToSrt(localFile.path);
        logger.i('Player', '导入字幕: EXO内核已将 ASS/SSA 转为 SRT: $pathToLoad');
      }
      await _playerService.loadLibassSubtitle(pathToLoad);
      // EXO 原生端在轨道就绪后自动选轨存在时序竞态（一次性延迟，轨道未就绪
      // 则永久漏选 →「提示加载成功但无字幕」），Dart 侧轮询兜底主动选中。
      final selected = await _selectExternalSubtitleTrack(pathToLoad);
      if (!mounted) return;
      if (selected) {
        AppToast.show(context, '已导入并加载字幕: ${result.files.single.name}',
            position: AppToastPosition.topCenter);
      } else {
        AppToast.show(context, '字幕文件已导入，但播放器未识别到字幕轨',
            position: AppToastPosition.topCenter);
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '导入失败: $e',
            kind: AppToastKind.error, position: AppToastPosition.topCenter);
      }
    }
  }

  /// 加载外挂字幕文件后，等待并主动选中新出现的字幕轨（EXO/MPV 共用）。
  /// 返回是否成功选中。
  Future<bool> _selectExternalSubtitleTrack(String subtitlePath) async {
    final before = _playerService.tracksInfo
        .where((t) => _isSubtitleTrack(t))
        .map((t) => t['id']?.toString())
        .toSet();
    final ext = subtitlePath.split('.').last.toLowerCase();
    final targetKeywords = switch (ext) {
      'ass' || 'ssa' => const ['ssa', 'ass'],
      'vtt' => const ['vtt', 'webvtt'],
      'sup' || 'pgs' => const ['pgs', 'sup', 'hdmv'],
      _ => const ['subrip', 'x-subrip', 'srt'],
    };
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final tracks = _playerService.tracksInfo
          .where((t) => _isSubtitleTrack(t))
          .toList();
      for (final track in tracks) {
        final id = track['id']?.toString();
        if (id == null || id.isEmpty || before.contains(id)) continue;
        final mime = (track['mimeType']?.toString() ?? '').toLowerCase();
        final codec = (track['codec']?.toString() ?? '').toLowerCase();
        final label =
            '${track['label']} ${track['title']} ${track['language']}'
                .toLowerCase();
        final matched = targetKeywords.any((k) =>
            mime.contains(k) || codec.contains(k) || label.contains(k));
        if (matched || i >= 15) {
          // 匹配到新字幕轨；超时后兜底选最后出现的一条字幕轨。
          await _playerService.selectSubtitleTrack(id);
          return true;
        }
      }
    }
    return false;
  }

  bool _isSubtitleTrack(Map<String, dynamic> track) {
    final type = track['type']?.toString();
    return type == 'text' || type == 'bitmap' || type == 'sub';
  }

  void _showSkipDialog() {
    _showRightPanel(
      title: '跳过片头',
      children: [
        _SkipDialog(
          currentPosition: _playerService.position,
          skipKey: _skipTimesKey,
        ),
      ],
    );
  }

  void _showSpeedPanel() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('播放速度',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final speed in speeds)
                  ActionChip(
                    label: Text('${speed}x'),
                    backgroundColor: (_playerService.speed - speed).abs() < 0.01
                        ? Theme.of(context).colorScheme.primary
                        : null,
                    labelStyle: TextStyle(
                      color: (_playerService.speed - speed).abs() < 0.01
                          ? Colors.white
                          : null,
                      fontWeight: FontWeight.w700,
                    ),
                    onPressed: () {
                      _playerService.setSpeed(speed);
                      Navigator.pop(sheetContext);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _toggleRotation() {
    final orientation = MediaQuery.of(context).orientation;
    if (orientation == Orientation.portrait) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  Future<void> _takeScreenshot() async {
    try {
      final data = await _playerService.screenshot();
      if (!mounted) return;
      if (data == null) {
        AppToast.show(context, '截图功能暂不支持当前播放器内核',
            position: AppToastPosition.topCenter);
        return;
      }
      // 真正落盘到系统「下载/WJPlayer」目录（之前只拿到字节、从未落盘）。
      // Android 10+ 走 MediaStore.Downloads（免存储权限）；<10 写公共 Download/WJPlayer
      //（清单已声明 maxSdk28）。
      bool saved = false;
      try {
        saved = await const MethodChannel('com.mapleling.wjplayer/media')
                .invokeMethod<bool>('saveImageToGallery', {
              'bytes': data,
              'name': 'WJPlayer_${DateTime.now().millisecondsSinceEpoch}',
            }) ??
            false;
      } catch (_) {
        saved = false;
      }
      if (!mounted) return;
      AppToast.show(context, saved ? '截图已保存到 下载/WJPlayer' : '截图保存失败，请重试',
          position: AppToastPosition.topCenter);
    } catch (_) {
      if (!mounted) return;
      AppToast.show(context, '截图失败，请重试',
          kind: AppToastKind.error, position: AppToastPosition.topCenter);
    }
  }

  void _showStats() {
    _showRightPanel(
      title: '媒体信息',
      children: [
        _PlaybackStatsView(service: _playerService),
      ],
    );
  }

  void _showDanmakuSettings() {
    _showRightPanel(
      title: '弹幕设置',
      children: [
        const _DanmakuSettingsContent(),
      ],
    );
  }

  /// 去重开关/时间窗口变化：用缓存重载原始弹幕并重新过滤，让开关立即生效
  /// （不重载的话去重只对下次加载的弹幕生效，看起来"改了没用"）。
  Future<void> _reapplyDanmakuFilter() async {
    final ctx = ref.read(danmakuContextProvider);
    if (ctx == null) return;
    final service = ref.read(danmakuServiceProvider);
    try {
      final raw =
          await service.getComments(ctx.episodeId, sourceId: ctx.sourceId);
      final items = applyDanmakuFilterAndDedup(
        raw,
        blockwords: ref.read(danmakuBlockwordsProvider),
        dedup: ref.read(danmakuDedupProvider),
        dedupWindow: ref.read(danmakuDedupWindowProvider),
      );
      if (mounted) {
        ref.read(loadedDanmakuProvider.notifier).state = items;
      }
    } catch (_) {
      // 重载失败保留现有弹幕，不打断播放。
    }
  }

  void _showDanmakuSearch() {
    final item = ref.read(currentPlayingItemProvider);
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 28,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
            child: PopupMenuShell(
              child: DanmakuSearchContent(item: item),
            ),
          ),
        );
      },
    );
  }

  void _showSubtitleSettings() {
    _showRightPanel(
      title: '字幕设置',
      children: [
        const _SubtitleSettingsContent(),
      ],
    );
  }

  Future<void> _applyInitialAudioTrack(
      List<MediaStream> audioStreams, int selectedIndex) async {
    final tracks = _playerService.tracksInfo;
    final audioTracks =
        tracks.where((track) => track['type'] == 'audio').toList();
    final audioPosition =
        audioStreams.indexWhere((stream) => stream.index == selectedIndex);
    if (audioPosition < 0 || audioPosition >= audioTracks.length) {
      return;
    }
    final trackId = audioTracks[audioPosition]['id']?.toString();
    if (trackId != null && trackId.isNotEmpty) {
      await _playerService.selectAudioTrack(trackId);
    }
  }

  void _showAudioSettings() {
    _showRightPanel(
      title: '音频设置',
      children: [
        const _AudioSettingsContent(),
      ],
    );
  }

  void _showEpisodeSelector(MediaItem? item) {
    final sourcePlay = _activeSourcePlay;
    if (sourcePlay != null && sourcePlay.playlist.isNotEmpty) {
      _showRightPanel(
        title: '选集',
        width: 460,
        maxWidthFraction: 0.5,
        children: [
          for (final entry in sourcePlay.playlist)
            PanelOptionTile(
              label: entry.name,
              leading: const Icon(Icons.play_circle_outline_rounded),
              selected: entry.id == sourcePlay.entry.id,
              onTap: () {
                Navigator.pop(context);
                _switchSourceEpisode(entry);
              },
            ),
        ],
      );
      return;
    }
    if (item?.seriesId == null) {
      AppToast.show(context, '当前资源没有可用选集',
          position: AppToastPosition.topCenter);
      return;
    }

    _showRightPanel(
      title: '选集',
      // 集数弹窗比普通设置面板宽：手机横屏下 1/3 只有 ~280px，封面小、参数挤。
      // 放宽到 1/2（普通面板仍走默认 1/3），封面和参数才有空间。
      width: 460,
      maxWidthFraction: 0.5,
      children: [
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: _EpisodeSelectorContent(
            seriesId: item!.seriesId!,
            currentEpisodeId: item.id,
            currentMediaSourceId: ref.read(selectedMediaSourceProvider),
          ),
        ),
      ],
    );
  }

  void _showTimerDialog() {
    final options = [15, 30, 45, 60, 90, 120];
    _showRightPanel(
      title: '定时关闭',
      children: [
        ...options.map((minutes) => PanelOptionTile(
              label: '$minutes 分钟后关闭',
              leading: const Icon(Icons.timer_outlined),
              selected: false,
              onTap: () {
                Navigator.pop(context);
                _startSleepTimer(Duration(minutes: minutes));
              },
            )),
      ],
    );
  }

  void _startSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepTimer = Timer(duration, () {
      if (mounted) {
        _playerService.pause();
        AppToast.show(context, '已定时关闭播放', position: AppToastPosition.topCenter);
      }
      _sleepTimer = null;
    });
    ref.read(sleepTimerRemainingProvider.notifier).state = duration;
    AppToast.show(context, '已设置 ${duration.inMinutes} 分钟后关闭',
        position: AppToastPosition.topCenter);
  }

  void _showCoreSwitchDialog() {
    final currentCore = normalizePlayerCore(
        _sourceCoreOverride ?? ref.read(playerCoreProvider));
    final children = <Widget>[
      PanelOptionTile(
        label: 'ExoPlayer',
        subtitle: 'Android 原生，轻量稳定',
        selected: currentCore == 'exoPlayer',
        onTap: () {
          Navigator.pop(context);
          if (currentCore != 'exoPlayer') {
            _switchCore('exoPlayer');
          }
        },
      ),
      if (Platform.isAndroid)
        PanelOptionTile(
          label: 'MPV 原生',
          subtitle: 'libplayer.so 直调 libmpv，全格式/HDR/字幕',
          selected: currentCore == 'nativeMpv',
          onTap: () {
            Navigator.pop(context);
            if (currentCore != 'nativeMpv') {
              _switchCore('nativeMpv');
            }
          },
        ),
      if (!Platform.isAndroid)
        PanelOptionTile(
          label: 'MPV (media_kit)',
          subtitle: 'libmpv FFI，全格式/HDR/高级字幕',
          selected: currentCore == 'mpv',
          onTap: () {
            Navigator.pop(context);
            if (currentCore != 'mpv') {
              _switchCore('mpv');
            }
          },
        ),
    ];

    _showRightPanel(
      title: '切换播放器内核',
      children: children,
    );
  }

  Future<void> _switchCore(String core) async {
    final savedPosition = _playerService.position;
    // 飞牛/网盘 source-player 路径：mpv↔exo 的轨道 id 不通用，切核后
    // _applySourceTrackPreferences 只按 SourcePlayback 初始值重选（详情页
    // 传入的列表索引），内核菜单里选的字幕会被覆盖成「关闭」。这里在内核
    // 销毁前捕获当前实际选中轨道的身份（语言/标题），重建后在新内核轨道
    // 里按身份匹配恢复。Emby 路径已有 provider（MediaStream index）机制，
    // 身份恢复对其无副作用。
    final subtitleIdentity = _selectedTrackIdentity('text');
    final audioIdentity = _selectedTrackIdentity('audio');
    final normalizedCore = normalizePlayerCore(core);
    // 播放器界面修改只写当前媒体覆盖，不触碰系统默认内核。
    _sourceCoreOverride = normalizedCore;
    await PlaybackPrefsStore.instance.writePlayerCore(widget.itemId, normalizedCore);
    await _playerService.dispose();
    _playerService = VideoPlayerService();
    _activePlayerService = _playerService;
    _playerService.addListener(_onPlayerUpdate);
    await _initializePlayer(startPositionOverride: savedPosition);
    if (subtitleIdentity != null) {
      unawaited(_restoreTrackByIdentity('text', subtitleIdentity));
    }
    if (audioIdentity != null) {
      unawaited(_restoreTrackByIdentity('audio', audioIdentity));
    }
    if (mounted) {
      final normalized = normalizePlayerCore(core);
      final label = switch (normalized) {
        'mpv' => 'MPV (media_kit)',
        'nativeMpv' => 'MPV 原生',
        _ => 'ExoPlayer',
      };
      AppToast.show(context, '已切换到 $label',
          position: AppToastPosition.topCenter);
    }
  }

  /// 当前内核中实际选中的轨道身份（language/title），用于内核切换后按身份
  /// 在新内核轨道里恢复选择。无选中轨道返回 null。
  Map<String, dynamic>? _selectedTrackIdentity(String type) {
    for (final t in _playerService.tracksInfo) {
      final ty = '${t['type']}'.toLowerCase();
      final isTarget = type == 'text'
          ? (ty == 'text' || ty == 'bitmap')
          : ty == type;
      if (!isTarget) continue;
      if (t['isSelected'] == true || t['selected'] == true) {
        final language = t['language']?.toString().trim();
        final title = t['title']?.toString().trim();
        if ((language == null || language.isEmpty) &&
            (title == null || title.isEmpty)) {
          return null;
        }
        return {'language': language, 'title': title};
      }
    }
    return null;
  }

  bool _sameTrackIdentity(
      Map<String, dynamic> track, Map<String, dynamic> identity) {
    final lang = track['language']?.toString().trim().toLowerCase() ?? '';
    final title = track['title']?.toString().trim().toLowerCase() ?? '';
    final wantLang = (identity['language'] as String? ?? '').trim().toLowerCase();
    final wantTitle = (identity['title'] as String? ?? '').trim().toLowerCase();
    if (wantTitle.isNotEmpty && wantLang.isNotEmpty) {
      return title == wantTitle && lang == wantLang;
    }
    if (wantTitle.isNotEmpty) return title == wantTitle;
    if (wantLang.isNotEmpty) return lang == wantLang;
    return false;
  }

  /// 内核切换后按轨道身份（语言/标题）在新内核轨道里恢复选择：轮询直到
  /// 轨道就绪（mpv demux 大流可能要十几秒），匹配到就选中，就绪后仍未
  /// 匹配到则保持现状（不强制关闭字幕）。
  Future<void> _restoreTrackByIdentity(
      String type, Map<String, dynamic> identity) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (!mounted) return;
      final tracks = _playerService.tracksInfo.where((t) {
        final ty = '${t['type']}'.toLowerCase();
        final isTarget =
            type == 'text' ? (ty == 'text' || ty == 'bitmap') : ty == type;
        return isTarget && t['id'] != 'auto' && t['id'] != 'no';
      }).toList();
      if (tracks.isNotEmpty) {
        for (final t in tracks) {
          if (_sameTrackIdentity(t, identity)) {
            if (type == 'audio') {
              await _playerService.selectAudioTrack(t['id'].toString());
            } else {
              await _playerService.selectSubtitleTrack(t['id'].toString());
            }
            return;
          }
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  void _showLineSelector() {
    final server = ref.read(currentServerProvider);
    if (server == null || server.lines.length <= 1) {
      if (mounted) {
        AppToast.show(context, '当前只有一个可用线路',
            position: AppToastPosition.topCenter);
      }
      return;
    }
    _showRightPanel(
      title: '选择线路',
      children: [
        ...server.lines.asMap().entries.map((entry) {
          final idx = entry.key;
          final line = entry.value;
          return PanelOptionTile(
            leading: const Icon(Icons.route),
            label: line.name,
            selected: idx == server.activeLineIndex,
            onTap: () async {
              ref
                  .read(serverListProvider.notifier)
                  .setActiveLine(server.id, idx);
              // 同步更新 currentServerProvider
              final updatedServer = ref
                  .read(serverListProvider)
                  .firstWhere((s) => s.id == server.id);
              ref.read(currentServerProvider.notifier).state = updatedServer;
              Navigator.pop(context);
              // 重新初始化播放器以应用新线路
              final savedPosition = _playerService.position;
              await _playerService.dispose();
              _playerService = VideoPlayerService();
              _activePlayerService = _playerService;
              _playerService.addListener(_onPlayerUpdate);
              await _initializePlayer(startPositionOverride: savedPosition);
              if (mounted) {
                AppToast.show(context, '已切换到线路: ${line.name}',
                    position: AppToastPosition.topCenter);
              }
            },
          );
        }),
      ],
    );
  }

  void _showAspectRatioDialog() {
    final ratios = ['自适应', '铺满'];
    _showRightPanel(
      title: '画面比例',
      children: ratios
          .map((ratio) => PanelOptionTile(
                label: ratio,
                selected: ref.read(aspectRatioProvider) == ratio,
                onTap: () {
                  ref.read(aspectRatioProvider.notifier).state = ratio;
                  _playerService.setAspectRatio(ratio);
                  Navigator.pop(context);
                  AppToast.show(context, '画面比例: $ratio',
                      position: AppToastPosition.topCenter);
                },
              ))
          .toList(),
    );
  }
}

/// 滚动文字组件
