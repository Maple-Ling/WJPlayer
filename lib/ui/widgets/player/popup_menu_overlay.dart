import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const Color popupMenuBlue = Color(0xFF4A7BD0);
const Color popupMenuSelectedBlue = Color(0x664A7BD0);
const Color popupMenuSurface = Color(0xEB0C1016);

/// 播放器二级/三级菜单 ID。
enum PopupMenuId {
  danmaku,
  danmakuSettings,
  speed,
  skip,
  aspect,
  info,
  aggregate,
  core,
  line,
  audio,
  subtitle,
  episodes,
}

class PopupAggregateSource {
  const PopupAggregateSource({
    required this.id,
    required this.name,
    required this.resolution,
    required this.metadata,
  });

  final String id;
  final String name;
  final String resolution;
  final String metadata;
}

class PopupEpisodeOption {
  const PopupEpisodeOption({
    required this.index,
    required this.name,
    required this.path,
    this.selected = false,
  });

  final int index;
  final String name;
  final String path;
  final bool selected;
}

class PopupLineOption {
  const PopupLineOption({
    required this.label,
    required this.sub,
  });

  final String label;
  final String sub;
}

class PopupSkipRecord {
  const PopupSkipRecord({
    required this.type,
    required this.time,
  });

  final String type;
  final String time;
}

/// 所有二级菜单统一使用毛玻璃表面。
class PopupMenuShell extends StatelessWidget {
  const PopupMenuShell({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: popupMenuSurface,
              border: Border.all(
                color: Colors.white.withOpacity(0.12),
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 30,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class PopupMenuTitle extends StatelessWidget {
  const PopupMenuTitle({
    super.key,
    required this.title,
  });

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: 8,
        right: 8,
        top: 2,
        bottom: 8,
      ),
      child: Text(
        title,
        style: TextStyle(
          color: Colors.white.withOpacity(0.6),
          fontSize: 10.5,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class PopupMenuCheck extends StatelessWidget {
  const PopupMenuCheck({
    super.key,
    required this.selected,
  });

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? popupMenuBlue : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected
              ? popupMenuBlue
              : Colors.white.withOpacity(0.4),
          width: 1.5,
        ),
      ),
      child: selected
          ? Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            )
          : null,
    );
  }
}

class PopupMenuSwitch extends StatelessWidget {
  const PopupMenuSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 30,
        height: 16,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: value
              ? popupMenuBlue
              : Colors.white.withOpacity(0.2),
          borderRadius: BorderRadius.circular(9),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 180),
          alignment: value
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Container(
            width: 12,
            height: 12,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

class PopupMenuPill extends StatelessWidget {
  const PopupMenuPill({
    super.key,
    required this.label,
    this.selected = false,
    this.showCheck = false,
    this.sub,
    this.trailing,
    this.onTap,
    this.onLongPress,
  });

  final String label;
  final bool selected;
  final bool showCheck;
  final String? sub;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    Widget? end = trailing;
    if (end == null && showCheck) {
      end = PopupMenuCheck(selected: selected);
    }
    if (end == null && sub != null) {
      end = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 150),
        child: Text(
          sub!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
          style: TextStyle(
            color: Colors.white.withOpacity(0.5),
            fontSize: 11,
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 9,
        ),
        decoration: BoxDecoration(
          color: selected
              ? popupMenuSelectedBlue
              : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                ),
              ),
            ),
            if (end != null) ...[
              const SizedBox(width: 10),
              end,
            ],
          ],
        ),
      ),
    );
  }
}

