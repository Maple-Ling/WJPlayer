import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/media_providers.dart';
import '../../../core/providers/playback_providers.dart';
import '../../../core/providers/unified_resource_provider.dart';
import '../../../core/sources/unified_media_adapter.dart';
import '../../../core/utils/track_preference.dart';
import '../common/danmaku_search_widget.dart';
import '../common/playback_resource_card.dart';

const Color popupMenuBlue = Color(0xFF4A7BD0);
const Color popupMenuSelectedBlue = Color(0x664A7BD0);
const Color popupMenuSurface = Color(0xEB0C1016);

/// 播放器二级/三级菜单 ID。
enum PopupMenuId {
  danmaku,
  danmakuSettings,
  danmakuSearch,
  speed,
  skip,
  aspect,
  info,
  aggregate,
  core,
  line,
  audio,
  subtitle,
  subtitleSettings,
  episodes,
}

class PopupAggregateSource {
  const PopupAggregateSource({
    required this.id,
    required this.name,
    required this.resolution,
    required this.metadata,
    this.dynamicRange,
    this.codec,
    this.size,
    this.bitrate,
  });

  final String id;
  final String name;
  final String resolution;
  final String metadata;
  final String? dynamicRange;
  final String? codec;
  final int? size;
  final int? bitrate;
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
              // 菜单内容超高（弹幕设置等长菜单）时可在屏内下滑查看，
              // 高度上限与 _PopupMenuPositionDelegate 的可用高度对齐。
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.max(120.0, MediaQuery.sizeOf(context).height - 24),
                ),
                child: SingleChildScrollView(
                  child: child,
                ),
              ),
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
    this.min = 0,
    this.max = 1,
    this.valueLabel,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final String? valueLabel;

  @override
  Widget build(BuildContext context) {
    final effectiveMax = math.max(min, max);
    final clamped = value.clamp(min, effectiveMax).toDouble();
    final labelText = valueLabel ?? '${(value * 100).round()}%';
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
                value: clamped,
                min: min,
                max: effectiveMax,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(
              labelText,
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
    return SizedBox(
      width: 250,
      child: PlaybackResourceCard(
        serverName: source.name,
        isCurrent: selected,
        resolution: source.resolution.isEmpty ? null : source.resolution,
        dynamicRange: source.dynamicRange,
        codec: source.codec ?? (source.metadata.isEmpty ? null : source.metadata),
        size: source.size,
        bitrate: source.bitrate,
        onTap: onTap,
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
    this.onSearchMore,
  });

  final List<PopupAggregateSource> sources;
  final String selectedSource;
  final ValueChanged<String> onSourceSelected;
  final VoidCallback? onSearchMore;

  @override
  Widget build(BuildContext context) {
    final visibleSources = sources.take(3).toList(growable: false);
    if (visibleSources.isEmpty) {
      return SizedBox(
        height: 52,
        child: Center(
          child: TextButton.icon(
            onPressed: onSearchMore,
            icon: const Icon(Icons.search_rounded, size: 18),
            label: const Text('搜索更多资源'),
          ),
        ),
      );
    }

    // 资源卡直接位于播放器进度条锚点，不再叠加“菜单胶囊”内边距/背景。
    return SizedBox(
      height: 155,
      width: double.infinity,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: visibleSources.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final source = visibleSources[index];
          return AggregateSearchCard(
            source: source,
            selected: source.id == selectedSource,
            onTap: () => onSourceSelected(source.id),
          );
        },
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

class PopupDanmakuSettingsMenu extends StatefulWidget {
  const PopupDanmakuSettingsMenu({
    super.key,
    required this.opacity,
    required this.fontSize,
    required this.speed,
    required this.density,
    required this.area,
    required this.delay,
    required this.deduplication,
    required this.dedupWindow,
    required this.floatingColorful,
    required this.floatingWhite,
    required this.scrollColorful,
    required this.scrollWhite,
    required this.bottomColorful,
    required this.bottomWhite,
    required this.stroke,
    required this.onOpacityChanged,
    required this.onFontSizeChanged,
    required this.onSpeedChanged,
    required this.onDensityChanged,
    required this.onAreaChanged,
    required this.onDelayChanged,
    required this.onDeduplicationChanged,
    required this.onDedupWindowChanged,
    required this.onFloatingColorfulChanged,
    required this.onFloatingWhiteChanged,
    required this.onScrollColorfulChanged,
    required this.onScrollWhiteChanged,
    required this.onBottomColorfulChanged,
    required this.onBottomWhiteChanged,
    required this.onStrokeChanged,
  });

  final double opacity;
  final double fontSize;
  final double speed;
  final double density;
  final double area;
  final double delay;
  final bool deduplication;
  final double dedupWindow;
  final bool floatingColorful;
  final bool floatingWhite;
  final bool scrollColorful;
  final bool scrollWhite;
  final bool bottomColorful;
  final bool bottomWhite;
  final bool stroke;
  final ValueChanged<double> onOpacityChanged;
  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<double> onSpeedChanged;
  final ValueChanged<double> onDensityChanged;
  final ValueChanged<double> onAreaChanged;
  final ValueChanged<double> onDelayChanged;
  final ValueChanged<bool> onDeduplicationChanged;
  final ValueChanged<double> onDedupWindowChanged;
  final ValueChanged<bool> onFloatingColorfulChanged;
  final ValueChanged<bool> onFloatingWhiteChanged;
  final ValueChanged<bool> onScrollColorfulChanged;
  final ValueChanged<bool> onScrollWhiteChanged;
  final ValueChanged<bool> onBottomColorfulChanged;
  final ValueChanged<bool> onBottomWhiteChanged;
  final ValueChanged<bool> onStrokeChanged;

  @override
  State<PopupDanmakuSettingsMenu> createState() =>
      _PopupDanmakuSettingsMenuState();
}

class _PopupDanmakuSettingsMenuState extends State<PopupDanmakuSettingsMenu> {
  bool _topExpanded = false;
  bool _bottomExpanded = false;
  bool _scrollExpanded = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '弹幕设置'),
        PopupMenuSliderRow(
          label: '不透明度',
          value: w.opacity,
          onChanged: w.onOpacityChanged,
        ),
        PopupMenuSliderRow(
          label: '弹幕字体',
          value: w.fontSize,
          onChanged: w.onFontSizeChanged,
        ),
        PopupMenuSliderRow(
          label: '弹幕速度',
          value: w.speed,
          onChanged: w.onSpeedChanged,
        ),
        PopupMenuSliderRow(
          label: '弹幕密度',
          value: w.density,
          onChanged: w.onDensityChanged,
        ),
        PopupMenuSliderRow(
          label: '弹幕区域',
          value: w.area,
          onChanged: w.onAreaChanged,
        ),
        PopupMenuSliderRow(
          label: '弹幕延迟',
          value: w.delay,
          onChanged: w.onDelayChanged,
        ),
        PopupMenuSwitchPill(
          label: '弹幕去重',
          value: w.deduplication,
          onChanged: w.onDeduplicationChanged,
        ),
        if (w.deduplication)
          PopupMenuSliderRow(
            label: '去重窗口',
            value: w.dedupWindow,
            min: 1,
            max: 30,
            valueLabel: '${w.dedupWindow.round()}秒',
            onChanged: w.onDedupWindowChanged,
          ),
        // 顶部弹幕（type 5）：> 展开彩色/白色两个开关；两个都关则顶部弹幕不显示。
        PopupMenuPill(
          label: '顶部弹幕',
          sub: _topExpanded ? '˅' : '›',
          onTap: () => setState(() => _topExpanded = !_topExpanded),
        ),
        if (_topExpanded) ...[
          PopupMenuSwitchPill(
            label: '彩色弹幕',
            value: w.floatingColorful,
            onChanged: w.onFloatingColorfulChanged,
          ),
          PopupMenuSwitchPill(
            label: '白色弹幕',
            value: w.floatingWhite,
            onChanged: w.onFloatingWhiteChanged,
          ),
        ],
        // 底部弹幕（type 4）：> 展开彩色/白色两个开关；两个都关则底部弹幕不显示。
        PopupMenuPill(
          label: '底部弹幕',
          sub: _bottomExpanded ? '˅' : '›',
          onTap: () => setState(() => _bottomExpanded = !_bottomExpanded),
        ),
        if (_bottomExpanded) ...[
          PopupMenuSwitchPill(
            label: '彩色弹幕',
            value: w.bottomColorful,
            onChanged: w.onBottomColorfulChanged,
          ),
          PopupMenuSwitchPill(
            label: '白色弹幕',
            value: w.bottomWhite,
            onChanged: w.onBottomWhiteChanged,
          ),
        ],
        // 滚动弹幕：> 展开彩色/白色两个开关；两个都关则滚动弹幕不显示。
        PopupMenuPill(
          label: '滚动弹幕',
          sub: _scrollExpanded ? '˅' : '›',
          onTap: () => setState(() => _scrollExpanded = !_scrollExpanded),
        ),
        if (_scrollExpanded) ...[
          PopupMenuSwitchPill(
            label: '彩色弹幕',
            value: w.scrollColorful,
            onChanged: w.onScrollColorfulChanged,
          ),
          PopupMenuSwitchPill(
            label: '白色弹幕',
            value: w.scrollWhite,
            onChanged: w.onScrollWhiteChanged,
          ),
        ],
        PopupMenuSwitchPill(
          label: '描边文字',
          value: w.stroke,
          onChanged: w.onStrokeChanged,
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

  /// 比例选项只保留自适应 / 裁切铺满。
  static const values = <MapEntry<String, String>>[
    MapEntry('自动', '自适应'),
    MapEntry('铺满', '裁切铺满'),
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

class PopupMediaInfoMenu extends StatefulWidget {
  const PopupMediaInfoMenu({
    super.key,
    required this.title,
    this.encoder,
    this.resolution,
    this.frameRate,
    this.bitrate,
    this.unifiedResource,
    this.selectedAudioTrack,
    this.selectedSubtitleTrack,
  });

  final String title;
  final String? encoder;
  final String? resolution;
  final String? frameRate;
  final String? bitrate;
  final UnifiedMediaResource? unifiedResource;
  final String? selectedAudioTrack;
  final String? selectedSubtitleTrack;

  @override
  State<PopupMediaInfoMenu> createState() => _PopupMediaInfoMenuState();
}

class _PopupMediaInfoMenuState extends State<PopupMediaInfoMenu> {
  late final PageController _pageController;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages();
    final page = _page.clamp(0, pages.length - 1).toInt();
    if (page != _page) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _page = page);
      });
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '媒体信息'),
        SizedBox(
          height: 184,
          child: PageView.builder(
            controller: _pageController,
            itemCount: pages.length,
            onPageChanged: (value) => setState(() => _page = value),
            itemBuilder: (_, index) => _PopupInfoPage(items: pages[index]),
          ),
        ),
        if (pages.length > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '上一页',
                visualDensity: VisualDensity.compact,
                onPressed: page == 0 ? null : () => _goTo(page - 1),
                icon: const Icon(Icons.chevron_left_rounded, size: 20),
              ),
              Text(
                '${page + 1}/${pages.length}',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.58),
                  fontSize: 11,
                ),
              ),
              IconButton(
                tooltip: '下一页',
                visualDensity: VisualDensity.compact,
                onPressed: page == pages.length - 1
                    ? null
                    : () => _goTo(page + 1),
                icon: const Icon(Icons.chevron_right_rounded, size: 20),
              ),
            ],
          ),
      ],
    );
  }

  void _goTo(int page) {
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  List<List<_PopupInfoItem>> _pages() {
    final resource = widget.unifiedResource;
    final video = resource?.video;
    // 兼容详情页流 API（codec_name/real_frame_rate…）与 Emby MediaStream
    // （codec/realFrameRate…）两种命名，保证与详情页底部媒体信息栏一致。
    dynamic pick(List<String> keys) {
      for (final key in keys) {
        final value = video?[key];
        if (value != null && value.toString().isNotEmpty) return value;
      }
      return null;
    }

    final enc = video != null
        ? _videoDisplay(video)
        : widget.encoder ?? '未知';
    final res = video != null ? _resolution(video) : widget.resolution ?? '未知';
    final fps = video != null ? _frameRate(video) : widget.frameRate ?? '未知';
    final bitrate = video != null ? _bitrate(video) : widget.bitrate ?? '未知';
    final size = resource != null ? _formatSize(resource.size) : '';

    final basic = <_PopupInfoItem>[
      _PopupInfoItem('标题', widget.title),
      _PopupInfoItem('编码器', enc),
      _PopupInfoItem('封装格式',
          pick(['container', 'format', 'file_format'])?.toString() ?? '未知'),
      _PopupInfoItem('分辨率', res),
      _PopupInfoItem('SAR',
          pick(['sample_aspect_ratio', 'sar'])?.toString() ?? '未知'),
      _PopupInfoItem('DAR',
          pick(['aspect_ratio', 'display_aspect_ratio', 'dar'])?.toString() ??
              '未知'),
      _PopupInfoItem('帧率', fps),
      _PopupInfoItem('码率', bitrate),
      _PopupInfoItem('像素格式',
          pick(['pixel_format', 'pix_fmt', 'pixelFormat'])?.toString() ?? '未知'),
      _PopupInfoItem('位深度',
          pick(['bit_depth', 'bitDepth', 'colorDepth'])?.toString() ?? '未知'),
      _PopupInfoItem('色彩范围',
          pick(['color_range', 'colorRange', 'range'])?.toString() ?? '未知'),
      _PopupInfoItem('色彩空间',
          pick(['color_space', 'colorSpace'])?.toString() ?? '未知'),
      _PopupInfoItem('色彩矩阵',
          pick(['color_matrix', 'colorMatrix'])?.toString() ?? '未知'),
      _PopupInfoItem('色域/传输',
          pick(['color_transfer', 'colorTransfer', 'transfer'])?.toString() ??
              '未知'),
      _PopupInfoItem('HDR类型',
          pick(['video_range_type', 'videoRangeType', 'hdr_type'])
                  ?.toString() ??
              pick(['video_range', 'videoRange', 'dynamic_range'])?.toString() ??
              '未知'),
      _PopupInfoItem('GOP长度',
          pick(['gop_size', 'gopSize', 'gop'])?.toString() ?? '未知'),
      _PopupInfoItem('时间基',
          pick(['time_base', 'timeBase'])?.toString() ?? '未知'),
      if (size.isNotEmpty) _PopupInfoItem('媒体体积', size),
    ];

    final tracks = <_PopupInfoItem>[
      _PopupInfoItem('当前音频', _audioLabel()),
      _PopupInfoItem('当前字幕', _subtitleLabel()),
      if (resource != null)
        for (var i = 0; i < resource.audios.length; i++)
          _PopupInfoItem(
            '音频 ${i + 1}',
            _trackLabel(resource.audios[i], resource.isFeiniu),
          ),
      if (resource != null)
        for (var i = 0; i < resource.subtitles.length; i++)
          _PopupInfoItem(
            '字幕 ${i + 1}',
            _trackLabel(resource.subtitles[i], resource.isFeiniu),
          ),
    ];
    return [basic, tracks];
  }

  String _formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 2)} ${units[unit]}';
  }

  String _audioLabel() {
    final selected = widget.selectedAudioTrack?.trim();
    if (selected != null && selected.isNotEmpty) return selected;
    final resource = widget.unifiedResource;
    if (resource == null || resource.audios.isEmpty) return '无音轨';
    return _trackLabel(resource.audios.first, resource.isFeiniu);
  }

  String _subtitleLabel() {
    final selected = widget.selectedSubtitleTrack?.trim();
    if (selected != null && selected.isNotEmpty) return selected;
    final resource = widget.unifiedResource;
    if (resource == null || resource.subtitles.isEmpty) return '无字幕';
    return _trackLabel(resource.subtitles.first, resource.isFeiniu);
  }

  String _videoDisplay(Map<String, dynamic> video) {
    final codec = (video['codec_name'] ?? video['codec'] ?? '未知编码')
        .toString()
        .toUpperCase();
    final colorDepth = video['bit_depth'] ?? video['colorDepth'];
    final colorDepthLabel =
        colorDepth != null && colorDepth.toString().isNotEmpty
            ? ' ${colorDepth}bit'
            : '';
    final hdrType = video['video_range_type'] ?? video['hdrType'];
    final hdrTypeLabel =
        hdrType != null && hdrType.toString().isNotEmpty ? ' ($hdrType)' : '';
    return '$codec$hdrTypeLabel$colorDepthLabel';
  }

  String _resolution(Map<String, dynamic> video) {
    final w = video['width'] as int?;
    final h = video['height'] as int?;
    if (w == null || h == null || w <= 0 || h <= 0) return '未知';
    return '${w}×$h';
  }

  String _frameRate(Map<String, dynamic> video) {
    final fps = (video['real_frame_rate'] ?? video['realFrameRate'] ??
            video['average_frame_rate'] ?? video['nominalFrameRate'])
        as num?;
    if (fps == null || fps <= 0) return '未知';
    final value = fps.toDouble();
    return value == value.roundToDouble()
        ? '${value.round()} fps'
        : '${value.toStringAsFixed(2)} fps';
  }

  String _bitrate(Map<String, dynamic> video) {
    final bps = video['bitrate'] as num?;
    if (bps == null || bps <= 0) return '未知';
    final value = bps.toDouble();
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)} Mbps';
    return '${(value / 1000).toStringAsFixed(0)} kbps';
  }

  String _trackLabel(Map<String, dynamic> track, bool isFeiniu) {
    if (isFeiniu) {
      final name = track['displayName'] as String? ??
          track['title'] as String? ??
          track['language'] as String?;
      if (name == null || name.isEmpty) {
        final index = (track['index'] as int? ?? 0) + 1;
        return 'Track $index';
      }
      final codec = track['codec'] as String?;
      final codecLabel = codec != null ? ' ($codec)' : '';
      final channels = track['channels'] as int?;
      final channelLabel = channels != null ? ', $channels CH' : '';
      return '$name$codecLabel$channelLabel';
    }
    final index = (track['index'] as int? ?? 0) + 1;
    final displayName = track['displayName'] as String? ??
        track['language'] as String?;
    final codec = track['codec'] as String?;
    final channels = track['channels'] as int?;
    final bitrate = track['bitrate'] as int?;
    final parts = <String>[
      'Track $index',
      if (displayName != null) displayName,
    ];
    final info = <String>[
      if (codec != null) codec,
      if (channels != null) '${channels}ch',
      if (bitrate != null && bitrate > 0) '${bitrate ~/ 1000}kbps',
    ];
    if (info.isNotEmpty) parts.add(info.join(', '));
    return parts.join(' · ');
  }
}

