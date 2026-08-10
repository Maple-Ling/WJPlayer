import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../../core/services/system_info_service.dart';
import '../../../core/utils/platform_utils.dart';

const Color playerUiBlue = Color(0xFF4A7BD0);
const Color playerUiPink = Color(0xFFE94560);

/// 播放器 UI 统一缩放因子（InheritedWidget）。
///
/// 平板/大屏：控制栏组件尺寸按 [scale] 放大，避免 UI 在平板上过小。
/// 手机与 TV 尺寸基准为 1.0（TV 已有自己的大尺寸布局），不缩放。
/// 读取：`final s = PlayerUiScale.of(context);`（无提供者时返回 1.0）。
class PlayerUiScale extends InheritedWidget {
  const PlayerUiScale({
    super.key,
    required this.scale,
    required super.child,
  });

  final double scale;

  static double of(BuildContext context) {
    final widget =
        context.dependOnInheritedWidgetOfExactType<PlayerUiScale>();
    return widget?.scale ?? 1.0;
  }

  @override
  bool updateShouldNotify(PlayerUiScale oldWidget) =>
      oldWidget.scale != scale;
}

/// 计算播放器 UI 缩放因子：按屏幕最短边（竖屏=宽，横屏=高）判断。
/// 手机（最短边 ≤ 480dp，含 6.8" 大屏手机）恒 1.0 不缩放；
/// 平板/大屏（最短边 > 480dp）线性放大、封顶 1.8。
/// TV（isTvPlatform）始终 1.0——TV 控制栏已按遥控距离设计，无需放大。
double playerUiScaleOf(Size screenSize, {required bool isTv}) {
  if (isTv) return 1.0;
  final shortest = screenSize.shortestSide;
  if (shortest <= 480) return 1.0;
  return (shortest / 480).clamp(1.0, 1.8);
}

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
    this.tvFocusIndex = -1,
    this.tvFocusNodes,
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

  /// TV 顶部控制区焦点：-1=无；0=返回；1..=顶部操作按钮。
  final int tvFocusIndex;

  /// TV 顶部区按钮焦点节点：index 0=返回，1+i=topActions[i]（由播放器持有）。
  final List<FocusNode>? tvFocusNodes;

  IconData get _batteryIcon {
    if (batteryCharging) return Icons.battery_charging_full_rounded;
    if (batteryLevel <= 10) return Icons.battery_alert_rounded;
    if (batteryLevel <= 35) return Icons.battery_2_bar_rounded;
    if (batteryLevel <= 65) return Icons.battery_4_bar_rounded;
    return Icons.battery_full_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final s = PlayerUiScale.of(context);
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
                8 * s,
                MediaQuery.sizeOf(context).width * 0.08,
                12 * s,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSystemStatusBar(s),
                  SizedBox(height: 8 * s),
                  _buildTopRow(s),
                  SizedBox(height: 10 * s),
                  _buildServerMeta(s),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemStatusBar(double s) {
    final safeBattery = batteryLevel.clamp(0, 100);
    final batteryColor = safeBattery <= 15
        ? Colors.orangeAccent
        : batteryCharging
            ? const Color(0xFF9DBDF5)
            : Colors.white70;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4 * s),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            timeText,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 10.5 * s,
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
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 10.5 * s,
                    fontWeight: FontWeight.w500,
                    height: 1,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                SizedBox(width: 9 * s),
              ],
              // 状态栏图标仅展示：Tooltip 自带 opaque 手势层会拦截点击，
              // 包 IgnorePointer 让图标区域点击穿透到底层手势层。
              IgnorePointer(
                child: Tooltip(
                  message: networkLabel,
                  child: Icon(
                    networkIcon,
                    size: 15 * s,
                    color: Colors.white70,
                  ),
                ),
              ),
              SizedBox(width: 9 * s),
              Icon(
                _batteryIcon,
                size: 16 * s,
                color: batteryColor,
              ),
              SizedBox(width: 3 * s),
              Text(
                '$safeBattery%',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 10.5 * s,
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

  Widget _buildTopRow(double s) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _TransparentCircleButton(
          icon: Icons.arrow_back_ios_new,
          tooltip: '返回',
          size: 38 * s,
          iconSize: 20 * s,
          background: Colors.black.withOpacity(0.4),
          onTap: onBack,
          focusNode: tvFocusNodes != null && tvFocusNodes!.isNotEmpty
              ? tvFocusNodes![0]
              : null,
          focused: tvFocusIndex == 0,
        ),
        SizedBox(width: 10 * s),
        _buildLogo(s),
        SizedBox(width: 10 * s),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < topActions.length; i++)
                    _TopActionButton(
                      action: topActions[i],
                      selected: selectedActions.contains(topActions[i]) ||
                          (topActions[i] == PlayerTopAction.anime4k &&
                              anime4kEnabled) ||
                          (topActions[i] ==
                                  PlayerTopAction.hardwareDecoding &&
                              hardwareDecoding),
                      onTap: () => onAction?.call(topActions[i]),
                      focusNode: tvFocusNodes != null &&
                              tvFocusNodes!.length > 1 + i
                          ? tvFocusNodes![1 + i]
                          : null,
                      focused: tvFocusIndex == 1 + i,
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLogo(double s) {
    final Widget content;
    if (logo != null) {
      content = logo!;
    } else if (logoImage != null) {
      content = Image(
        image: logoImage!,
        width: logoWidth * s,
        height: logoHeight * s,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
        // 外部 logo 加载失败时回退到文本标题，避免显示破图/错乱占位。
        errorBuilder: (_, __, ___) => _buildLogoText(s),
      );
    } else {
      content = _buildLogoText(s);
    }

    return SizedBox(
      width: logoWidth * s,
      height: logoHeight * s,
      child: content,
    );
  }

  Widget _buildLogoText(double s) {
    final text = logoText.trim().isEmpty ? 'WJPLAYER' : logoText.trim();
    // 无 logo 时显示媒体名称：使用适中的标题字号（不再放大到 logo 级字号），
    // 且标题后不再追加 V 形 chevron（豆瓣等源只有文字标题）。
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: Colors.white,
        fontSize: 20 * s,
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

  Widget _buildServerMeta(double s) {
    return Padding(
      padding: EdgeInsets.only(left: 4 * s),
      child: Row(
        children: [
          // 服务器图标纯装饰展示：IgnorePointer 让图标区域点击也穿透到
          // 底层手势层——点服务器名称/线路/图标均触发控制栏显隐切换。
          SizedBox(
            width: 22 * s,
            height: 22 * s,
            child: IgnorePointer(
              child: serverIcon ??
                  Container(
                    decoration: BoxDecoration(
                      color: playerUiBlue,
                      borderRadius: BorderRadius.circular(6 * s),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.dns_outlined,
                      color: Colors.white,
                      size: 14 * s,
                    ),
                  ),
            ),
          ),
          SizedBox(width: 8 * s),
          Flexible(
            child: Text(
              serverName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 13 * s,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(width: 8 * s),
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 线路状态小圆点纯装饰：IgnorePointer 让该区域点击同样穿透。
                IgnorePointer(
                  child: Container(
                    width: 10 * s,
                    height: 10 * s,
                    decoration: BoxDecoration(
                      color: playerUiBlue,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                SizedBox(width: 5 * s),
                Flexible(
                  child: Text(
                    lineName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 10.5 * s,
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
    this.focused = false,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final Color? background;

  /// TV 聚焦态：白色圆环描边。
  final bool focused;

  /// TV 遥控聚焦节点（播放器持有；null = 不可遥控聚焦）。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: focusNode,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap?.call();
            return null;
          },
        ),
      },
      child: Tooltip(
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
              border: focused
                  ? Border.all(color: Colors.white, width: 2.5)
                  : null,
              boxShadow: focused
                  ? [
                      BoxShadow(
                          color: Colors.white.withValues(alpha: 0.35),
                          blurRadius: 10)
                    ]
                  : null,
            ),
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

class _TopActionButton extends StatelessWidget {
  const _TopActionButton({
    required this.action,
    required this.selected,
    required this.onTap,
    this.focusNode,
    this.focused = false,
  });

  final PlayerTopAction action;
  final bool selected;
  final VoidCallback onTap;

  /// TV 遥控聚焦节点（播放器持有；null = 不可遥控聚焦）。
  final FocusNode? focusNode;

  /// TV 聚焦态：蓝色描边高亮。
  final bool focused;

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
    final s = PlayerUiScale.of(context);
    return FocusableActionDetector(
      focusNode: focusNode,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap();
            return null;
          },
        ),
      },
      child: Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 36 * s,
            height: 36 * s,
            margin: EdgeInsets.symmetric(horizontal: 2 * s),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? playerUiBlue.withOpacity(0.35)
                  : Colors.transparent,
              shape: BoxShape.circle,
              border: focused
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
            ),
            child: PlayerShadowIcon(icon: icon, size: 19 * s),
          ),
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
    this.tvFocusIndex = -1,
    this.tvFocusNodes,
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

  /// TV 控制栏焦点：-2=进度条；0..N=按钮（传输 3 + 底部操作）；-1=无。
  final int tvFocusIndex;

  /// TV 底部区按钮焦点节点：index 0=进度条、1..3=传输、4..=底部操作
  /// （由播放器持有）。
  final List<FocusNode>? tvFocusNodes;

  double get progress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final s = PlayerUiScale.of(context);
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
                8 * s,
                MediaQuery.sizeOf(context).width * 0.08,
                14 * s,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.only(left: 4 * s),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17 * s,
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
                        SizedBox(height: 2 * s),
                        Text(
                          episode,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.78),
                            fontSize: 12 * s,
                          ),
                        ),
                        SizedBox(height: 2 * s),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.55),
                            fontSize: 10.5 * s,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 6 * s),
                  _buildProgress(context, focused: tvFocusIndex == -2, s: s),
                  SizedBox(height: 6 * s),
                  _buildControls(s),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress(BuildContext context,
      {required bool focused, required double s}) {
    final enabled = onProgressChanged != null || onProgressChangeEnd != null;
    final target = dragTargetPosition;
    final progressRow = Row(
      children: [
        SizedBox(
          // 时间文本自适应宽度：HH:MM:SS（8 字符）比 MM:SS（5 字符）宽，
          // 固定 42 会把长时长挤到下一行。
          width: _durationTextWidth(_formatDuration(position), s),
          child: Text(
            _formatDuration(position),
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 11 * s,
            ),
          ),
        ),
        Expanded(
          child: FocusableActionDetector(
            // 进度条焦点节点：区域切换聚焦到进度条时 Slider 高亮
            // （tvFocusIndex==-2 驱动）并由播放器统一聚焦。
            focusNode: tvFocusNodes != null && tvFocusNodes!.isNotEmpty
                ? tvFocusNodes![0]
                : null,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: (focused ? 6 : 4) * s,
                activeTrackColor: focused ? Colors.white : playerUiPink,
                inactiveTrackColor: Colors.white.withOpacity(0.2),
                secondaryActiveTrackColor: Colors.white.withOpacity(0.35),
                thumbColor: Colors.white,
                overlayColor: Colors.white.withOpacity(0.12),
                thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius: (focused ? 9 : 6.5) * s),
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
        ),
        SizedBox(
          width: _durationTextWidth(_formatDuration(duration), s),
          child: Text(
            _formatDuration(duration),
            textAlign: TextAlign.right,
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 11 * s,
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
          padding: EdgeInsets.only(bottom: 12 * s),
          child: Center(
            child: Text(
              _formatDuration(target),
              style: TextStyle(
                color: Colors.white,
                fontSize: 16 * s,
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

  Widget _buildControls(double s) {
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
              focused: tvFocusIndex == 0,
              focusNode: tvFocusNodes != null && tvFocusNodes!.length > 1
                  ? tvFocusNodes![1]
                  : null,
            ),
            SizedBox(width: 8 * s),
            _TransportButton(
              icon: isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              tooltip: isPlaying ? '暂停' : '播放',
              size: 38,
              iconSize: 23,
              onTap: onPlayPause,
              focused: tvFocusIndex == 1,
              focusNode: tvFocusNodes != null && tvFocusNodes!.length > 2
                  ? tvFocusNodes![2]
                  : null,
            ),
            SizedBox(width: 8 * s),
            _TransportButton(
              icon: Icons.skip_next_rounded,
              tooltip: '下一集',
              onTap: onNext,
              focused: tvFocusIndex == 2,
              focusNode: tvFocusNodes != null && tvFocusNodes!.length > 3
                  ? tvFocusNodes![3]
                  : null,
            ),
          ],
        ),
        SizedBox(width: 8 * s),
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
                  for (var i = 0; i < bottomActions.length; i++)
                    _BottomActionButton(
                      action: bottomActions[i],
                      selected: selectedActions.contains(bottomActions[i]),
                      onTap: () => onAction?.call(bottomActions[i]),
                      focused: tvFocusIndex == 3 + i,
                      focusNode: tvFocusNodes != null &&
                              tvFocusNodes!.length > 4 + i
                          ? tvFocusNodes![4 + i]
                          : null,
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
  double _durationTextWidth(String text, double s) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white.withOpacity(0.8),
          fontSize: 11 * s,
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
    this.focused = false,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;

  /// TV 聚焦态：白色圆环描边。
  final bool focused;

  /// TV 遥控聚焦节点（播放器持有；null = 不可遥控聚焦）。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final s = PlayerUiScale.of(context);
    return FocusableActionDetector(
      focusNode: focusNode,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap?.call();
            return null;
          },
        ),
      },
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: size * s,
            height: size * s,
            child: Center(
              child: Container(
                width: size * s,
                height: size * s,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: focused
                      ? Border.all(color: Colors.white, width: 2.5)
                      : null,
                  boxShadow: focused
                      ? [
                          BoxShadow(
                              color: Colors.white.withValues(alpha: 0.35),
                              blurRadius: 10)
                        ]
                      : null,
                ),
                child: PlayerShadowIcon(
                  icon: icon,
                  size: iconSize * s,
                ),
              ),
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
    this.focused = false,
    this.focusNode,
  });

  final PlayerBottomAction action;
  final bool selected;
  final VoidCallback onTap;

  /// TV 聚焦态：白色描边。
  final bool focused;

  /// TV 遥控聚焦节点（播放器持有；null = 不可遥控聚焦）。
  final FocusNode? focusNode;

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
    final s = PlayerUiScale.of(context);
    return FocusableActionDetector(
      focusNode: focusNode,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap();
            return null;
          },
        ),
      },
      child: Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(minWidth: 44 * s),
            margin: EdgeInsets.symmetric(horizontal: 1 * s),
            padding: EdgeInsets.symmetric(
                horizontal: 7 * s, vertical: 6 * s),
            decoration: BoxDecoration(
              color: selected
                  ? playerUiBlue.withOpacity(0.35)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10 * s),
              border: focused
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
            ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PlayerShadowIcon(icon: icon, size: 19 * s),
              SizedBox(height: 3 * s),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.85),
                  fontSize: 9.5 * s,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
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
    final s = PlayerUiScale.of(context);
    return SizedBox.expand(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : MediaQuery.sizeOf(context).height;
          final top = ((height - buttonSize * s) / 2).clamp(0.0, height);

          return Stack(
            children: [
              Positioned(
                left: horizontalPadding * s,
                top: top,
                child: _SideButton(
                  tooltip: '锁定屏幕',
                  icon: Icons.lock_outline_rounded,
                  iconBuilder: lockIconBuilder,
                  buttonSize: buttonSize * s,
                  iconSize: iconSize * s,
                  onTap: onLock,
                ),
              ),
              Positioned(
                right: horizontalPadding * s,
                top: top,
                child: _SideButton(
                  tooltip: '旋转屏幕',
                  icon: Icons.screen_rotation_alt_rounded,
                  iconBuilder: rotateIconBuilder,
                  buttonSize: buttonSize * s,
                  iconSize: iconSize * s,
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