class PopupMenuSwitchPill extends StatelessWidget {
  const PopupMenuSwitchPill({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuPill(
      label: label,
      trailing: PopupMenuSwitch(
        value: value,
        onChanged: onChanged,
      ),
      onTap: () => onChanged(!value),
    );
  }
}

class PopupMenuSliderRow extends StatelessWidget {
  const PopupMenuSliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.75),
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 5,
                activeTrackColor: popupMenuBlue,
                inactiveTrackColor: Colors.white.withOpacity(0.18),
                thumbColor: Colors.white,
                overlayColor: Colors.white.withOpacity(0.1),
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 5,
                ),
                overlayShape: const RoundSliderOverlayShape(
                  overlayRadius: 10,
                ),
              ),
              child: Slider(
                value: value.clamp(0.0, 1.0).toDouble(),
                min: 0,
                max: 1,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(
              '${(value * 100).round()}%',
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PopupMiniButton extends StatelessWidget {
  const PopupMiniButton({
    super.key,
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: popupMenuBlue.withOpacity(0.35),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFF9DBDF5),
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}

class AggregateSearchCard extends StatelessWidget {
  const AggregateSearchCard({
    super.key,
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final PopupAggregateSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 150,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? popupMenuBlue.withOpacity(0.3)
              : Colors.white.withOpacity(0.06),
          border: Border.all(
            color: selected
                ? popupMenuBlue
                : Colors.white.withOpacity(0.1),
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: popupMenuBlue.withOpacity(0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: popupMenuBlue,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    source.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: popupMenuBlue.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    source.resolution,
                    style: const TextStyle(
                      color: Color(0xFF9DBDF5),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              source.metadata,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withOpacity(0.55),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PopupAggregateSearchMenu extends StatelessWidget {
  const PopupAggregateSearchMenu({
    super.key,
    required this.sources,
    required this.selectedSource,
    required this.onSourceSelected,
  });

  final List<PopupAggregateSource> sources;
  final String selectedSource;
  final ValueChanged<String> onSourceSelected;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: [
            for (var i = 0; i < sources.length; i++) ...[
              AggregateSearchCard(
                source: sources[i],
                selected: sources[i].id == selectedSource,
                onTap: () => onSourceSelected(sources[i].id),
              ),
              if (i < sources.length - 1) const SizedBox(width: 10),
            ],
          ],
        ),
      ),
    );
  }
}

class PopupDanmakuMenu extends StatelessWidget {
  const PopupDanmakuMenu({
    super.key,
    required this.enabled,
    required this.onEnabledChanged,
    required this.onSearch,
    required this.onOpenSettings,
  });

  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onSearch;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '弹幕选项'),
        PopupMenuSwitchPill(
          label: '弹幕开关',
          value: enabled,
          onChanged: onEnabledChanged,
        ),
        PopupMenuPill(
          label: '搜索弹幕',
          trailing: PopupMiniButton(label: '搜索', onTap: onSearch),
          onTap: onSearch,
        ),
        PopupMenuPill(
          label: '弹幕设置',
          sub: '›',
          onTap: onOpenSettings,
        ),
      ],
    );
  }
}

class PopupDanmakuSettingsMenu extends StatelessWidget {
  const PopupDanmakuSettingsMenu({
    super.key,
    required this.opacity,
    required this.fontSize,
    required this.speed,
    required this.density,
    required this.area,
    required this.delay,
    required this.deduplication,
    required this.onOpacityChanged,
    required this.onFontSizeChanged,
    required this.onSpeedChanged,
    required this.onDensityChanged,
    required this.onAreaChanged,
    required this.onDelayChanged,
    required this.onDeduplicationChanged,
  });

  final double opacity;
  final double fontSize;
  final double speed;
  final double density;
  final double area;
  final double delay;
  final bool deduplication;
  final ValueChanged<double> onOpacityChanged;
  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<double> onSpeedChanged;
  final ValueChanged<double> onDensityChanged;
  final ValueChanged<double> onAreaChanged;
  final ValueChanged<double> onDelayChanged;
  final ValueChanged<bool> onDeduplicationChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '弹幕设置'),
        PopupMenuSliderRow(
          label: '不透明度',
          value: opacity,
          onChanged: onOpacityChanged,
        ),
        PopupMenuSliderRow(
          label: '弹幕字体',
          value: fontSize,
          onChanged: onFontSizeChanged,
        ),
        PopupMenuSliderRow(
          label: '弹幕速度',
          value: speed,
          onChanged: onSpeedChanged,
        ),
        PopupMenuSliderRow(
          label: '弹幕密度',
          value: density,
          onChanged: onDensityChanged,
        ),
        PopupMenuSliderRow(
          label: '弹幕区域',
          value: area,
          onChanged: onAreaChanged,
        ),
        PopupMenuSliderRow(
          label: '弹幕延迟',
          value: delay,
          onChanged: onDelayChanged,
        ),
        PopupMenuSwitchPill(
          label: '弹幕去重',
          value: deduplication,
          onChanged: onDeduplicationChanged,
        ),
      ],
    );
  }
}

class PopupSpeedMenu extends StatelessWidget {
  const PopupSpeedMenu({
    super.key,
    required this.selectedSpeed,
    required this.onSpeedSelected,
  });

