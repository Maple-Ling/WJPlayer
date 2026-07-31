import 'package:flutter/material.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

/// TDesign 风格的「开关行」，作为 Material [SwitchListTile] 的 drop-in 替代：
/// 字段名与 SwitchListTile 对齐（secondary/title/subtitle/value/onChanged），
/// 三端统一开关观感时，调用处只需把 `SwitchListTile` 改名为 `TdSwitchTile`。
class TdSwitchTile extends StatelessWidget {
  /// 左侧图标（对应 SwitchListTile.secondary）。
  final Widget? secondary;
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry? contentPadding;

  final bool dense;

  const TdSwitchTile({
    super.key,
    this.secondary,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.contentPadding,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    // 开关尺寸随端走：从环境 TD 字号推断（移动~16/PC~15/TV~25+），TV 用大号。
    final bodySize = TDTheme.of(context).fontBodyLarge?.size ?? 16;
    final switchSize = bodySize >= 22
        ? TDSwitchSize.large
        : (bodySize <= 15 ? TDSwitchSize.small : TDSwitchSize.medium);

    // 手写行布局（不用 TDCell，避免其标题/描述叠字问题）：
    // 左图标 + 标题/副标题竖排 + 右侧 TDSwitch，整体可点切换。对齐 ListTile 观感。
    final theme = Theme.of(context);
    final vPad = dense ? 6.0 : 10.0;
    final row = Padding(
      padding: contentPadding?.resolve(Directionality.of(context)) ??
          EdgeInsets.symmetric(horizontal: 16, vertical: vPad),
      child: Row(
        children: [
          if (secondary != null) ...[
            IconTheme.merge(
              data: IconThemeData(color: theme.colorScheme.onSurfaceVariant),
              child: secondary!,
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                DefaultTextStyle.merge(
                  style: theme.textTheme.titleMedium,
                  child: title,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  DefaultTextStyle.merge(
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    child: subtitle!,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          TDSwitch(
            size: switchSize,
            isOn: value,
            enable: onChanged != null,
            onChanged: onChanged == null
                ? null
                : (v) {
                    onChanged!(v);
                    return true; // 状态由外部 provider 持有，始终接受切换。
                  },
          ),
        ],
      ),
    );

    return onChanged == null
        ? row
        : InkWell(onTap: () => onChanged!(!value), child: row);
  }
}
