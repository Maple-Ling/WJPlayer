part of 'settings_screen.dart';

class PlayerSettingsScreen extends ConsumerWidget {
  const PlayerSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerCore = normalizePlayerCore(ref.watch(playerCoreProvider));
    final playbackSpeed = ref.watch(defaultPlaybackSpeedProvider);
    final hardwareDecoding = ref.watch(hardwareDecodingProvider);
    // 后台播放固定禁用，不再向用户暴露开关。
    final autoPlayNext = ref.watch(autoPlayNextProvider);
    final autoSkipSegments = ref.watch(autoSkipSegmentsProvider);
    final preloadEnabled = ref.watch(preloadEnabledProvider);
    // 多线程加载功能已从手机版删除。
    final strmDirectPlay = ref.watch(strmDirectPlayProvider);
    final watchedThreshold = ref.watch(watchedThresholdProvider);
    final exoLibass = ref.watch(exoLibassProvider);
    final subtitleBackground = ref.watch(subtitleBackgroundProvider);
    final mpvDolbyVisionFix = ref.watch(mpvDolbyVisionFixProvider);
    final dolbyAutoGpuNextSw = ref.watch(dolbyAutoGpuNextSwProvider);
    final externalMpvPath = ref.watch(externalMpvPathProvider);
    final gpuNextEnabled = ref.watch(gpuNextEnabledProvider);
    final pgsBlendMode = ref.watch(pgsBlendModeProvider);
    final anime4kEnabled =
        ref.watch(anime4KLevelProvider) != 'off';

    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.light
          ? AppColors.lightBackground
          : AppColors.darkBackground,
      appBar: AppBar(title: const Text('播放器设置')),
      body: TvListArea(
        id: 'settings_player',
        onBoundary: (_) => Navigator.of(context).pop(),
        child: body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          TvListTile(
            title: const Text('播放器内核'),
            subtitle: Text(switch (playerCore) {
              'mpv' => 'MPV (media_kit)',
              'nativeMpv' => 'MPV 原生',
              _ => 'ExoPlayer/AVPlayer',
            }),
            onTap: () => _showCoreSelector(context, ref),
          ),

          const Divider(),
          TvListTile(
            leading: const Icon(Icons.touch_app_outlined),
            title: const Text('交互设置'),
            subtitle: const Text('手势交互区、快进步长、双击与长按'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const InteractionSettingsScreen(),
              ),
            ),
          ),

          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '播放行为',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          TvListTile(
            title: const Text('默认播放速度'),
            subtitle: Text('${playbackSpeed}x'),
            onTap: () => _showSpeedSelector(context, ref),
          ),
          // 后台播放固定禁用。
          TdSwitchTile(
            title: const Text('自动播放下一集'),
            value: autoPlayNext,
            onChanged: (value) =>
                ref.read(autoPlayNextProvider.notifier).state = value,
          ),
          TdSwitchTile(
            title: const Text('自动跳过片头/片尾'),
            subtitle: const Text('联网识别剧集片头片尾，进入时显示跳过按钮'),
            value: autoSkipSegments,
            onChanged: (value) =>
                ref.read(autoSkipSegmentsProvider.notifier).state = value,
          ),
          TdSwitchTile(
            title: const Text('预加载'),
            subtitle: const Text('进入集/电影详情页时提前预热播放流，点播放更接近秒开（会消耗少量流量）'),
            value: preloadEnabled,
            onChanged: (value) =>
                ref.read(preloadEnabledProvider.notifier).state = value,
          ),
          // 多线程加载入口已删除。
          TdSwitchTile(
            title: const Text('STRM 直链播放'),
            subtitle:
                const Text('STRM 可获取直链时直接直链播放；部分服务器不兼容可能导致无法播放，仅在明确需要时开启'),
            value: strmDirectPlay,
            onChanged: (value) =>
                ref.read(strmDirectPlayProvider.notifier).state = value,
          ),
          /*
          TvListTile(
            title: const Text('宸茬湅鍒ゅ畾闃堝€?),
            subtitle: Text('$watchedThreshold%'),
            onTap: () => _showWatchedThresholdSelector(context, ref),
          ),

          */
          TvListTile(
            title: const Text('已看判定阈值'),
            subtitle: Text('$watchedThreshold%'),
            onTap: () => _showWatchedThresholdSelector(context, ref),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '音轨与字幕',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          TdSwitchTile(
            title: const Text('字幕黑色背景'),
            subtitle: const Text('为字幕添加半透明黑色背景'),
            value: subtitleBackground,
            onChanged: (value) =>
                ref.read(subtitleBackgroundProvider.notifier).state = value,
          ),
          if (isDesktopPlatform)
            TvListTile(
              title: const Text('图形字幕渲染模式 (PGS/SUP)'),
              subtitle: Text(_pgsBlendLabel(pgsBlendMode)),
              trailing: DropdownButton<String>(
                value: pgsBlendMode,
                onChanged: (v) {
                  if (v != null) {
                    ref.read(pgsBlendModeProvider.notifier).state = v;
                  }
                },
                items: const [
                  DropdownMenuItem(value: 'no', child: Text('覆盖层（默认）')),
                  DropdownMenuItem(value: 'video', child: Text('混合到视频')),
                  DropdownMenuItem(value: 'yes', child: Text('混合到输出帧')),
                ],
              ),
            ),

          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '解码与渲染',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          TdSwitchTile(
            title: const Text('硬件解码'),
            value: hardwareDecoding,
            onChanged: (value) =>
                ref.read(hardwareDecodingProvider.notifier).state = value,
          ),
          if (playerCore == 'mpv' || playerCore == 'nativeMpv')
            TdSwitchTile(
              title: const Text('Anime4K 超分'),
              subtitle: const Text('开启后使用 Anime4K 着色器提升动画画质（仅 MPV 内核支持）'),
              value: anime4kEnabled,
              onChanged: (value) => ref
                  .read(anime4KLevelProvider.notifier)
                  .state = value ? 'modeA' : 'off',
            ),
          if (playerCore == 'mpv' || playerCore == 'nativeMpv')
            TdSwitchTile(
              title: const Text('杜比视界自动切换软解'),
              subtitle: const Text(
                '播放杜比视界时自动启用 gpu-next 渲染 + 软件解码，修正硬解偏色',
              ),
              value: dolbyAutoGpuNextSw,
              onChanged: (value) =>
                  ref.read(dolbyAutoGpuNextSwProvider.notifier).state = value,
            ),

          // MPV特有设置
          if (playerCore == 'mpv') ...[
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'MPV 高级设置',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey,
                ),
              ),
            ),
            TdSwitchTile(
              title: const Text('自动修正杜比视界颜色'),
              subtitle: const Text('开启后软件修正杜比视界颜色偏差'),
              value: mpvDolbyVisionFix,
              onChanged: (value) =>
                  ref.read(mpvDolbyVisionFixProvider.notifier).state = value,
            ),
          ],

          // 原生MPV特有设置
          if (playerCore == 'nativeMpv') ...[
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '原生MPV 渲染设置',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey,
                ),
              ),
            ),
            TdSwitchTile(
              title: const Text('启用 gpu-next 渲染'),
              subtitle:
                  const Text('使用 libplacebo/gpu-next 渲染（需要 SurfaceView 支持）'),
              value: gpuNextEnabled,
              onChanged: (value) =>
                  ref.read(gpuNextEnabledProvider.notifier).state = value,
            ),
          ],

          // 实验性功能
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '实验性功能',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          if (isDesktopPlatform) ...[
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '外部播放器',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey,
                ),
              ),
            ),
            TvListTile(
              title: const Text('外部 MPV 路径'),
              subtitle: Text(
                externalMpvPath.isEmpty ? '点击选择外部 MPV 可执行文件' : externalMpvPath,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: externalMpvPath.isEmpty
                  ? const Icon(Icons.chevron_right)
                  : IconButton(
                      tooltip: '清除路径',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        ref.read(externalMpvPathProvider.notifier).state = '';
                      },
                    ),
              onTap: () => _pickExternalMpvPath(context, ref),
            ),
          ],
          if (!isDesktopPlatform && playerCore == 'exoPlayer')
            TdSwitchTile(
              title: const Text('EXO 启用 ASS 原生渲染'),
              subtitle: const Text(
                  '默认关闭：开启后视频帧全部经 GL 管线处理，HEVC 高码率可能严重卡顿；'
                  '关闭时 ASS 字幕自动转 SRT 播放。需要原生 ASS 效果建议用 MPV 内核'),
              value: exoLibass,
              onChanged: (value) =>
                  ref.read(exoLibassProvider.notifier).state = value,
            ),
        ],
      ),),

    );
  }

  void _showCoreSelector(BuildContext context, WidgetRef ref) {
    // ExoPlayer 与原生 MPV 是 Android 专属（平台通道 + libplayer.so）；iOS(Flutter)
    // 无原生播放插件，只有 media_kit(mpv)；桌面同样只有 media_kit(mpv)。
    final children = <Widget>[
      if (Platform.isAndroid)
        const RadioListTile<String>(
          title: Text('ExoPlayer'),
          subtitle: Text('轻量稳定，适合大多数场景'),
          value: 'exoPlayer',
        ),
      if (Platform.isAndroid)
        const RadioListTile<String>(
          title: Text('MPV 原生'),
          subtitle: Text('通过 libplayer.so 直接调用 libmpv，支持 HDR/着色器/PGS/SUP'),
          value: 'nativeMpv',
        ),
      if (!Platform.isAndroid)
        const RadioListTile<String>(
          title: Text('MPV (media_kit)'),
          subtitle: Text('libmpv FFI，支持 HDR/着色器/PGS/SUP'),
          value: 'mpv',
        ),
    ];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('播放器内核'),
        content: RadioGroup<String>(
          groupValue: normalizePlayerCore(ref.read(playerCoreProvider)),
          onChanged: (value) {
            if (value != null) {
              ref.read(playerCoreProvider.notifier).state =
                  normalizePlayerCore(value);
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }

  void _showSpeedSelector(BuildContext context, WidgetRef ref) {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('默认播放速度'),
        content: RadioGroup<double>(
          groupValue: ref.read(defaultPlaybackSpeedProvider),
          onChanged: (value) {
            if (value != null) {
              ref.read(defaultPlaybackSpeedProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: speeds
                .map((speed) => RadioListTile<double>(
                      title: Text('${speed}x'),
                      value: speed,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  void _showWatchedThresholdSelector(BuildContext context, WidgetRef ref) {
    final thresholds = [75, 80, 85, 90, 95];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('已看判定阈值'),
        content: RadioGroup<int>(
          groupValue: ref.read(watchedThresholdProvider),
          onChanged: (value) {
            if (value != null) {
              ref.read(watchedThresholdProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: thresholds
                .map((threshold) => RadioListTile<int>(
                      title: Text('$threshold%'),
                      subtitle: Text('播放进度达到 $threshold% 后视为已看'),
                      value: threshold,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  void _showAudioLanguageSelector(BuildContext context, WidgetRef ref) {
    final languages = {
      'jpn': '日语',
      'chi': '中文',
      'eng': '英语',
      'kor': '韩语',
    };
    final current = ref.read(preferredAudioLanguageProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('首选音频语言'),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(preferredAudioLanguageProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: languages.entries
                .map((entry) => RadioListTile<String>(
                      title: Text(entry.value),
                      value: entry.key,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  String _pgsBlendLabel(String mode) {
    switch (mode) {
      case 'video':
        return '混合到视频分辨率 · 覆盖层闪现时可试此项';
      case 'yes':
        return '混合到输出帧 · 最不易闪但可能略糊';
      default:
        return '覆盖层渲染（默认）· 性能最好';
    }
  }

  void _showSubtitleFontSelector(BuildContext context, WidgetRef ref) {
    final fonts = ['默认', '思源黑体', '微软雅黑', '苹方'];
    final current = ref.read(subtitleFontProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('字幕字体'),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(subtitleFontProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: fonts
                .map((font) => RadioListTile<String>(
                      title: Text(font),
                      value: font,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  Future<void> _pickExternalMpvPath(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择外部 MPV 可执行文件',
      allowMultiple: false,
      type: Platform.isWindows ? FileType.custom : FileType.any,
      allowedExtensions: Platform.isWindows ? const ['exe'] : null,
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) {
      return;
    }

    ref.read(externalMpvPathProvider.notifier).state = path;
    if (!context.mounted) {
      return;
    }
    AppToast.show(context, '已更新外部 MPV 路径');
  }
}

/// 弹幕设置页