  final double selectedSpeed;
  final ValueChanged<double> onSpeedSelected;

  static const values = <double>[0.5, 1.0, 1.5, 2.0, 2.5, 3.0];

  String _label(double speed) => speed == 1.0 ? '正常 (1.0x)' : '${speed}x';

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '播放倍速'),
        for (final speed in values)
          PopupMenuPill(
            label: _label(speed),
            selected: (selectedSpeed - speed).abs() < 0.01,
            showCheck: true,
            onTap: () => onSpeedSelected(speed),
          ),
      ],
    );
  }
}

class PopupSkipMenu extends StatelessWidget {
  const PopupSkipMenu({
    super.key,
    required this.introTime,
    required this.outroTime,
    required this.autoSkip,
    required this.onRecordIntro,
    required this.onRecordOutro,
    required this.onClearIntro,
    required this.onClearOutro,
    required this.onAutoSkipChanged,
  });

  final String? introTime;
  final String? outroTime;
  final bool autoSkip;
  final VoidCallback onRecordIntro;
  final VoidCallback onRecordOutro;
  final VoidCallback onClearIntro;
  final VoidCallback onClearOutro;
  final ValueChanged<bool> onAutoSkipChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '跳过片头片尾'),
        PopupMenuPill(
          label: '跳过片头',
          sub: introTime == null ? '点击记录当前' : '已记录 $introTime',
          onTap: onRecordIntro,
          onLongPress: onClearIntro,
        ),
        PopupMenuPill(
          label: '跳过片尾',
          sub: outroTime == null ? '点击记录当前' : '已记录 $outroTime',
          onTap: onRecordOutro,
          onLongPress: onClearOutro,
        ),
        PopupMenuSwitchPill(
          label: '自动跳过',
          value: autoSkip,
          onChanged: onAutoSkipChanged,
        ),
      ],
    );
  }
}

class PopupAspectRatioMenu extends StatelessWidget {
  const PopupAspectRatioMenu({
    super.key,
    required this.selectedAspect,
    required this.onAspectSelected,
  });

  final String selectedAspect;
  final ValueChanged<String> onAspectSelected;

  static const values = <MapEntry<String, String>>[
    MapEntry('自动', '自适应'),
    MapEntry('原始', '原始'),
    MapEntry('16:9', '16:9'),
    MapEntry('4:3', '4:3'),
    MapEntry('21:9', '21:9'),
    MapEntry('铺满', '裁切铺满'),
    MapEntry('拉伸', '拉伸填充'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '画面比例'),
        for (final value in values)
          PopupMenuPill(
            label: value.value,
            selected: selectedAspect == value.key,
            showCheck: true,
            onTap: () => onAspectSelected(value.key),
          ),
      ],
    );
  }
}

class PopupMediaInfoMenu extends StatelessWidget {
  const PopupMediaInfoMenu({
    super.key,
    required this.title,
    required this.encoder,
    required this.resolution,
    required this.frameRate,
    required this.bitrate,
  });

  final String title;
  final String encoder;
  final String resolution;
  final String frameRate;
  final String bitrate;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '媒体信息'),
        PopupMenuPill(label: '标题', sub: title),
        PopupMenuPill(label: '编码器', sub: encoder),
        PopupMenuPill(label: '分辨率', sub: resolution),
        PopupMenuPill(label: '帧率', sub: frameRate),
        PopupMenuPill(label: '码率', sub: bitrate),
      ],
    );
  }
}

class PopupCoreMenu extends StatelessWidget {
  const PopupCoreMenu({
    super.key,
    required this.cores,
    required this.selectedCore,
    required this.onCoreSelected,
  });

  final List<String> cores;
  final String selectedCore;
  final ValueChanged<String> onCoreSelected;

  String _label(String core) {
    switch (core) {
      case 'exoPlayer':
        return 'ExoPlayer';
      case 'nativeMpv':
        return 'MPV 原生';
      case 'mpv':
        return 'MPV';
      default:
        return core;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '播放器内核'),
        for (final core in cores)
          PopupMenuPill(
            label: _label(core),
            selected: core == selectedCore,
            showCheck: true,
            onTap: () => onCoreSelected(core),
          ),
      ],
    );
  }
}

class PopupLineMenu extends StatelessWidget {
  const PopupLineMenu({
    super.key,
    required this.lines,
    required this.selectedLine,
    required this.onLineSelected,
  });

