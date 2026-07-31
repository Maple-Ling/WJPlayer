import 'package:flutter/material.dart';
import '../../../core/widgets/td_switch_tile.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../common/app_toast.dart';

/// 订阅「编辑」面板（对齐 ani-rss 原版订阅配置）。
///
/// 之前订阅页只能刷新/删除/启停，无法配置任何字段——这正是「基本没用」的根因。
/// 本面板覆盖 ani-rss 最常用的订阅字段，保存即 `setAni` 回写：
/// 标题 / 季 / 总集数 / 集数偏移 / 字幕组 / 包含·排除关键字 / 全局排除 /
/// 自定义下载位置 / OVA·剧场版 / 启用 / BGM 刮削地址。
Future<void> showAniRssEditSubscriptionSheet(
  BuildContext context,
  WidgetRef ref,
  AniModel ani,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: FractionallySizedBox(
        heightFactor: 0.92,
        child: _EditBody(ani: ani, parentRef: ref),
      ),
    ),
  );
}

class _EditBody extends StatefulWidget {
  final AniModel ani;
  final WidgetRef parentRef;
  const _EditBody({required this.ani, required this.parentRef});

  @override
  State<_EditBody> createState() => _EditBodyState();
}

class _EditBodyState extends State<_EditBody> {
  late final TextEditingController _title;
  late final TextEditingController _season;
  late final TextEditingController _total;
  late final TextEditingController _offset;
  late final TextEditingController _subgroup;
  late final TextEditingController _match;
  late final TextEditingController _exclude;
  late final TextEditingController _downloadPath;
  late final TextEditingController _bgmUrl;

  late bool _enable;
  late bool _ova;
  late bool _globalExclude;
  late bool _customDownloadPath;
  bool _saving = false;
  String? _error;

  AniModel get ani => widget.ani;

  int? _int(String key) => (ani.raw[key] as num?)?.toInt();

  /// match / exclude 在服务端是**字符串数组**；这里展开成「每行一条」编辑。
  String _listText(String key) {
    final v = ani.raw[key];
    if (v is List) return v.map((e) => e.toString()).join('\n');
    final s = (v ?? '').toString();
    return s.isEmpty ? '' : s;
  }

  /// 反向：把「每行一条」拆回字符串数组（去空白行）。
  List<String> _parseList(String text) => text
      .split(RegExp(r'[\n,]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: ani.title);
    _season = TextEditingController(text: (ani.season ?? 1).toString());
    _total = TextEditingController(
        text: (ani.totalEpisodeNumber ?? 0) > 0
            ? ani.totalEpisodeNumber.toString()
            : '');
    _offset =
        TextEditingController(text: (_int('offset') ?? 0).toString());
    _subgroup = TextEditingController(text: ani.subgroup ?? '');
    _match = TextEditingController(text: _listText('match'));
    _exclude = TextEditingController(text: _listText('exclude'));
    _downloadPath = TextEditingController(text: ani.downloadPath ?? '');
    _bgmUrl = TextEditingController(text: ani.bgmUrl ?? '');
    _enable = ani.enable;
    _ova = ani.ova;
    _globalExclude = ani.raw['globalExclude'] != false; // 缺省视为开
    _customDownloadPath = ani.raw['customDownloadPath'] == true;
  }

  @override
  void dispose() {
    _title.dispose();
    _season.dispose();
    _total.dispose();
    _offset.dispose();
    _subgroup.dispose();
    _match.dispose();
    _exclude.dispose();
    _downloadPath.dispose();
    _bgmUrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final api = widget.parentRef.read(aniRssApiProvider);
    if (api == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final overrides = <String, dynamic>{
        'title': _title.text.trim(),
        'season': int.tryParse(_season.text.trim()) ?? ani.season ?? 1,
        'totalEpisodeNumber': int.tryParse(_total.text.trim()) ?? 0,
        'offset': int.tryParse(_offset.text.trim()) ?? 0,
        'subgroup': _subgroup.text.trim(),
        'match': _parseList(_match.text),
        'exclude': _parseList(_exclude.text),
        'globalExclude': _globalExclude,
        'customDownloadPath': _customDownloadPath,
        if (_customDownloadPath) 'downloadPath': _downloadPath.text.trim(),
        'ova': _ova,
        'enable': _enable,
        'bgmUrl': _bgmUrl.text.trim(),
      };
      await api.setAni(ani.copyWithRaw(overrides));
      widget.parentRef.invalidate(aniListProvider);
      if (mounted) {
        Navigator.of(context).pop();
        AppToast.show(context, '订阅已保存');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text('编辑订阅',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check, size: 18),
                label: const Text('保存'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              _section('基本信息'),
              _text(_title, '标题'),
              Row(
                children: [
                  Expanded(child: _num(_season, '季')),
                  const SizedBox(width: 12),
                  Expanded(child: _num(_total, '总集数（0=未知）')),
                ],
              ),
              _num(_offset, '集数偏移（RSS 集号 + 偏移 = 实际集）'),
              _text(_subgroup, '字幕组'),
              const SizedBox(height: 8),
              _section('过滤规则'),
              _text(_match, '包含关键字 / 正则（可空）'),
              _text(_exclude, '排除关键字（多个用逗号或换行分隔）',
                  maxLines: 2),
              TdSwitchTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('应用全局排除规则'),
                value: _globalExclude,
                onChanged: (v) => setState(() => _globalExclude = v),
              ),
              const SizedBox(height: 8),
              _section('下载'),
              TdSwitchTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自定义下载位置'),
                value: _customDownloadPath,
                onChanged: (v) => setState(() => _customDownloadPath = v),
              ),
              if (_customDownloadPath) _text(_downloadPath, '下载路径'),
              const SizedBox(height: 8),
              _section('选项'),
              TdSwitchTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用订阅'),
                value: _enable,
                onChanged: (v) => setState(() => _enable = v),
              ),
              TdSwitchTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('OVA / 剧场版（不按季集匹配）'),
                value: _ova,
                onChanged: (v) => setState(() => _ova = v),
              ),
              const SizedBox(height: 8),
              _section('刮削'),
              _text(_bgmUrl, 'BGM 地址（用于刮削元数据）'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 6),
        child: Text(t,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary)),
      );

  Widget _text(TextEditingController c, String label, {int maxLines = 1}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          maxLines: maxLines,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );

  Widget _num(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );
}
