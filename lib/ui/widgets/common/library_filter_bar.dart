import 'package:flutter/material.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/utils/library_filter_utils.dart';

/// 媒体库筛选面板（移动端 + 桌面端共用，Material）。
///
/// 分面取值（类型 / 标签 / 工作室 / 时间）来自 Emby 各分面专用端点。每个维度**一行**，
/// 默认空（显示「全部」），点该行弹出底部选择器（按拼音首字母排序）选一个值，选中后
/// 在该行回显，下方媒体库实时服务端过滤。再选「全部」即清除。标签承载「地区」等信息
/// ——Emby 无独立地区分面，国产刮削器通常写进 Tags。
class LibraryFilterBar extends StatelessWidget {
  final Filters facets;
  final LibraryFilterValue value;
  final int currentYear;
  final ValueChanged<LibraryFilterValue> onChanged;

  /// 紧凑模式（移动端）：类型/标签不再整行平铺胶囊（会占满屏幕），改为一行回显
  /// 当前值、点开带搜索的弹窗选择。桌面端宽屏保持平铺，传 false。
  final bool compact;

  const LibraryFilterBar({
    super.key,
    required this.facets,
    required this.value,
    required this.currentYear,
    required this.onChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final f = facets;
    final v = value;
    final yearChips = buildYearChips(f.years, currentYear: currentYear);

    final theme = Theme.of(context);
    final rows = <Widget>[];
    // 顺序（自上而下）：时间 → 类型 → 标签 → 评分 → 工作室。
    if (yearChips.isNotEmpty) {
      rows.add(_chipRow(theme, '时间', [
        for (final yc in yearChips)
          _chip(theme, yc.label, v.yearLabel == yc.label, () {
            final on = v.yearLabel == yc.label;
            onChanged(
                v.withYear(on ? null : yc.label, on ? null : yc.yearsCsv));
          }),
      ]));
    }
    // 类型/标签：桌面平铺可点选胶囊；移动端（compact）改为回显行 + 搜索弹窗选一个。
    if (f.genres.isNotEmpty) {
      if (compact) {
        rows.add(_pickerRow(theme, '类型', v.genre, () async {
          final picked = await _pick(context, '类型', f.genres, v.genre);
          if (picked != null) {
            onChanged(v.withGenre(picked.isEmpty ? null : picked));
          }
        }));
      } else {
        rows.add(_chipRow(theme, '类型', [
          for (final g in f.genres)
            _chip(theme, g, v.genre == g,
                () => onChanged(v.withGenre(v.genre == g ? null : g))),
        ]));
      }
    }
    if (f.tags.isNotEmpty) {
      if (compact) {
        rows.add(_pickerRow(theme, '标签', v.tag, () async {
          final picked =
              await _pick(context, '标签', sortByPinyin(f.tags), v.tag);
          if (picked != null) {
            onChanged(v.withTag(picked.isEmpty ? null : picked));
          }
        }));
      } else {
        rows.add(_chipRow(theme, '标签', [
          for (final t in f.tags)
            _chip(theme, t, v.tag == t,
                () => onChanged(v.withTag(v.tag == t ? null : t))),
        ]));
      }
    }
    // 评分区间始终可用（与分面无关）。
    rows.add(_RatingRow(value: v, onChanged: onChanged));
    // 工作室取值可能很多，单独成一行回显当前值，点开居中可搜索弹窗选。
    if (f.studios.isNotEmpty) {
      rows.add(_pickerRow(theme, '工作室', v.studio, () async {
        final picked =
            await _pick(context, '工作室', sortByPinyin(f.studios), v.studio);
        if (picked != null) {
          final name = picked.isEmpty ? null : picked;
          onChanged(v.withStudio(name, name == null ? null : f.studioIds[name]));
        }
      }));
    }
    // 最后一行：排序按钮（更新时间 / 标题排序 / 官方评级，各自升降序可切）。
    rows.add(_SortRow(value: v, onChanged: onChanged));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (v.activeCount > 0)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => onChanged(v.cleared()),
                icon: const Icon(Icons.restart_alt, size: 16),
                label: const Text('重置'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
              ),
            ),
          ...rows,
        ],
      ),
    );
  }

  /// 左侧维度标签胶囊。
  Widget _label(ThemeData theme, String label) {
    return Container(
      margin: const EdgeInsets.only(top: 4, right: 10),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 一行可点选胶囊（类型/标签/时间）。
  Widget _chipRow(ThemeData theme, String label, List<Widget> chips) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(theme, label),
          Expanded(child: Wrap(spacing: 6, runSpacing: 4, children: chips)),
        ],
      ),
    );
  }

  Widget _chip(ThemeData theme, String label, bool selected, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected
                ? theme.colorScheme.primary
                : theme.textTheme.bodyMedium?.color,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// 一行回显当前选中值（未选显示「全部」），整行可点开居中弹窗（工作室专用）。
  Widget _pickerRow(
      ThemeData theme, String label, String? selected, VoidCallback onTap) {
    final active = selected != null;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            _label(theme, label),
            Expanded(
              child: Text(
                selected ?? '全部',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: active ? theme.colorScheme.primary : theme.hintColor,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            Icon(Icons.keyboard_arrow_right, size: 18, color: theme.hintColor),
          ],
        ),
      ),
    );
  }

  /// 居中弹窗选择器：胶囊网格 + 右上角搜索框。返回 null=未改、''=全部、其余=选中值。
  Future<String?> _pick(BuildContext context, String title,
      List<String> options, String? current) {
    return showDialog<String>(
      context: context,
      builder: (ctx) =>
          _FacetPickerDialog(title: title, options: options, current: current),
    );
  }
}