  final List<PopupLineOption> lines;
  final String selectedLine;
  final ValueChanged<String> onLineSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '线路选择'),
        for (final line in lines)
          PopupMenuPill(
            label: line.label,
            sub: line.sub,
            selected: line.label == selectedLine,
            onTap: () => onLineSelected(line.label),
          ),
        if (lines.isEmpty) const PopupMenuPill(label: '暂无可用线路'),
      ],
    );
  }
}

class PopupTrackMenu extends StatelessWidget {
  const PopupTrackMenu({
    super.key,
    required this.title,
    required this.tracks,
    required this.selectedTrack,
    required this.onTrackSelected,
    this.externalSubtitle = false,
    this.onExternalSubtitle,
  });

  final String title;
  final List<String> tracks;
  final String selectedTrack;
  final ValueChanged<String> onTrackSelected;
  final bool externalSubtitle;
  final VoidCallback? onExternalSubtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PopupMenuTitle(title: title),
        for (final track in tracks)
          PopupMenuPill(
            label: track,
            selected: track == selectedTrack,
            showCheck: true,
            onTap: () => onTrackSelected(track),
          ),
        if (externalSubtitle)
          PopupMenuPill(
            label: '外挂字幕',
            trailing: PopupMiniButton(
              label: '加载',
              onTap: onExternalSubtitle ?? () {},
            ),
            onTap: onExternalSubtitle,
          ),
        if (tracks.isEmpty) const PopupMenuPill(label: '暂无可用轨道'),
      ],
    );
  }
}

class PopupEpisodesMenu extends StatelessWidget {
  const PopupEpisodesMenu({
    super.key,
    required this.episodes,
    required this.selectedEpisode,
    required this.onEpisodeSelected,
  });

  final List<PopupEpisodeOption> episodes;
  final int selectedEpisode;
  final ValueChanged<int> onEpisodeSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '选集'),
        if (episodes.isEmpty)
          const PopupMenuPill(label: '暂无可用选集'),
        if (episodes.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final episode in episodes)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onEpisodeSelected(episode.index),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: episode.selected ||
                              selectedEpisode == episode.index
                          ? popupMenuSelectedBlue
                          : Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'EP${episode.index} ${episode.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: episode.selected ||
                                selectedEpisode == episode.index
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// 可定位的播放器菜单覆盖层。聚合卡片以进度条为锚点居中，其余菜单以按钮为锚点。
class PopupMenuOverlay extends StatelessWidget {
  const PopupMenuOverlay({
    super.key,
    required this.activeMenu,
    required this.anchorRect,
    required this.progressRect,
    required this.onClose,
    required this.onOpenMenu,
    required this.danmakuEnabled,
    required this.danmakuDeduplication,
    required this.autoSkip,
    required this.danmakuOpacity,
    required this.danmakuFontSize,
    required this.danmakuSpeed,
    required this.danmakuDensity,
    required this.danmakuArea,
    required this.danmakuDelay,
    required this.speed,
    required this.aspectRatio,
    required this.selectedSource,
    required this.selectedCore,
    required this.selectedLine,
    required this.selectedAudioTrack,
    required this.selectedSubtitleTrack,
    required this.selectedEpisode,
    required this.episodes,
    required this.introTime,
    required this.outroTime,
    required this.currentPositionLabel,
    required this.mediaTitle,
    required this.encoder,
    required this.resolution,
    required this.frameRate,
    required this.bitrate,
    required this.sources,
    required this.cores,
    required this.lines,
    required this.audioTracks,
    required this.subtitleTracks,
    required this.onDanmakuChanged,
    required this.onDanmakuDeduplicationChanged,
    required this.onAutoSkipChanged,
    required this.onDanmakuOpacityChanged,
    required this.onDanmakuFontSizeChanged,
    required this.onDanmakuSpeedChanged,
    required this.onDanmakuDensityChanged,
    required this.onDanmakuAreaChanged,
    required this.onDanmakuDelayChanged,
    required this.onSearchDanmaku,
    required this.onPlaybackRateChanged,
    required this.onAspectRatioChanged,
    required this.onSourceChanged,
    required this.onCoreChanged,
    required this.onLineChanged,
    required this.onAudioTrackChanged,
    required this.onSubtitleChanged,
    required this.onEpisodeChanged,
    required this.onSkipTimeRecorded,
    required this.onClearIntro,
    required this.onClearOutro,
    required this.onExternalSubtitleRequested,
  });