class _PopupInfoItem {
  const _PopupInfoItem(this.label, this.value);

  final String label;
  final String value;
}

class _PopupInfoPage extends StatelessWidget {
  const _PopupInfoPage({required this.items});

  final List<_PopupInfoItem> items;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      physics: const BouncingScrollPhysics(),
      itemCount: items.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        color: Colors.white.withOpacity(0.09),
      ),
      itemBuilder: (_, index) {
        final item = items[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 58,
                child: Text(
                  item.label,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.55),
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        );
      },
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
        return '原生 MPV';
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
    this.onOpenSettings,
    this.unifiedResource,
    this.preferQualityAudio = false,
  });

  final String title;
  final List<String> tracks;
  final String selectedTrack;
  final ValueChanged<String> onTrackSelected;
  final bool externalSubtitle;
  final VoidCallback? onExternalSubtitle;
  final VoidCallback? onOpenSettings;
  final UnifiedMediaResource? unifiedResource;

  /// 音频菜单排序策略：true = 音质优先（MPV 内核），false = 兼容优先（ExoPlayer）。
  /// 与详情页音频按钮、播放器默认选轨同一套排序（track_preference.audioCodecRank）。
  final bool preferQualityAudio;

  @override
  Widget build(BuildContext context) {
    // 优先使用 unifiedResource 的轨道列表，回退到 tracks 参数
    final effectiveTracks = _buildTrackList();
    final empty = effectiveTracks.isEmpty && tracks.isEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PopupMenuTitle(title: title),
        for (final track in effectiveTracks)
          PopupMenuPill(
            label: track.label,
            selected: track.label == selectedTrack,
            showCheck: true,
            onTap: () => onTrackSelected(track.label),
          ),
        // 字幕菜单提供「关闭字幕」（音频无此概念）：走 onTrackSelected('关闭字幕')
        // → state._switchSubtitleTrackByName 的 deselect 分支；无选中字幕时高亮
        // （selectedTrack 为空串，或刚点过关闭暂存的 '关闭字幕'）。
        if (title == '字幕轨道')
          PopupMenuPill(
            label: '关闭字幕',
            selected: selectedTrack.isEmpty || selectedTrack == '关闭字幕',
            showCheck: true,
            onTap: () => onTrackSelected('关闭字幕'),
          ),
        // 字幕设置二级菜单入口：大小 / 上下位置。
        if (title == '字幕轨道' && onOpenSettings != null)
          PopupMenuPill(
            label: '字幕设置',
            trailing: const Icon(Icons.chevron_right_rounded,
                size: 18, color: Colors.white54),
            onTap: onOpenSettings,
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
        if (empty) const PopupMenuPill(label: '暂无可用轨道'),
      ],
    );
  }

  List<PopupTrackOption> _buildTrackList() {
    final unified = unifiedResource;
    if (unified != null) {
      final isAudio = title == '音频轨道';
      final trackList = isAudio ? unified.audios : unified.subtitles;
      if (trackList.isNotEmpty) {
        // 音频菜单按当前内核策略排序（兼容优先/音质优先），与详情页同步；
        // 字幕保持原顺序。排序只影响展示顺序，选中态按 label 匹配不受影响。
        final ordered = isAudio
            ? sortAudioIndexes(
                trackList.length,
                (i) => audioCodecOf(trackList[i]),
                preferQuality: preferQualityAudio,
              ).map((i) => trackList[i]).toList()
            : trackList;
        return ordered.map((t) => PopupTrackOption(
          label: unifiedTrackLabel(t, unified.isFeiniu),
        )).toList();
      }
    }
    // 回退到原始 tracks 列表
    return tracks.map((t) => PopupTrackOption(label: t)).toList();
  }
}

