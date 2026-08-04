import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChrome, SystemUiOverlayStyle;

// ===========================================================================
// 播放器「胶囊菜单」（对应 HTML 播放器 UI 原型的 .menu / .pill / .agg 结构）
// ===========================================================================
//
// 设计对齐 HTML 原型：
// - 居中深色半透明胶囊（rgba(0x0C1016,.88) + 14 圆角 + 微边框 + 阴影）；
// - 菜单项 .pill：两端对齐，右侧副文本/勾选圆点/迷你按钮/下一级箭头；
// - 滑杆 .sl-row：窄滑条 + 渐变填充 + 数值；
// - 开关 .sw：小号胶囊开关；
// - 支持二级/三级导航：点击带箭头的行推入下一级，标题栏返回箭头回退。

/// 主面板配色 token（对齐 HTML）。
class CapsuleTokens {
  CapsuleTokens._();
  static const Color surface = Color(0xE00C1016);
  static const Color border = Color(0x14FFFFFF);
  static const Color text = Colors.white;
  static const Color textSecondary = Color(0x80FFFFFF);
  static const Color accent = Color(0xFF4A7BD0);
  static const Color accentFill = Color(0x664A7BD0);
  static const Color track = Color(0x0DFFFFFF);
  static const Color danger = Color(0xFFE94560);
  static const Color dangerFill = Color(0x33E94560);
  static const Color dangerBorder = Color(0x66E94560);
  static const Color checkBlue = Color(0xFF9DBDF5);
}

/// 菜单项模型：一个「pill」行。
///
/// [next] 非空时表示可进入下一级菜单（三级导航），整行显示「›」箭头；
/// 否则点击触发 [onTap]（可为 null = 仅展示）。
class CapsuleMenuItem {
  final String label;
  final String? subLabel;
  final String? trailingLabel;
  final bool selected;
  final VoidCallback? onTap;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final double sliderValue;
  final ValueChanged<double>? onSlider;
  final String? sliderValueLabel;
  final CapsuleMenuLevel? next;
  final bool info;
  final bool danger;

  const CapsuleMenuItem({
    required this.label,
    this.subLabel,
    this.trailingLabel,
    this.selected = false,
    this.value = false,
    this.onTap,
    this.onChanged,
    this.sliderValue = 0,
    this.onSlider,
    this.sliderValueLabel,
    this.next,
    this.info = false,
    this.danger = false,
  }) : assert(
          (onChanged != null) ||
              (onSlider != null) ||
              (onTap != null) ||
              (next != null) ||
              info,
          '胶囊菜单项必须绑定交互或用途',
        );

  bool get isSwitch => onChanged != null;
  bool get isSlider => onSlider != null;
}

/// 某一级菜单：标题 + 若干项。
class CapsuleMenuLevel {
  final String title;
  final List<CapsuleMenuItem> items;
  const CapsuleMenuLevel(this.title, this.items);
}

/// 打开胶囊菜单（一级/二级/三级导航）。
void showCapsuleMenu({
  required BuildContext context,
  required CapsuleMenuLevel level,
}) {
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (ctx, _, __) => _CapsuleNavigator(level: level),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.95, end: 1.0).animate(curved),
          alignment: Alignment.center,
          child: child,
        ),
      );
    },
  );
}

/// 导航栈容器：负责二级/三级 push/pop 与整体滚动。
class _CapsuleNavigator extends StatefulWidget {
  final CapsuleMenuLevel level;
  const _CapsuleNavigator({required this.level});

  @override
  State<_CapsuleNavigator> createState() => _CapsuleNavigatorState();
}

class _CapsuleNavigatorState extends State<_CapsuleNavigator> {
  final List<CapsuleMenuLevel> _stack = [];

  @override
  void initState() {
    super.initState();
    _stack.add(widget.level);
    // 弹层期间保持沉浸深色系统栏，避免闪白。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ));
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _push(CapsuleMenuLevel level) => setState(() => _stack.add(level));
  void _pop() =>
      setState(() { if (_stack.length > 1) _stack.removeLast(); });

  @override
  Widget build(BuildContext context) {
    final current = _stack.last;
    final maxHeight = MediaQuery.of(context).size.height * 0.72;
    final maxWidth = MediaQuery.of(context).size.width * 0.82;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: maxWidth),
        child: Container(
          decoration: BoxDecoration(
            color: CapsuleTokens.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: CapsuleTokens.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 30,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CapsuleHeader(
                    title: current.title,
                    onBack: _stack.length > 1 ? _pop : null,
                    onClose: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(height: 6),
                  for (final item in current.items)
                    _buildItem(item),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItem(CapsuleMenuItem item) {
    if (item.isSlider) {
      return _CapsuleSliderRow(
        label: item.label,
        value: item.sliderValue,
        valueLabel: item.sliderValueLabel,
        onChanged: item.onSlider!,
      );
    }
    return _CapsulePill(
      label: item.label,
      subLabel: item.subLabel,
      selected: item.selected,
      accentText: item.danger,
      trailing: item.isSwitch
          ? _CapsuleSwitch(value: item.value, onChanged: item.onChanged!)
          : item.next != null
              ? const _CapsuleChevron()
              : item.trailingLabel != null
                  ? _CapsuleMiniButton(item.trailingLabel!)
                  : null,
      onTap: () {
        if (item.next != null) {
          _push(item.next!);
        } else if (item.onTap != null && !item.isSwitch) {
          item.onTap!();
        }
      },
    );
  }
}

/// 标题栏（对齐 HTML .mtitle），支持返回/关闭。
class _CapsuleHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onClose;
  const _CapsuleHeader({
    required this.title,
    this.onBack,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (onBack != null) ...[
          InkWell(
            onTap: onBack,
            borderRadius: BorderRadius.circular(10),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.arrow_back_ios_new_rounded,
                  size: 15, color: CapsuleTokens.textSecondary),
            ),
          ),
        ],
        const SizedBox(width: 2),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: CapsuleTokens.textSecondary,
              fontSize: 10.5,
              letterSpacing: 0.5,
            ),
          ),
        ),
        if (onClose != null)
          InkWell(
            onTap: onClose,
            borderRadius: BorderRadius.circular(10),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.close_rounded,
                  size: 15, color: CapsuleTokens.textSecondary),
            ),
          ),
      ],
    );
  }
}