  final PopupMenuId? activeMenu;
  final Rect? anchorRect;
  final Rect? progressRect;
  final VoidCallback onClose;
  final ValueChanged<PopupMenuId> onOpenMenu;

  final bool danmakuEnabled;
  final bool danmakuDeduplication;
  final bool autoSkip;
  final double danmakuOpacity;
  final double danmakuFontSize;
  final double danmakuSpeed;
  final double danmakuDensity;
  final double danmakuArea;
  final double danmakuDelay;
  final double speed;
  final String aspectRatio;
  final String selectedSource;
  final String selectedCore;
  final String selectedLine;
  final String selectedAudioTrack;
  final String selectedSubtitleTrack;
  final int selectedEpisode;
  final List<PopupEpisodeOption> episodes;
  final String? introTime;
  final String? outroTime;
  final String currentPositionLabel;

  final String mediaTitle;
  final String encoder;
  final String resolution;
  final String frameRate;
  final String bitrate;

  final List<PopupAggregateSource> sources;
  final List<String> cores;
  final List<PopupLineOption> lines;
  final List<String> audioTracks;
  final List<String> subtitleTracks;

  final ValueChanged<bool> onDanmakuChanged;
  final ValueChanged<bool> onDanmakuDeduplicationChanged;
  final ValueChanged<bool> onAutoSkipChanged;
  final ValueChanged<double> onDanmakuOpacityChanged;
  final ValueChanged<double> onDanmakuFontSizeChanged;
  final ValueChanged<double> onDanmakuSpeedChanged;
  final ValueChanged<double> onDanmakuDensityChanged;
  final ValueChanged<double> onDanmakuAreaChanged;
  final ValueChanged<double> onDanmakuDelayChanged;
  final VoidCallback onSearchDanmaku;
  final ValueChanged<double> onPlaybackRateChanged;
  final ValueChanged<String> onAspectRatioChanged;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<String> onCoreChanged;
  final ValueChanged<String> onLineChanged;
  final ValueChanged<String> onAudioTrackChanged;
  final ValueChanged<String> onSubtitleChanged;
  final ValueChanged<int> onEpisodeChanged;
  final ValueChanged<PopupSkipRecord> onSkipTimeRecorded;
  final VoidCallback onClearIntro;
  final VoidCallback onClearOutro;
  final VoidCallback onExternalSubtitleRequested;