/// 字幕设置二级菜单：当前字幕的大小（0.5x~2.0x）与上下位置（0~100%）。
class PopupSubtitleSettingsMenu extends StatelessWidget {
  const PopupSubtitleSettingsMenu({
    super.key,
    required this.subtitleSize,
    required this.subtitlePosition,
    required this.onSubtitleSizeChanged,
    required this.onSubtitlePositionChanged,
  });

  final double subtitleSize;
  final double subtitlePosition;
  final ValueChanged<double> onSubtitleSizeChanged;
  final ValueChanged<double> onSubtitlePositionChanged;

  @override
  Widget build(BuildContext context) {
    Widget row({
      required String label,
      required double value,
      required double min,
      required double max,
      required String display,
      required ValueChanged<double> onChanged,
    }) {
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
                  value: value.clamp(min, max).toDouble(),
                  min: min,
                  max: max,
                  onChanged: onChanged,
                ),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                display,
                textAlign: TextAlign.right,
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '字幕设置'),
        row(
          label: '大小',
          value: subtitleSize,
          min: 0.5,
          max: 2.0,
          display: '${subtitleSize.toStringAsFixed(1)}x',
          onChanged: onSubtitleSizeChanged,
        ),
        row(
          label: '位置',
          value: subtitlePosition,
          min: 0,
          max: 1,
          display: '${(subtitlePosition.clamp(0.0, 1.0) * 100).round()}%',
          onChanged: onSubtitlePositionChanged,
        ),
      ],
    );
  }
}

