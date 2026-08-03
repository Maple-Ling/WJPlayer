import 'package:flutter/widgets.dart';
import 'package:flutter_animate/flutter_animate.dart';

/// 全端统一动效系统（基于 flutter_animate）。
///
/// 单一“动效真相源”：三端（TV / 桌面 / 移动）的时长、曲线、错峰节奏都从这里取，
/// 避免各端各写一套导致节奏不一致、调一次要改十几处。
///
/// 设计目标：流畅且不吃性能——
/// - 入场动画一次性播放（默认 autoPlay），不随 rebuild 重放；
/// - 错峰延迟有上限（[staggerMaxItems]），长列表尾部不会迟迟不出现；
/// - 优先 transform/opacity 这类便宜的合成属性，避免动画阴影/布局。
class AppMotion {
  AppMotion._();

  // === 时长 ===
  /// 微交互（高亮、勾选、小图标）。
  static const Duration fast = Duration(milliseconds: 150);

  /// 常规状态切换（悬停、展开、淡入淡出）。
  static const Duration medium = Duration(milliseconds: 250);

  /// 强调过渡（大面板、模态）。
  static const Duration slow = Duration(milliseconds: 400);

  /// 内容入场（卡片、区块）。
  static const Duration entrance = Duration(milliseconds: 320);

  // === 曲线 ===
  /// 标准减速曲线，绝大多数入场/正向过渡用它。
  static const Curve standard = Curves.easeOutCubic;

  /// 强调曲线，先加速后减速，用于较大的位移/缩放。
  static const Curve emphasized = Curves.fastOutSlowIn;

  /// 反向/退场曲线。
  static const Curve reverse = Curves.easeInCubic;

  // === 错峰 ===
  /// 相邻 item 的入场延迟步长。
  static const Duration staggerStep = Duration(milliseconds: 40);

  /// 参与错峰的最大 item 数；超过的 item 用同一最大延迟，
  /// 避免长列表越往后入场越晚。
  static const int staggerMaxItems = 12;

  /// 计算第 [index] 个 item 的入场延迟（已封顶）。
  static Duration staggerDelay(int index) {
    final clamped =
        index < 0 ? 0 : (index > staggerMaxItems ? staggerMaxItems : index);
    return staggerStep * clamped;
  }

  /// 应用 flutter_animate 的全局默认值，在 [runApp] 之前调用一次。
  static void applyGlobalDefaults() {
    Animate.defaultDuration = entrance;
    Animate.defaultCurve = standard;
  }
}

/// 「仅首次出现」入场动效：滚动列表/网格里，item 滚出再滚回会被
/// GridView/ListView 回收重建，导致 [appEntrance] 的 flutter_animate 重新播放
/// （即"回滑还在渐显"）。本方法按稳定 [id] 记录已出现项，已出现的直接显示、
/// 不再渐显；仅真正首次进入视口的项才播放入场。
///
/// [seen] 由调用方（通常是 State）持有并跨 rebuild 保留。
Widget entranceOnce({
  required String id,
  required int index,
  required Set<String> seen,
  required Widget child,
}) {
  if (seen.contains(id)) return child;
  seen.add(id);
  return child.appEntrance(index: index);
}

/// 统一入场动效扩展。在任意 Widget 上 `.appEntrance()` 即可获得
/// 一致的“淡入 + 轻微上移”，列表/网格传 [index] 自动错峰。
extension AppMotionEntrance on Widget {
  /// 内容入场：淡入 + 自下而上轻微位移（一次性）。
  ///
  /// [index]：在列表/网格中的位置，用于错峰；非列表场景留空即可。
  Widget appEntrance({int index = 0, Duration? delay}) {
    final effectiveDelay = delay ?? AppMotion.staggerDelay(index);
    return animate(delay: effectiveDelay)
        .fadeIn(duration: AppMotion.entrance, curve: AppMotion.standard)
        .slideY(
          begin: 0.06,
          end: 0,
          duration: AppMotion.entrance,
          curve: AppMotion.standard,
        );
  }

  /// 纯淡入，用于不希望有位移的场景（如整页内容切换）。
  Widget appFadeIn({Duration? duration, Duration? delay}) {
    return animate(delay: delay ?? Duration.zero).fadeIn(
      duration: duration ?? AppMotion.medium,
      curve: AppMotion.standard,
    );
  }

  /// 淡入 + 轻微放大，用于弹层、Toast、确认按钮等。
  Widget appScaleIn({Duration? duration, Duration? delay}) {
    final d = duration ?? AppMotion.medium;
    return animate(delay: delay ?? Duration.zero)
        .fadeIn(duration: d, curve: AppMotion.standard)
        .scaleXY(begin: 0.94, end: 1, duration: d, curve: AppMotion.emphasized);
  }
}