/// pill 菜单项（对齐 HTML .pill）。
class _CapsulePill extends StatelessWidget {
  final String label;
  final String? subLabel;
  final bool selected;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool accentText;
  const _CapsulePill({
    required this.label,
    this.subLabel,
    this.selected = false,
    this.trailing,
    this.onTap,
    this.accentText = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? CapsuleTokens.accentFill : CapsuleTokens.track,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: accentText
                      ? CapsuleTokens.accent
                      : CapsuleTokens.text,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (subLabel != null) ...[
              const SizedBox(width: 8),
              Text(
                subLabel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: CapsuleTokens.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            if (trailing == null && selected)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: _CheckDot(),
              ),
          ],
        ),
      ),
    );
  }
}

/// 迷你按钮（对齐 HTML .mini-btn）。
class _CapsuleMiniButton extends StatelessWidget {
  final String label;
  const _CapsuleMiniButton(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: CapsuleTokens.accentFill,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: CapsuleTokens.checkBlue,
          fontSize: 11,
        ),
      ),
    );
  }
}

/// 下一级箭头（三级入口标记）。
class _CapsuleChevron extends StatelessWidget {
  const _CapsuleChevron();

  @override
  Widget build(BuildContext context) {
    return const Icon(
      Icons.chevron_right_rounded,
      color: CapsuleTokens.textSecondary,
      size: 18,
    );
  }
}

/// 胶囊开关（对齐 HTML .sw）。
class _CapsuleSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _CapsuleSwitch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 30,
        height: 16,
        decoration: BoxDecoration(
          color: value ? CapsuleTokens.accent : CapsuleTokens.track,
          borderRadius: BorderRadius.circular(9),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 200),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 2),
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

/// 选中圆点（对齐 HTML .ck）。
class _CheckDot extends StatelessWidget {
  const _CheckDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: const BoxDecoration(
        color: CapsuleTokens.accent,
        shape: BoxShape.circle,
      ),
      child: const Center(
        child: SizedBox(
          width: 6,
          height: 6,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

/// 滑杆行（对齐 HTML .sl-row）。
class _CapsuleSliderRow extends StatefulWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final String? valueLabel;
  const _CapsuleSliderRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.valueLabel,
  });

  @override
  State<_CapsuleSliderRow> createState() => _CapsuleSliderRowState();
}

class _CapsuleSliderRowState extends State<_CapsuleSliderRow> {
  // 拖动中的本地值；null 表示未拖动，回退显示 widget.value。
  double? _dragValue;

  @override
  void didUpdateWidget(covariant _CapsuleSliderRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _dragValue = null;
  }

  void _set(double v) {
    setState(() => _dragValue = v.clamp(0.0, 1.0));
    widget.onChanged(v.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final value = _dragValue ?? widget.value.clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              widget.label,
              style: const TextStyle(
                color: Color(0xBFFFFFFF),
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) {
                    final dx =
                        details.localPosition.dx.clamp(0.0, constraints.maxWidth);
                    _set(dx / constraints.maxWidth);
                  },
                  onHorizontalDragUpdate: (details) {
                    final dx = details.localPosition.dx
                        .clamp(0.0, constraints.maxWidth);
                    _set(dx / constraints.maxWidth);
                  },
                  onHorizontalDragEnd: (_) {
                    setState(() => _dragValue = null);
                  },
                  child: Container(
                    height: 18,
                    alignment: Alignment.center,
                    child: Container(
                      height: 5,
                      decoration: BoxDecoration(
                        color: CapsuleTokens.track,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: value,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  Color(0xFFE94560),
                                  Color(0xFFFF8C42),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 34,
            child: Text(
              widget.valueLabel ?? '${(value * 100).round()}%',
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

/// 选项行（对应 HTML .pill 可点项）。
CapsuleMenuItem capsuleOption({
  required String label,
  String? subLabel,
  bool selected = false,
  VoidCallback? onTap,
  CapsuleMenuLevel? next,
  String? trailingLabel,
}) {
  return CapsuleMenuItem(
    label: label,
    subLabel: subLabel,
    selected: selected,
    onTap: onTap,
    next: next,
    trailingLabel: trailingLabel,
  );
}

/// 开关行（对应 HTML .pill + .sw）。
CapsuleMenuItem capsuleSwitch({
  required String label,
  required bool value,
  required ValueChanged<bool> onChanged,
  String? subLabel,
}) {
  return CapsuleMenuItem(
    label: label,
    value: value,
    onChanged: onChanged,
    subLabel: subLabel,
  );
}

/// 滑杆行（对应 HTML .sl-row）。
CapsuleMenuItem capsuleSlider({
  required String label,
  required double value,
  required ValueChanged<double> onChanged,
  String? valueLabel,
}) {
  return CapsuleMenuItem(
    label: label,
    sliderValue: value,
    onSlider: onChanged,
    sliderValueLabel: valueLabel,
  );
}

/// 纯信息行（对应 HTML .pill 仅展示）。
CapsuleMenuItem capsuleInfo({
  required String label,
  required String subLabel,
}) {
  return CapsuleMenuItem(
    label: label,
    subLabel: subLabel,
    info: true,
    onTap: null,
  );
}