/// 评分区间一行：[最低] - [最高] 两个数字框，回车/完成时套用（避免每次按键都重拉网格）。
class _RatingRow extends StatefulWidget {
  final LibraryFilterValue value;
  final ValueChanged<LibraryFilterValue> onChanged;
  const _RatingRow({required this.value, required this.onChanged});

  @override
  State<_RatingRow> createState() => _RatingRowState();
}

class _RatingRowState extends State<_RatingRow> {
  late final TextEditingController _min =
      TextEditingController(text: _fmt(widget.value.ratingMin));
  late final TextEditingController _max =
      TextEditingController(text: _fmt(widget.value.ratingMax));

  @override
  void didUpdateWidget(covariant _RatingRow old) {
    super.didUpdateWidget(old);
    // 外部「重置」清空时，同步回输入框。
    final v = widget.value;
    if (v.ratingMin == null &&
        v.ratingMax == null &&
        (_min.text.isNotEmpty || _max.text.isNotEmpty)) {
      _min.text = '';
      _max.text = '';
    }
  }

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  String _fmt(double? d) => d == null
      ? ''
      : (d == d.roundToDouble() ? d.toInt().toString() : d.toString());

  void _apply() {
    widget.onChanged(widget.value.withRating(
      double.tryParse(_min.text.trim()),
      double.tryParse(_max.text.trim()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            margin: const EdgeInsets.only(right: 10),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('评分',
                style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600)),
          ),
          _field(theme, _min, '最低'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('-', style: TextStyle(color: theme.hintColor)),
          ),
          _field(theme, _max, '最高'),
          const SizedBox(width: 8),
          Text('（0–10）',
              style: TextStyle(fontSize: 11, color: theme.hintColor)),
        ],
      ),
    );
  }

  Widget _field(ThemeData theme, TextEditingController c, String hint) {
    return SizedBox(
      width: 58,
      height: 34,
      child: TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _apply(),
        onEditingComplete: _apply,
      ),
    );
  }
}

/// 排序按钮行：更新时间 / 标题排序 / 官方评级。点选中项切升/降序，点未选中项切到该字段。
const List<({String label, String key})> kLibrarySortOptions = [
  (label: '更新时间', key: 'DateLastContentAdded'),
  (label: '标题排序', key: 'SortName'),
  (label: '官方评级', key: 'OfficialRating'),
];

class _SortRow extends StatelessWidget {
  final LibraryFilterValue value;
  final ValueChanged<LibraryFilterValue> onChanged;
  const _SortRow({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4, right: 10),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('排序',
                style: TextStyle(
                    fontSize: 12,
                    color: primary,
                    fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final o in kLibrarySortOptions)
                  _button(theme, o.label, o.key),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _button(ThemeData theme, String label, String key) {
    final selected = value.sortBy == key;
    final primary = theme.colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => onChanged(value.toggledSort(key)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? primary.withValues(alpha: 0.14)
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? primary : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                  fontSize: 13,
                  color: selected ? primary : theme.textTheme.bodyMedium?.color,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                )),
            if (selected) ...[
              const SizedBox(width: 2),
              Icon(
                value.sortDescending
                    ? Icons.arrow_downward
                    : Icons.arrow_upward,
                size: 15,
                color: primary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 居中的筛选取值选择器：标题 + 右上角实时搜索框（中文按拼音匹配），下方一个个胶囊，
/// 选中即返回。「全部」固定在最前用于清除。
class _FacetPickerDialog extends StatefulWidget {
  final String title;
  final List<String> options;
  final String? current;

  const _FacetPickerDialog({
    required this.title,
    required this.options,
    required this.current,
  });

  @override
  State<_FacetPickerDialog> createState() => _FacetPickerDialogState();
}

class _FacetPickerDialogState extends State<_FacetPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.options
        : widget.options
            .where((o) =>
                o.toLowerCase().contains(q) || pinyinOf(o).contains(q))
            .toList();

    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(widget.title,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  SizedBox(
                    width: 160,
                    height: 36,
                    child: TextField(
                      autofocus: false,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '搜索',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (q.isEmpty)
                        _capsule(theme, '全部', widget.current == null,
                            () => Navigator.pop(context, '')),
                      for (final o in filtered)
                        _capsule(theme, o, o == widget.current,
                            () => Navigator.pop(context, o)),
                      if (filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text('无匹配项',
                              style: TextStyle(
                                  fontSize: 13, color: theme.hintColor)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _capsule(
      ThemeData theme, String label, bool selected, VoidCallback onTap) {
    final primary = theme.colorScheme.primary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? primary.withValues(alpha: 0.14)
                : theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: selected ? primary : theme.textTheme.bodyMedium?.color,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
