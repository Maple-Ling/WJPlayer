import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../../core/services/system_info_service.dart';

const Color playerUiBlue = Color(0xFF4A7BD0);
const Color playerUiPink = Color(0xFFE94560);

/// 顶栏操作类型。
enum PlayerTopAction {
  anime4k,
  hardwareDecoding,
  danmaku,
  speed,
  skipOpeningEnding,
  aspectRatio,
  mediaInfo,
}

/// 无背景图标。通过阴影图层提升透明悬浮图标在视频画面上的可读性。
class PlayerShadowIcon extends StatelessWidget {
  const PlayerShadowIcon({
    super.key,
    this.icon,
    this.iconBuilder,
    this.size = 24,
    this.color = Colors.white,
    this.shadowColor = const Color(0xD9000000),
    this.shadowBlur = 3,
    this.shadowOffset = 2,
  }) : assert(
          icon != null || iconBuilder != null,
          'icon 或 iconBuilder 至少需要提供一个',
        );

  final IconData? icon;
  final Widget Function(Color color)? iconBuilder;
  final double size;
  final Color color;
  final Color shadowColor;
  final double shadowBlur;
  final double shadowOffset;

  Widget _glyph(Color glyphColor) {
    if (iconBuilder != null) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(child: iconBuilder!(glyphColor)),
      );
    }

    return Icon(icon, size: size, color: glyphColor);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 8,
      height: size + 8,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform.translate(
            offset: Offset(0, shadowOffset),
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: shadowBlur,
                sigmaY: shadowBlur,
              ),
              child: _glyph(shadowColor),
            ),
          ),
          _glyph(color),
        ],
      ),
    );
  }
}