  Widget _menu() {
    switch (activeMenu!) {
      case PopupMenuId.danmaku:
        return PopupDanmakuMenu(
          enabled: danmakuEnabled,
          onEnabledChanged: onDanmakuChanged,
          onSearch: onSearchDanmaku,
          onOpenSettings: () => onOpenMenu(PopupMenuId.danmakuSettings),
        );
      case PopupMenuId.danmakuSettings:
        return PopupDanmakuSettingsMenu(
          opacity: danmakuOpacity,
          fontSize: danmakuFontSize,
          speed: danmakuSpeed,
          density: danmakuDensity,
          area: danmakuArea,
          delay: danmakuDelay,
          deduplication: danmakuDeduplication,
          onOpacityChanged: onDanmakuOpacityChanged,
          onFontSizeChanged: onDanmakuFontSizeChanged,
          onSpeedChanged: onDanmakuSpeedChanged,
          onDensityChanged: onDanmakuDensityChanged,
          onAreaChanged: onDanmakuAreaChanged,
          onDelayChanged: onDanmakuDelayChanged,
          onDeduplicationChanged: onDanmakuDeduplicationChanged,
        );
      case PopupMenuId.speed:
        return PopupSpeedMenu(
          selectedSpeed: speed,
          onSpeedSelected: onPlaybackRateChanged,
        );
      case PopupMenuId.skip:
        return PopupSkipMenu(
          introTime: introTime,
          outroTime: outroTime,
          autoSkip: autoSkip,
          onRecordIntro: () => onSkipTimeRecorded(
            PopupSkipRecord(
              type: '片头',
              time: currentPositionLabel,
            ),
          ),
          onRecordOutro: () => onSkipTimeRecorded(
            PopupSkipRecord(
              type: '片尾',
              time: currentPositionLabel,
            ),
          ),
          onClearIntro: onClearIntro,
          onClearOutro: onClearOutro,
          onAutoSkipChanged: onAutoSkipChanged,
        );
      case PopupMenuId.aspect:
        return PopupAspectRatioMenu(
          selectedAspect: aspectRatio,
          onAspectSelected: onAspectRatioChanged,
        );
      case PopupMenuId.info:
        return PopupMediaInfoMenu(
          title: mediaTitle,
          encoder: encoder,
          resolution: resolution,
          frameRate: frameRate,
          bitrate: bitrate,
        );
      case PopupMenuId.aggregate:
        return PopupAggregateSearchMenu(
          sources: sources,
          selectedSource: selectedSource,
          onSourceSelected: onSourceChanged,
        );
      case PopupMenuId.core:
        return PopupCoreMenu(
          cores: cores,
          selectedCore: selectedCore,
          onCoreSelected: onCoreChanged,
        );
      case PopupMenuId.line:
        return PopupLineMenu(
          lines: lines,
          selectedLine: selectedLine,
          onLineSelected: onLineChanged,
        );
      case PopupMenuId.audio:
        return PopupTrackMenu(
          title: '音频轨道',
          tracks: audioTracks,
          selectedTrack: selectedAudioTrack,
          onTrackSelected: onAudioTrackChanged,
        );
      case PopupMenuId.subtitle:
        return PopupTrackMenu(
          title: '字幕轨道',
          tracks: subtitleTracks,
          selectedTrack: selectedSubtitleTrack,
          onTrackSelected: onSubtitleChanged,
          externalSubtitle: true,
          onExternalSubtitle: onExternalSubtitleRequested,
        );
      case PopupMenuId.episodes:
        return PopupEpisodesMenu(
          episodes: episodes,
          selectedEpisode: selectedEpisode,
          onEpisodeSelected: onEpisodeChanged,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final menu = activeMenu;
    if (menu == null) return const SizedBox.shrink();

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
        CustomSingleChildLayout(
          delegate: _PopupMenuPositionDelegate(
            aggregate: menu == PopupMenuId.aggregate,
            anchorRect: anchorRect,
            progressRect: progressRect,
          ),
          child: PopupMenuShell(child: _menu()),
        ),
      ],
    );
  }
}

class _PopupMenuPositionDelegate extends SingleChildLayoutDelegate {
  const _PopupMenuPositionDelegate({
    required this.aggregate,
    required this.anchorRect,
    required this.progressRect,
  });

  final bool aggregate;
  final Rect? anchorRect;
  final Rect? progressRect;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : 360.0;
    final height = constraints.maxHeight.isFinite
        ? constraints.maxHeight
        : 640.0;
    final availableWidth = math.max(1.0, width - 24);
    final availableHeight = math.max(1.0, height - 24);

    if (aggregate) {
      final aggregateWidth = math.min(availableWidth, width * 0.92);
      return BoxConstraints(
        minWidth: aggregateWidth,
        maxWidth: aggregateWidth,
        maxHeight: availableHeight,
      );
    }

    final maxWidth = math.min(280.0, availableWidth);
    return BoxConstraints(
      minWidth: math.min(180.0, maxWidth),
      maxWidth: maxWidth,
      maxHeight: availableHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 12.0;
    double left;
    double top;

    if (aggregate) {
      final anchor = progressRect;
      left = anchor == null
          ? (size.width - childSize.width) / 2
          : anchor.center.dx - childSize.width / 2;
      top = anchor == null
          ? (size.height - childSize.height) / 2
          : anchor.top - childSize.height - 10;
      if (top < margin && anchor != null) {
        top = anchor.bottom + 10;
      }
    } else if (anchorRect == null) {
      left = (size.width - childSize.width) / 2;
      top = (size.height - childSize.height) / 2;
    } else {
      left = anchorRect!.center.dx - childSize.width / 2;
      top = anchorRect!.top < size.height / 2
          ? anchorRect!.bottom + 8
          : anchorRect!.top - childSize.height - 8;
    }

    final maxLeft = math.max(margin, size.width - childSize.width - margin);
    final maxTop = math.max(margin, size.height - childSize.height - margin);
    return Offset(
      left.clamp(margin, maxLeft).toDouble(),
      top.clamp(margin, maxTop).toDouble(),
    );
  }

  @override
  bool shouldRelayout(covariant _PopupMenuPositionDelegate oldDelegate) {
    return aggregate != oldDelegate.aggregate ||
        anchorRect != oldDelegate.anchorRect ||
        progressRect != oldDelegate.progressRect;
  }
}