/// 统一的轨道显示标签（播放器菜单 / 媒体信息共用，与详情页流信息一致）。
/// 供 PopupTrackMenu 与播放器状态层共同使用，保证"选中态字符串"同源可比。
String unifiedTrackLabel(Map<String, dynamic> track, bool isFeiniu) {
  if (isFeiniu) {
    final name = track['displayName'] as String? ??
        track['title'] as String? ??
        track['language'] as String?;
    if (name == null || name.isEmpty) {
      final index = (track['index'] as int? ?? 0) + 1;
      return 'Track $index';
    }
    // codec 兼容归一化 key（normalizeMediaStream 输出 codec_name）。
    final codec = (track['codec'] ?? track['codec_name']) as String?;
    final codecLabel = codec != null ? ' ($codec)' : '';
    final channels = track['channels'] as int?;
    final channelLabel = channels != null ? ', $channels CH' : '';
    return '$name$codecLabel$channelLabel';
  } else {
    final index = (track['index'] as int? ?? 0) + 1;
    final displayName = track['displayName'] as String? ??
        track['language'] as String?;
    final codec = (track['codec'] ?? track['codec_name']) as String?;
    final channels = track['channels'] as int?;
    final bitrate = track['bitrate'] as int?;
    final parts = <String>[
      'Track $index',
      if (displayName != null) displayName,
    ];
    final info = <String>[
      if (codec != null) codec,
      if (channels != null) '${channels}ch',
      if (bitrate != null && bitrate > 0) '${bitrate ~/ 1000}kbps',
    ];
    if (info.isNotEmpty) parts.add(info.join(', '));
    return parts.join(' · ');
  }
}