/// 播放器顶部系统状态栏 + Logo + 服务器信息 + 顶部操作按钮。
class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.logoText,
    this.logo,
    this.logoImage,
    this.logoWidth = 150,
    this.logoHeight = 38,
    this.serverIcon,
    required this.serverName,
    required this.lineName,
    required this.timeText,
    required this.batteryLevel,
    this.batteryCharging = false,
    required this.networkIcon,
    required this.networkLabel,
    this.networkSpeed = '',
    required this.topActions,
    required this.selectedActions,
    required this.anime4kEnabled,
    required this.hardwareDecoding,
    this.onBack,
    this.onAction,
  });

  final Widget? logo;
  final ImageProvider<Object>? logoImage;
  final String logoText;
  final double logoWidth;
  final double logoHeight;

  final Widget? serverIcon;
  final String serverName;
  final String lineName;

  final String timeText;
  final int batteryLevel;
  final bool batteryCharging;
  final IconData networkIcon;
  final String networkLabel;
  final String networkSpeed;

  final List<PlayerTopAction> topActions;
  final Set<PlayerTopAction> selectedActions;
  final bool anime4kEnabled;
  final bool hardwareDecoding;
  final VoidCallback? onBack;
  final ValueChanged<PlayerTopAction>? onAction;

  IconData get _batteryIcon {
    if (batteryCharging) return Icons.battery_charging_full_rounded;
    if (batteryLevel <= 10) return Icons.battery_alert_rounded;
    if (batteryLevel <= 35) return Icons.battery_2_bar_rounded;
    if (batteryLevel <= 65) return Icons.battery_4_bar_rounded;
    return Icons.battery_full_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: true,
      bottom: false,
      child: Stack(
        children: [
          // 顶部渐变背景：纯装饰层，IgnorePointer 不拦截触摸——点击媒体
          // 信息栏（服务器名称/线路等）、两侧 8% 边距、渐变区域时事件
          // 穿透到底层手势层（_buildPlayerBody 轻点判定切换控制栏显隐）。
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xA6000000), Colors.transparent],
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                MediaQuery.sizeOf(context).width * 0.08,
                8,
                MediaQuery.sizeOf(context).width * 0.08,
                12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSystemStatusBar(),
                  const SizedBox(height: 8),
                  _buildTopRow(),
                  const SizedBox(height: 10),
                  _buildServerMeta(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemStatusBar() {
    final safeBattery = batteryLevel.clamp(0, 100);
    final batteryColor = safeBattery <= 15
        ? Colors.orangeAccent
        : batteryCharging
            ? const Color(0xFF9DBDF5)
            : Colors.white70;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            timeText,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
              height: 1,
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 网速显示（WiFi 图标左侧）
              if (networkSpeed.isNotEmpty) ...[
                Text(
                  networkSpeed,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    height: 1,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 9),
              ],
              // 状态栏图标仅展示：Tooltip 自带 opaque 手势层会拦截点击，
              // 包 IgnorePointer 让图标区域点击穿透到底层手势层。
              IgnorePointer(
                child: Tooltip(
                  message: networkLabel,
                  child: Icon(
                    networkIcon,
                    size: 15,
                    color: Colors.white70,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Icon(
                _batteryIcon,
                size: 16,
                color: batteryColor,
              ),
              const SizedBox(width: 3),
              Text(
                '$safeBattery%',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                  height: 1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTopRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _TransparentCircleButton(
          icon: Icons.arrow_back_ios_new,
          tooltip: '返回',
          size: 38,
          iconSize: 20,
          background: Colors.black.withOpacity(0.4),
          onTap: onBack,
        ),
        const SizedBox(width: 10),
        _buildLogo(),
        const SizedBox(width: 10),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final action in topActions)
                    _TopActionButton(
                      action: action,
                      selected: selectedActions.contains(action) ||
                          (action == PlayerTopAction.anime4k && anime4kEnabled) ||
                          (action == PlayerTopAction.hardwareDecoding &&
                              hardwareDecoding),
                      onTap: () => onAction?.call(action),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLogo() {
    final Widget content;
    if (logo != null) {
      content = logo!;
    } else if (logoImage != null) {
      content = Image(
        image: logoImage!,
        width: logoWidth,
        height: logoHeight,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
        // 外部 logo 加载失败时回退到文本标题，避免显示破图/错乱占位。
        errorBuilder: (_, __, ___) => _buildLogoText(),
      );
    } else {
      content = _buildLogoText();
    }

    return SizedBox(
      width: logoWidth,
      height: logoHeight,
      child: content,
    );
  }

  Widget _buildLogoText() {
    final text = logoText.trim().isEmpty ? 'WJPLAYER' : logoText.trim();
    // 无 logo 时显示媒体名称：使用适中的标题字号（不再放大到 logo 级字号），
    // 且标题后不再追加 V 形 chevron（豆瓣等源只有文字标题）。
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: 1,
        height: 1,
        shadows: [
          Shadow(
            color: Colors.black87,
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
    );
  }

  Widget _buildServerMeta() {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        children: [
          // 服务器图标纯装饰展示：IgnorePointer 让图标区域点击也穿透到
          // 底层手势层——点服务器名称/线路/图标均触发控制栏显隐切换。
          SizedBox(
            width: 22,
            height: 22,
            child: IgnorePointer(
              child: serverIcon ??
                  Container(
                    decoration: BoxDecoration(
                      color: playerUiBlue,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.dns_outlined,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              serverName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 线路状态小圆点纯装饰：IgnorePointer 让该区域点击同样穿透。
                IgnorePointer(
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: playerUiBlue,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    lineName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 10.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TransparentCircleButton extends StatelessWidget {
  const _TransparentCircleButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 36,
    this.iconSize = 19,
    this.background,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            shape: BoxShape.circle,
          ),
          child: PlayerShadowIcon(
            icon: icon,
            size: iconSize,
          ),
        ),
      ),
    );
  }
}

class _TopActionButton extends StatelessWidget {
  const _TopActionButton({
    required this.action,
    required this.selected,
    required this.onTap,
  });

  final PlayerTopAction action;
  final bool selected;
  final VoidCallback onTap;

  String get label {
    switch (action) {
      case PlayerTopAction.anime4k:
        return 'Anime4K 超分';
      case PlayerTopAction.hardwareDecoding:
        return '硬解/软解';
      case PlayerTopAction.danmaku:
        return '弹幕';
      case PlayerTopAction.speed:
        return '倍速';
      case PlayerTopAction.skipOpeningEnding:
        return '跳过片头片尾';
      case PlayerTopAction.aspectRatio:
        return '画面比例';
      case PlayerTopAction.mediaInfo:
        return '媒体信息';
    }
  }

  IconData get icon {
    switch (action) {
      case PlayerTopAction.anime4k:
        return Icons.auto_awesome_rounded;
      case PlayerTopAction.hardwareDecoding:
        return Icons.settings_overscan_rounded;
      case PlayerTopAction.danmaku:
        return Icons.chat_bubble_outline;
      case PlayerTopAction.speed:
        return Icons.speed;
      case PlayerTopAction.skipOpeningEnding:
        return Icons.skip_next;
      case PlayerTopAction.aspectRatio:
        return Icons.aspect_ratio;
      case PlayerTopAction.mediaInfo:
        return Icons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? playerUiBlue.withOpacity(0.35)
                : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: PlayerShadowIcon(icon: icon, size: 19),
        ),
      ),
    );
  }
}

/// 底栏操作类型。
enum PlayerBottomAction {
  aggregate,
  core,
  line,
  audio,
  subtitle,
  episodes,
}

/// 播放器底部媒体信息、进度条、播放控制和胶囊菜单入口。
class BottomBar extends StatelessWidget {
  const BottomBar({
    super.key,
    required this.title,
    required this.episode,
    required this.meta,
    required this.position,
    required this.duration,
    required this.bufferedProgress,
    required this.isPlaying,
    this.dragTargetPosition,
    this.isDraggingProgress = false,
    this.progressOverride,
    required this.bottomActions,
    required this.selectedActions,
    this.onProgressChanged,
    this.onProgressChangeEnd,
    this.onPrevious,
    this.onPlayPause,
    this.onNext,
    this.onAction,
  });

  final String title;
  final String episode;
  final String meta;
  final Duration position;
  final Duration duration;
  final double bufferedProgress;
  final bool isPlaying;
  final Duration? dragTargetPosition;
  final bool isDraggingProgress;
  final double? progressOverride;

  final List<PlayerBottomAction> bottomActions;
  final Set<PlayerBottomAction> selectedActions;
  final ValueChanged<double>? onProgressChanged;
  final ValueChanged<double>? onProgressChangeEnd;
  final VoidCallback? onPrevious;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;
  final ValueChanged<PlayerBottomAction>? onAction;

  double get progress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Stack(
        children: [
          // 底部渐变背景：纯装饰层，IgnorePointer 不拦截触摸——标题/元信息
          // 文字上方与渐变区域点击穿透到底层手势层（切换控制栏显隐）。
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xBF000000), Colors.transparent],
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                MediaQuery.sizeOf(context).width * 0.08,
                8,
                MediaQuery.sizeOf(context).width * 0.08,
                14,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            shadows: [
                              Shadow(
                                color: Colors.black87,
                                blurRadius: 4,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          episode,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.78),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.55),
                            fontSize: 10.5,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  _buildProgress(context),
                  const SizedBox(height: 6),
                  _buildControls(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress(BuildContext context) {
    final enabled = onProgressChanged != null || onProgressChangeEnd != null;
    final target = dragTargetPosition;
    final progressRow = Row(
      children: [
        SizedBox(
          // 时间文本自适应宽度：HH:MM:SS（8 字符）比 MM:SS（5 字符）宽，
          // 固定 42 会把长时长挤到下一行。
          width: _durationTextWidth(_formatDuration(position)),
          child: Text(
            _formatDuration(position),
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 11,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: playerUiPink,
              inactiveTrackColor: Colors.white.withOpacity(0.2),
              secondaryActiveTrackColor: Colors.white.withOpacity(0.35),
              thumbColor: Colors.white,
              overlayColor: Colors.white.withOpacity(0.12),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
            ),
            child: Slider(
              value: progressOverride ?? progress,
              secondaryTrackValue: bufferedProgress.clamp(0.0, 1.0),
              min: 0,
              max: 1,
              onChanged: enabled ? onProgressChanged : null,
              onChangeEnd: enabled ? onProgressChangeEnd : null,
            ),
          ),
        ),
        SizedBox(
          width: _durationTextWidth(_formatDuration(duration)),
          child: Text(
            _formatDuration(duration),
            textAlign: TextAlign.right,
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
    if (target == null) return progressRow;
    // 拖动/seek 稳定期：目标绝对时间紧贴进度条上方、水平居中，
    // 向上偏移约两字符高度；position 已由上层传入拖动预览值，跟手不回弹。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Center(
            child: Text(
              _formatDuration(target),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
              ),
            ),
          ),
        ),
        progressRow,
      ],
    );
  }

  Widget _buildControls() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TransportButton(
              icon: Icons.skip_previous_rounded,
              tooltip: '上一集',
              onTap: onPrevious,
            ),
            const SizedBox(width: 8),
            _TransportButton(
              icon: isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              tooltip: isPlaying ? '暂停' : '播放',
              size: 38,
              iconSize: 23,
              onTap: onPlayPause,
            ),
            const SizedBox(width: 8),
            _TransportButton(
              icon: Icons.skip_next_rounded,
              tooltip: '下一集',
              onTap: onNext,
            ),
          ],
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: SingleChildScrollView(
              reverse: true,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final action in bottomActions)
                    _BottomActionButton(
                      action: action,
                      selected: selectedActions.contains(action),
                      onTap: () => onAction?.call(action),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 30);
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remain = seconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${remain.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${remain.toString().padLeft(2, '0')}';
  }

  /// 进度条时间文本的精确宽度（fontSize 11 测量 + 2px 余量）。
  /// 时长带小时（HH:MM:SS）比纯 MM:SS 宽，固定宽度会把末位挤到下一行。
  double _durationTextWidth(String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white.withOpacity(0.8),
          fontSize: 11,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w + 2;
  }
}

class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 36,
    this.iconSize = 22,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: PlayerShadowIcon(
              icon: icon,
              size: iconSize,
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomActionButton extends StatelessWidget {
  const _BottomActionButton({
    required this.action,
    required this.selected,
    required this.onTap,
  });

  final PlayerBottomAction action;
  final bool selected;
  final VoidCallback onTap;

  String get label {
    switch (action) {
      case PlayerBottomAction.aggregate:
        return '聚合';
      case PlayerBottomAction.core:
        return '内核';
      case PlayerBottomAction.line:
        return '线路';
      case PlayerBottomAction.audio:
        return '音频';
      case PlayerBottomAction.subtitle:
        return '字幕';
      case PlayerBottomAction.episodes:
        return '选集';
    }
  }

  IconData get icon {
    switch (action) {
      case PlayerBottomAction.aggregate:
        return Icons.travel_explore_rounded;
      case PlayerBottomAction.core:
        return Icons.memory_rounded;
      case PlayerBottomAction.line:
        return Icons.route_rounded;
      case PlayerBottomAction.audio:
        return Icons.audiotrack_rounded;
      case PlayerBottomAction.subtitle:
        return Icons.subtitles_outlined;
      case PlayerBottomAction.episodes:
        return Icons.playlist_play_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 44),
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? playerUiBlue.withOpacity(0.35)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PlayerShadowIcon(icon: icon, size: 19),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.85),
                  fontSize: 9.5,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 左侧锁定、右侧旋转按钮。按钮本体透明，仅保留图标投影和点击区域。
class SideButtons extends StatelessWidget {
  const SideButtons({
    super.key,
    this.horizontalPadding = 14,
    this.buttonSize = 44,
    this.iconSize = 26,
    this.onLock,
    this.onRotate,
    this.lockIconBuilder,
    this.rotateIconBuilder,
  });

  final double horizontalPadding;
  final double buttonSize;
  final double iconSize;
  final VoidCallback? onLock;
  final VoidCallback? onRotate;
  final Widget Function(Color color)? lockIconBuilder;
  final Widget Function(Color color)? rotateIconBuilder;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : MediaQuery.sizeOf(context).height;
          final top = ((height - buttonSize) / 2).clamp(0.0, height);

          return Stack(
            children: [
              Positioned(
                left: horizontalPadding,
                top: top,
                child: _SideButton(
                  tooltip: '锁定屏幕',
                  icon: Icons.lock_outline_rounded,
                  iconBuilder: lockIconBuilder,
                  buttonSize: buttonSize,
                  iconSize: iconSize,
                  onTap: onLock,
                ),
              ),
              Positioned(
                right: horizontalPadding,
                top: top,
                child: _SideButton(
                  tooltip: '旋转屏幕',
                  icon: Icons.screen_rotation_alt_rounded,
                  iconBuilder: rotateIconBuilder,
                  buttonSize: buttonSize,
                  iconSize: iconSize,
                  onTap: onRotate,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SideButton extends StatelessWidget {
  const _SideButton({
    required this.tooltip,
    required this.icon,
    required this.iconBuilder,
    required this.buttonSize,
    required this.iconSize,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final Widget Function(Color color)? iconBuilder;
  final double buttonSize;
  final double iconSize;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: buttonSize,
            height: buttonSize,
            child: Center(
              child: PlayerShadowIcon(
                icon: icon,
                iconBuilder: iconBuilder,
                size: iconSize,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
