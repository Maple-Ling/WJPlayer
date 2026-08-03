part of 'player_screen.dart';

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  late VideoPlayerService _playerService;
  bool _showRemaining = false;
  bool _isLongPressing = false;
  bool _isSliderDragging = false;
  double? _sliderDragValue;
  Timer? _longPressTimer;
  Timer? _gestureHintTimer;
  String? _seekHint;
  Timer? _sleepTimer;
  Timer? _sourceProgressTimer;
  Map<String, dynamic>? _sourcePlayMetadata;
  SourcePlayback? _activeSourcePlay;
  bool _sourceProgressWriteInFlight = false;
  int _lastSourceProgressSecond = -1;
  bool _sourceCompletionReported = false;
  String? _sourceCoreOverride;
  double? _initialVideoAspectRatio;
  // 当前 Anime4K 超分档位（off/modeA/…/modeAC），供顶栏面板高亮选中项。
  String _anime4kMode = 'off';
  // 本次播放是否已上报「看过」到同步服务，避免 onStop 多次触发导致重复写入。
  bool _didScrobble = false;

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
    // 任何模式都保持视频自身比例；“拉伸”仅保留为历史值，避免默认变形。
    final safeMode = mode == '拉伸' || mode == '全屏' ? '自适应' : mode;
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
    WidgetsBinding.instance.addObserver(this);
    _activeState = this;
    _activeSourcePlay = widget.sourcePlay;
    _sourceCoreOverride =
        widget.sourcePlay?.playerCoreOverride ?? widget.playerCoreOverride;
    _introSkip =
        IntroSkipController(service: ref.read(introSkipServiceProvider));
    _playerService = VideoPlayerService();
    _playerService.addListener(_onPlayerUpdate);
    unawaited(_playerService.hydrateSystemControls());

    // Delay initialization when using nativeMpv to allow SurfaceView to be created
    // This ensures the AndroidView is rendered before we try to use the SurfaceView
    final coreString = normalizePlayerCore(
        _sourceCoreOverride ?? ref.read(playerCoreProvider));
    if (coreString == 'nativeMpv') {
      // Use addPostFrameCallback to delay until after the first frame is built
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initializePlayer();
      });
    } else {
      _initializePlayer();
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
    final videoStream = mediaSource?.primaryVideoStream;
    _initialVideoAspectRatio = (videoStream?.width != null &&
            videoStream?.height != null &&
            videoStream!.width! > 0 &&
            videoStream.height! > 0)
        ? videoStream.width! / videoStream.height!
        : null;

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

    _playerService.setSubtitleSize(ref.read(subtitleSizeProvider));
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
      final effectiveStart = startPosition ?? play.resumePosition;
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
      await _playerService.play();
      _startSourceProgressReporting(sp);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      // 外挂字幕（ani-rss 等源带回）：加载首条作默认；内封由内核原生读取。
      if (play.subtitles.isNotEmpty) {
        try {
          await _playerService.loadLibassSubtitle(play.subtitles.first.url);
        } catch (_) {}
      }
      unawaited(_applySourceTrackPreferences(sp));
      _playerService.setSubtitleSize(ref.read(subtitleSizeProvider));
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
    final subtitleIndex = sp.preferredSubtitleListIndex;

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
    if (sp.server.hidden) return; // 隐藏服务器不记播放记录
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
            incrementPlayCount: _lastSourceProgressSecond < 0,
            force: force,
          );
    } catch (_) {
      // 本地记录失败不能中断来源播放和服务端进度回传。
    }
  }

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
      logger.w('Player', 'MPV 无可用字幕轨道 - 设置pending等待轨道就绪');
      final mpvAdapter = _playerService.adapter;
      if (mpvAdapter is MpvPlayerAdapter) {
        mpvAdapter.setPendingSubtitle(
          target.codec?.toLowerCase() ?? 'ass',
          title: target.displayTitle ?? target.title,
        );
      }
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
    _checkSkipOpening();
    _introSkip.onPosition(_playerService.position);
    final sp = _activeSourcePlay;
    if (sp != null &&
        _playerService.isCompleted &&
        !_sourceCompletionReported) {
      _sourceCompletionReported = true;
      unawaited(_reportSourceProgress(sp, force: true));
    }
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

  void _checkSkipOpening() {
    final openingStart = ref.read(skipOpeningStartProvider);
    final openingEnd = ref.read(skipOpeningEndProvider);
    final autoSkip = ref.read(skipAutoModeProvider);
    if (openingStart <= 0 || openingEnd <= 0 || openingEnd <= openingStart) {
      return;
    }

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
    final openingEnd = ref.read(skipOpeningEndProvider);
    _playerService.seekTo(Duration(seconds: openingEnd));
    setState(() => _showSkipButton = false);
    _skipButtonTimer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      final sp = _activeSourcePlay;
      if (sp != null) unawaited(_reportSourceProgress(sp, force: true));
      _playerService.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    unawaited(_playerService.restoreSystemBrightness());
    _playerService.dispose();
    _longPressTimer?.cancel();
    _gestureHintTimer?.cancel();
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _playerService.toggleControls,
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
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 24),
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
                    if (_seekHint != null) _buildSeekHint(),
                    if (_isLongPressing) _buildLongPressIndicator(),
                    if (_playerService.isDragging &&
                        _playerService.isScrubbingPosition)
                      _buildDragIndicator(),
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
              if (_playerService.showControls && !_playerService.isLocked)
                Positioned.fill(child: _buildControlsOverlay(item)),
              // 锁定态：解锁按钮与未锁定时的锁定按钮同位置（左侧居中），且随控制栏计时自动隐藏，不再长驻。
              if (_playerService.isLocked && _playerService.showControls)
                Positioned(
                  left: 4,
                  top: 0,
                  bottom: 0,
                  child: SafeArea(child: Center(child: _lockButton())),
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
            ],
          );
        },
      ),
    );
  }

  Widget _buildVideoArea() {
    final videoWidget = _playerService.buildVideo();
    final danmakuItems = ref.watch(loadedDanmakuProvider);
    final danmakuEnabled = ref.watch(danmakuEnabledProvider);
    final danmakuOpacity = ref.watch(danmakuOpacityProvider);
    final danmakuFontSize = ref.watch(danmakuFontSizeProvider);
    final danmakuSpeed = ref.watch(danmakuSpeedProvider);
    final danmakuDensity = ref.watch(danmakuDensityProvider);
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
        final delayedPosition = _playerService.position -
            Duration(milliseconds: (danmakuDelay * 1000).round());
        return Stack(
          fit: StackFit.expand,
          children: [
            if (isMpv)
              Positioned.fill(child: videoWidget)
            else
              Positioned.fromRect(rect: contentRect, child: videoWidget),
            if (danmakuEnabled && danmakuItems.isNotEmpty)
              Positioned.fill(
                child: DanmakuOverlay(
                  items: danmakuItems,
                  position: delayedPosition,
                  isPlaying: _playerService.isPlaying,
                  playbackRate: _playerService.speed,
                  opacity: danmakuOpacity,
                  fontSizeFactor: danmakuFontSize,
                  speedFactor: danmakuSpeed,
                  densityFactor: danmakuDensity,
                  displayArea: danmakuDisplayArea,
                  stroke: danmakuStroke,
                  fontFamily: danmakuFontFamily,
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
      _playerService.onDragEnd(DragEndDetails());
    }
    _gestureIsZoom = false;
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
    if (tapX < screenWidth / 3) {
      _playerService.seekBy(Duration(seconds: -step));
      _showSeekHint('«  -${step}s');
    } else if (tapX > screenWidth * 2 / 3) {
      _playerService.seekBy(Duration(seconds: step));
      _showSeekHint('+${step}s  »');
    } else {
      _playerService.togglePlay();
    }
  }

  void _showSeekHint(String text) {
    _gestureHintTimer?.cancel();
    setState(() => _seekHint = text);
    _gestureHintTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _seekHint = null);
    });
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
    IconData icon;
    double value;

    if (_playerService.activeVerticalAction == 'brightness') {
      label = '亮度';
      icon = Icons.brightness_high;
      value = _playerService.brightness;
    } else {
      label = '音量';
      icon = Icons.volume_up;
      value = _playerService.volume;
    }

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 32),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 100,
              child: LinearProgressIndicator(
                value: value,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${(value * 100).toInt()}%',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hintBar(String text, {IconData? icon}) {
    return Align(
      // 拖动/长按提示靠近画面上方，避开中央画面与底部进度控件。
      alignment: const Alignment(0, -0.78),
      child: IgnorePointer(
        child: Container(
          constraints: const BoxConstraints(minWidth: 100, maxWidth: 280),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, color: Colors.white, size: 17),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLongPressIndicator() =>
      _hintBar(_formatSpeed(ref.read(longPressSpeedProvider)),
          icon: Icons.fast_forward_rounded);

  Widget _buildSeekHint() => _hintBar(_seekHint ?? '');

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
              Expanded(child: Center(child: _buildCenterControls())),
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
        // 右侧倍速条。
        Positioned(
          right: 24,
          top: 0,
          bottom: 0,
          child: SafeArea(child: Center(child: _buildSpeedBar())),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
            iconSize: 20,
            tooltip: '返回',
            onPressed: () => context.pop(),
          ),
          // 标题：只占左侧；超长才匀速滚动，右侧留给操作按钮。
          Expanded(
            child: _MarqueeText(
              text: item?.name ?? widget.itemId,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.fast_forward_rounded, color: Colors.white),
            iconSize: 20,
            tooltip: '跳过片头/片尾',
            onPressed: _showSkipDialog,
          ),
          IconButton(
            icon: const Icon(Icons.aspect_ratio_rounded, color: Colors.white),
            iconSize: 20,
            tooltip: '画面比例',
            onPressed: _showAspectRatioDialog,
          ),
          IconButton(
            icon: Icon(
              ref.watch(hardwareDecodingProvider)
                  ? Icons.memory_rounded
                  : Icons.slow_motion_video_rounded,
              color: Colors.white,
            ),
            iconSize: 20,
            tooltip: ref.watch(hardwareDecodingProvider) ? '硬件解码' : '软件解码',
            onPressed: _toggleHardwareDecoding,
          ),
          IconButton(
            icon: const Icon(Icons.timer_outlined, color: Colors.white),
            iconSize: 20,
            tooltip: '定时关闭',
            onPressed: _showTimerDialog,
          ),
          IconButton(
            icon: const Icon(Icons.info_outline_rounded, color: Colors.white),
            iconSize: 20,
            tooltip: '详情信息',
            onPressed: _showStats,
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
          _BottomBarAction(
            icon: Icons.skip_next_rounded,
            label: '下一集',
            onTap: _playNext,
          ),
          const Spacer(),
          _BottomBarAction(
            icon: Icons.memory_rounded,
            label: '内核',
            onTap: _showCoreSwitchDialog,
          ),
          _BottomBarAction(
            icon: Icons.route_rounded,
            label: '线路',
            onTap: _showLineSelector,
          ),
          _BottomBarAction(
            icon: Icons.manage_search_rounded,
            label: '弹幕搜索',
            onTap: _showDanmakuSearch,
          ),
          _BottomBarAction(
            icon: Icons.chat_bubble_outline_rounded,
            label: '弹幕',
            onTap: _showDanmakuSettings,
          ),
          _BottomBarAction(
            icon: Icons.subtitles_outlined,
            label: '字幕',
            onTap: _showSubtitleSettings,
          ),
          _BottomBarAction(
            icon: Icons.audiotrack_rounded,
            label: '音轨',
            onTap: _showAudioSettings,
          ),
          _BottomBarAction(
            icon: Icons.playlist_play_rounded,
            label: '选集',
            onTap: () => _showEpisodeSelector(item),
          ),
        ],
      ),
    );
  }

  Widget _buildDragIndicator() {
    final preview = _playerService.isScrubbingPosition
        ? _playerService.dragPreviewPosition
        : _playerService.position;
    final delta = preview - _playerService.position;
    final sign = delta.isNegative ? '-' : '+';
    final magnitude = delta.isNegative ? -delta : delta;
    return _hintBar(
      '${_formatDuration(_playerService.position)} $sign${_formatDuration(magnitude)} / ${_formatDuration(_playerService.duration)}',
      icon: delta.isNegative
          ? Icons.fast_rewind_rounded
          : Icons.fast_forward_rounded,
    );
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
    if (current?.hidden == true) return; // 隐藏服务器不记播放记录
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
            incrementPlayCount: incrementPlayCount,
            force: force,
          );
      _maybeWriteBackCrossServer(
        scopeKey: scopeKey,
        item: item,
        record: record,
        force: force,
      );
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

  void _showSkipDialog() {
    _showRightPanel(
      title: '跳过片头',
      children: [
        _SkipDialog(currentPosition: _playerService.position),
      ],
    );
  }

  void _toggleOrientation() {
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

  void _showDanmakuSearch() {
    final item = ref.read(currentPlayingItemProvider);
    _showRightPanel(
      title: '搜索弹幕',
      children: [
        DanmakuSearchContent(item: item),
      ],
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
    final normalizedCore = normalizePlayerCore(core);
    if (_activeSourcePlay != null || widget.playerCoreOverride != null) {
      _sourceCoreOverride = normalizedCore;
    } else {
      ref.read(playerCoreProvider.notifier).state = normalizedCore;
    }
    await _playerService.dispose();
    _playerService = VideoPlayerService();
    _activePlayerService = _playerService;
    _playerService.addListener(_onPlayerUpdate);
    await _initializePlayer(startPositionOverride: savedPosition);
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
    final ratios = ['原始', '铺满'];
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