class PopupTrackOption {
  const PopupTrackOption({required this.label});
  final String label;
}

class PopupEpisodesMenu extends StatefulWidget {
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
  State<PopupEpisodesMenu> createState() => _PopupEpisodesMenuState();
}

class _PopupEpisodesMenuState extends State<PopupEpisodesMenu> {
  late final PageController _pageController;
  int _page = 0;

  int get _pageCount =>
      widget.episodes.isEmpty ? 1 : (widget.episodes.length + 4) ~/ 5;

  @override
  void initState() {
    super.initState();
    final selectedIndex = widget.episodes.indexWhere(
      (episode) =>
          episode.selected || episode.index == widget.selectedEpisode,
    );
    _page = selectedIndex < 0 ? 0 : selectedIndex ~/ 5;
    _pageController = PageController(initialPage: _page);
  }

  @override
  void didUpdateWidget(covariant PopupEpisodesMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 注意：播放器每次 rebuild 都会传入新的 episodes 列表实例（直链播放时
    // _overlayEpisodesFor 每次重建列表），若按实例比较会反复 jumpToPage 把
    // 用户手动翻的页拉回选中集页，导致"无法翻页"。
    // 这里只对比内容（长度/选中集）是否真正变化。
    final contentChanged = oldWidget.episodes.length != widget.episodes.length ||
        oldWidget.selectedEpisode != widget.selectedEpisode;
    if (contentChanged) {
      final selectedIndex = widget.episodes.indexWhere(
        (episode) =>
            episode.selected || episode.index == widget.selectedEpisode,
      );
      final nextPage = selectedIndex < 0 ? 0 : selectedIndex ~/ 5;
      _page = nextPage.clamp(0, _pageCount - 1).toInt();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(_page);
        }
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.episodes.isEmpty) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PopupMenuTitle(title: '选集'),
          PopupMenuPill(label: '暂无可用选集'),
        ],
      );
    }

    // 一页 5 集的精确高度：行高（Padding 7×2 + 12px 文本行 ≈ 31px）× 5 + 分隔线 4 ≈ 159px。
    // 原固定 220px 底部冗余约 60px 空白、比例失调；现按内容量精算，并在极端矮屏
    // （横屏）按视口比例收缩，最低保留 2 行高度，避免面板过高或溢出。
    final screenHeight = MediaQuery.sizeOf(context).height;
    final panelHeight = math.max(
      66.0,
      math.min(159.0, screenHeight * 0.26),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopupMenuTitle(title: '选集'),
        SizedBox(
          height: panelHeight,
          child: PageView.builder(
            controller: _pageController,
            itemCount: _pageCount,
            onPageChanged: (value) => setState(() => _page = value),
            itemBuilder: (_, page) {
              final start = page * 5;
              final end = math.min(start + 5, widget.episodes.length);
              return _PopupEpisodePage(
                episodes: widget.episodes.sublist(start, end),
                selectedEpisode: widget.selectedEpisode,
                onEpisodeSelected: widget.onEpisodeSelected,
                // 容器被视口压缩（极端矮屏）时允许滚动查看被裁行。
                scrollable: panelHeight < 159.0,
              );
            },
          ),
        ),
        if (_pageCount > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '上一页',
                visualDensity: VisualDensity.compact,
                onPressed: _page == 0 ? null : () => _goTo(_page - 1),
                icon: const Icon(Icons.chevron_left_rounded, size: 20),
              ),
              Text(
                '${_page + 1}/$_pageCount',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.58),
                  fontSize: 11,
                ),
              ),
              IconButton(
                tooltip: '下一页',
                visualDensity: VisualDensity.compact,
                onPressed: _page == _pageCount - 1
                    ? null
                    : () => _goTo(_page + 1),
                icon: const Icon(Icons.chevron_right_rounded, size: 20),
              ),
            ],
          ),
      ],
    );
  }

  void _goTo(int page) {
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }
}

class _PopupEpisodePage extends StatelessWidget {
  const _PopupEpisodePage({
    required this.episodes,
    required this.selectedEpisode,
    required this.onEpisodeSelected,
    this.scrollable = false,
  });

  final List<PopupEpisodeOption> episodes;
  final int selectedEpisode;
  final ValueChanged<int> onEpisodeSelected;

  /// 容器高度被视口压缩（极端矮屏）时允许滚动查看被裁行；正常高度保持
  /// 每页固定 5 集不可滚动，翻页即换一批。
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      physics: scrollable
          ? const AlwaysScrollableScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      itemCount: episodes.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        color: Colors.white.withOpacity(0.09),
      ),
      itemBuilder: (_, index) {
        final episode = episodes[index];
        final selected =
            episode.selected || selectedEpisode == episode.index;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onEpisodeSelected(episode.index),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              children: [
                SizedBox(
                  width: 42,
                  child: Text(
                    'EP${episode.index}',
                    style: TextStyle(
                      color: selected ? popupMenuBlue : Colors.white,
                      fontSize: 12,
                      fontWeight: selected
                          ? FontWeight.w700
                          : FontWeight.normal,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    episode.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(selected ? 1 : 0.78),
                      fontSize: 12,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (selected)
                  const Icon(
                    Icons.check_rounded,
                    color: popupMenuBlue,
                    size: 17,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}


/// 可定位的播放器菜单覆盖层。聚合卡片以进度条为锚点居中，其余菜单以按钮为锚点。
class PopupMenuOverlay extends ConsumerWidget {
  const PopupMenuOverlay({
    super.key,
    required this.activeMenu,
    required this.anchorRect,
    required this.progressRect,
    required this.onClose,
    required this.onOpenMenu,
    required this.danmakuEnabled,
    required this.danmakuDeduplication,
    required this.danmakuDedupWindow,
    required this.danmakuFloatingColorful,
    required this.danmakuFloatingWhite,
    required this.danmakuScrollColorful,
    required this.danmakuScrollWhite,
    required this.danmakuBottomColorful,
    required this.danmakuBottomWhite,
    required this.danmakuStroke,
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
    required this.onDanmakuChanged,
    required this.onDanmakuDeduplicationChanged,
    required this.onDanmakuDedupWindowChanged,
    required this.onDanmakuFloatingColorfulChanged,
    required this.onDanmakuFloatingWhiteChanged,
    required this.onDanmakuScrollColorfulChanged,
    required this.onDanmakuScrollWhiteChanged,
    required this.onDanmakuStrokeChanged,
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
    this.onAggregationSearch,
    this.onCrossServerMatchSelected,
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
  final double danmakuDedupWindow;
  final bool danmakuFloatingColorful;
  final bool danmakuFloatingWhite;
  final bool danmakuScrollColorful;
  final bool danmakuScrollWhite;
  final bool danmakuBottomColorful;
  final bool danmakuBottomWhite;
  final bool danmakuStroke;
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

  final ValueChanged<bool> onDanmakuChanged;
  final ValueChanged<bool> onDanmakuDeduplicationChanged;
  final ValueChanged<double> onDanmakuDedupWindowChanged;
  final ValueChanged<bool> onDanmakuFloatingColorfulChanged;
  final ValueChanged<bool> onDanmakuFloatingWhiteChanged;
  final ValueChanged<bool> onDanmakuScrollColorfulChanged;
  final ValueChanged<bool> onDanmakuScrollWhiteChanged;
  final ValueChanged<bool> onDanmakuStrokeChanged;
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
  final VoidCallback? onAggregationSearch;
  final ValueChanged<ServerMatchInfo>? onCrossServerMatchSelected;
  final ValueChanged<PopupSkipRecord> onSkipTimeRecorded;
  final VoidCallback onClearIntro;
  final VoidCallback onClearOutro;
  final VoidCallback onExternalSubtitleRequested;

  Widget _menu({UnifiedMediaResource? unifiedResource, required WidgetRef ref}) {
    switch (activeMenu!) {
      case PopupMenuId.danmaku:
        return PopupDanmakuMenu(
          enabled: danmakuEnabled,
          onEnabledChanged: onDanmakuChanged,
          // 搜索弹幕改为胶囊菜单（锚定弹幕按钮下方，与选集框同风格）。
          onSearch: () => onOpenMenu(PopupMenuId.danmakuSearch),
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
          dedupWindow: danmakuDedupWindow,
          floatingColorful: danmakuFloatingColorful,
          floatingWhite: danmakuFloatingWhite,
          scrollColorful: danmakuScrollColorful,
          scrollWhite: danmakuScrollWhite,
          bottomColorful: danmakuBottomColorful,
          bottomWhite: danmakuBottomWhite,
          stroke: danmakuStroke,
          onOpacityChanged: onDanmakuOpacityChanged,
          onFontSizeChanged: onDanmakuFontSizeChanged,
          onSpeedChanged: onDanmakuSpeedChanged,
          onDensityChanged: onDanmakuDensityChanged,
          onAreaChanged: onDanmakuAreaChanged,
          onDelayChanged: onDanmakuDelayChanged,
          onDeduplicationChanged: onDanmakuDeduplicationChanged,
          onDedupWindowChanged: onDanmakuDedupWindowChanged,
          onFloatingColorfulChanged: onDanmakuFloatingColorfulChanged,
          onFloatingWhiteChanged: onDanmakuFloatingWhiteChanged,
          onScrollColorfulChanged: onDanmakuScrollColorfulChanged,
          onScrollWhiteChanged: onDanmakuScrollWhiteChanged,
          onBottomColorfulChanged: onDanmakuBottomColorfulChanged,
          onBottomWhiteChanged: onDanmakuBottomWhiteChanged,
          onStrokeChanged: onDanmakuStrokeChanged,
        );
      case PopupMenuId.danmakuSearch:
        // 播放器胶囊版弹幕搜索：与选集框同尺寸锚定在弹幕按钮下方，
        // 结果默认 3 条可见、可上下滚动；不含本地导入（右侧面板保留完整版）。
        // 加载成功即关闭菜单（onLoaded），让弹幕立即上屏。
        return DanmakuSearchContent(
          item: ref.read(currentPlayingItemProvider),
          compact: true,
          onLoaded: onClose,
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
          unifiedResource: unifiedResource,
          selectedAudioTrack: selectedAudioTrack,
          selectedSubtitleTrack: selectedSubtitleTrack,
        );
      case PopupMenuId.aggregate:
        // 复用详情页播放资源栏的跨服务器检索（rankingCrossServerMatchProvider），
        // 实时搜索其他服务器同媒体资源；无结果时回退本地已加载资源。
        return Consumer(
          builder: (context, ref, _) {
            final async = ref.watch(rankingCrossServerMatchProvider(mediaTitle));
            return async.when(
              loading: () => const SizedBox(
                height: 155,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => PopupAggregateSearchMenu(
                sources: sources,
                selectedSource: selectedSource,
                onSourceSelected: onSourceChanged,
                onSearchMore: onAggregationSearch,
              ),
              data: (matches) {
                if (matches.isEmpty) {
                  return PopupAggregateSearchMenu(
                    sources: sources,
                    selectedSource: selectedSource,
                    onSourceSelected: onSourceChanged,
                    onSearchMore: onAggregationSearch,
                  );
                }
                return StatefulBuilder(
                  builder: (context, setState) {
                    var crossSelectedIndex = 0;
                    return SizedBox(
                      height: 155,
                      width: double.infinity,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.zero,
                        itemCount: matches.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (_, index) {
                          final match = matches[index];
                          final info = matchPlaybackInfo(match);
                          return SizedBox(
                            width: 250,
                            child: PlaybackResourceCard(
                              serverName: match.serverName,
                              isBest: index == 0,
                              isSelected: index == crossSelectedIndex,
                              resolution: info.resolution,
                              dynamicRange: info.dynamicRange,
                              codec: info.codec,
                              frameRate: info.frameRate,
                              size: info.size,
                              bitrate: info.bitrate,
                              // 单击 = 直接播放该服务器资源（复用详情页播放链路）。
                              onTap: () {
                                setState(() => crossSelectedIndex = index);
                                onCrossServerMatchSelected?.call(match);
                              },
                            ),
                          );
                        },
                      ),
                    );
                  },
                );
              },
            );
          },
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
          tracks: const [],
          selectedTrack: selectedAudioTrack,
          onTrackSelected: onAudioTrackChanged,
          unifiedResource: unifiedResource,
          preferQualityAudio: selectedCore != 'exoPlayer',
        );
      case PopupMenuId.subtitle:
        return PopupTrackMenu(
          title: '字幕轨道',
          tracks: const [],
          selectedTrack: selectedSubtitleTrack,
          onTrackSelected: onSubtitleChanged,
          externalSubtitle: true,
          onExternalSubtitle: onExternalSubtitleRequested,
          onOpenSettings: () => onOpenMenu(PopupMenuId.subtitleSettings),
          unifiedResource: unifiedResource,
        );
      case PopupMenuId.subtitleSettings:
        // 直接 watch 字幕大小/位置 provider（PopupMenuOverlay 是 ConsumerWidget，
        // 无需经 widget 参数传递）；写 provider 后由播放器状态层的
        // listenManual 自动下发到内核（setSubtitleSize / setSubtitlePosition）。
        return Consumer(
          builder: (context, ref, _) {
            final size = ref.watch(subtitleSizeProvider);
            final position = ref.watch(subtitlePositionProvider);
            return PopupSubtitleSettingsMenu(
              subtitleSize: size,
              subtitlePosition: position,
              onSubtitleSizeChanged: (v) {
                ref.read(subtitleSizeTouchedProvider.notifier).state = true;
                ref.read(subtitleSizeProvider.notifier).state = v;
              },
              onSubtitlePositionChanged: (v) =>
                  ref.read(subtitlePositionProvider.notifier).state = v,
            );
          },
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
  Widget build(BuildContext context, WidgetRef ref) {
    final unifiedResource = ref.read(unifiedResourceProvider);
    final menu = activeMenu;
    if (menu == null) return const SizedBox.shrink();

    final isInlineAggregate = menu == PopupMenuId.aggregate;
    final menuChild = _menu(unifiedResource: unifiedResource, ref: ref);
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
            aggregate: isInlineAggregate,
            anchorRect: anchorRect,
            progressRect: progressRect,
          ),
          // 聚合资源卡本身就是详情页资源框：不再用 PopupMenuShell 包裹，
          // 也不增加二级胶囊的内边距/背景。
          child: isInlineAggregate
              ? menuChild
              : PopupMenuShell(child: menuChild),
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
        minHeight: 155,
        maxHeight: 155,
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
