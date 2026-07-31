import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/anirss/anirss_api.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../../../core/sources/anirss/models/bgm_info.dart';
import '../../../core/sources/anirss/models/discover.dart';
import '../common/app_toast.dart';
import '../common/media_widgets.dart';

/// 添加订阅的搜索源。
enum DiscoverSource { bgm, mikan, aniBT, animeGarden, rss }

extension DiscoverSourceLabel on DiscoverSource {
  String get label => switch (this) {
        DiscoverSource.bgm => 'BGM 搜索',
        DiscoverSource.mikan => 'Mikan 季度',
        DiscoverSource.aniBT => 'AniBT',
        DiscoverSource.animeGarden => 'AnimeGarden',
        DiscoverSource.rss => '自定义 RSS',
      };

  /// rssToAni 的 type 取值。
  String get rssType => switch (this) {
        DiscoverSource.aniBT => 'ani-bt',
        DiscoverSource.animeGarden => 'anime-garden',
        DiscoverSource.rss => 'other',
        _ => 'mikan',
      };
}

/// 统一候选项（各源归一后用同一套「选字幕组 → 生成订阅 → 预览 → 添加」流程）。
/// 三端（移动 sheet / 桌面 dialog / TV overlay）共用。
class AniRssCandidate {
  final String title;
  final String? cover;
  final double? score;
  final bool exists;
  final DiscoverSource source;

  /// BGM：subjectId；其余源用于拉字幕组的 id（bgmId / mikan url）。
  final String? bgmId;
  final String? mikanUrl;
  final String? bgmUrl;

  /// Mikan 已内联返回的字幕组（其余源需现拉）。
  final List<GroupModel> groups;

  const AniRssCandidate({
    required this.title,
    required this.source,
    this.cover,
    this.score,
    this.exists = false,
    this.bgmId,
    this.mikanUrl,
    this.bgmUrl,
    this.groups = const [],
  });

  factory AniRssCandidate.fromBgm(BgmInfoModel b) => AniRssCandidate(
        title: b.displayName,
        cover: b.image,
        score: b.score,
        source: DiscoverSource.bgm,
        bgmId: b.id,
        bgmUrl: b.url,
      );

  factory AniRssCandidate.fromMikan(MikanInfoModel m) => AniRssCandidate(
        title: m.title,
        cover: m.coverHttp,
        score: m.score,
        exists: m.exists,
        source: DiscoverSource.mikan,
        mikanUrl: m.url,
        bgmUrl: m.bgmUrl,
        bgmId: m.bangumiId,
        groups: m.groups,
      );

  factory AniRssCandidate.fromAnime(AnimeModel a) => AniRssCandidate(
        title: a.title.display,
        cover: a.coverHttp,
        score: a.rating,
        exists: a.exists,
        source: DiscoverSource.aniBT,
        bgmId: a.bgmId,
      );

  factory AniRssCandidate.fromAnimeGarden(MikanInfoModel m) => AniRssCandidate(
        title: m.title,
        cover: m.coverHttp,
        score: m.score,
        exists: m.exists,
        source: DiscoverSource.animeGarden,
        bgmId: m.bangumiId,
        bgmUrl: m.bgmUrl,
        groups: m.groups,
      );

  String get stableKey => '$source:${bgmId ?? mikanUrl ?? title}';
}

/// 把候选生成可添加的订阅 Ani（必要时弹字幕组选择）。取消返回 null。三端共用。
Future<AniModel?> resolveAniRssCandidate(
    BuildContext context, AniRssApi api, AniRssCandidate c) async {
  if (c.source == DiscoverSource.bgm) {
    if (c.bgmId == null || c.bgmId!.isEmpty) {
      throw Exception('缺少 BGM 条目 id');
    }
    return api.getAniBySubjectId(c.bgmId!);
  }
  var groups = c.groups;
  if (groups.isEmpty) {
    groups = switch (c.source) {
      DiscoverSource.mikan => await api.mikanGroup(c.mikanUrl ?? ''),
      DiscoverSource.aniBT => await api.aniBTGroup(c.bgmId ?? ''),
      DiscoverSource.animeGarden => await api.animeGardenGroup(c.bgmId ?? ''),
      _ => const <GroupModel>[],
    };
  }
  if (groups.isEmpty) throw Exception('未找到可用的字幕组/RSS');
  GroupModel group;
  if (groups.length == 1) {
    group = groups.first;
  } else {
    if (!context.mounted) return null;
    final picked = await showAniRssSubgroupPicker(context, groups);
    if (picked == null) return null;
    group = picked;
  }
  final rss = group.rss;
  if (rss == null || rss.isEmpty) throw Exception('该字幕组缺少 RSS 地址');
  return api.rssToAni(
    url: rss,
    type: c.source.rssType,
    bgmUrl: group.bgmUrl ?? c.bgmUrl,
    subgroup: group.displayName,
  );
}

/// 多搜索源「添加订阅」主体（Material，移动端 bottom sheet / 桌面 dialog 复用）。
///
/// 流程统一为：选源 → 列候选 → 选字幕组（必要时）→ rssToAni/getAniBySubjectId 生成订阅
/// → 可选 previewAni 预览匹配剧集 → addAni。
class AniRssAddSubscriptionBody extends StatefulWidget {
  final AniRssApi api;
  final WidgetRef parentRef;

  /// 添加成功后回调（宿主据此关闭 sheet/dialog）。
  final VoidCallback? onAdded;

  const AniRssAddSubscriptionBody({
    super.key,
    required this.api,
    required this.parentRef,
    this.onAdded,
  });

  @override
  State<AniRssAddSubscriptionBody> createState() =>
      _AniRssAddSubscriptionBodyState();
}

class _AniRssAddSubscriptionBodyState extends State<AniRssAddSubscriptionBody> {
  DiscoverSource _source = DiscoverSource.bgm;
  final _searchCtrl = TextEditingController();

  bool _loading = false;
  String? _error;
  String? _busyKey; // 正在添加/预览的候选 key
  List<AniRssCandidate> _candidates = const [];

  // Mikan 季度。
  List<SeasonModel> _seasons = const [];
  SeasonModel? _season;

  // 自定义 RSS 表单。
  final _rssUrlCtrl = TextEditingController();
  final _rssBgmCtrl = TextEditingController();
  final _rssSubgroupCtrl = TextEditingController(text: '未知字幕组');

  AniRssApi get api => widget.api;

  @override
  void initState() {
    super.initState();
    // 进入即载入「免输入」的源（Mikan/AniBT/AnimeGarden 列当前季）。
    // 默认 BGM 源等待用户输入，不自动加载。
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _rssUrlCtrl.dispose();
    _rssBgmCtrl.dispose();
    _rssSubgroupCtrl.dispose();
    super.dispose();
  }

  void _switchSource(DiscoverSource s) {
    if (s == _source) return;
    setState(() {
      _source = s;
      _candidates = const [];
      _error = null;
    });
    if (s != DiscoverSource.bgm && s != DiscoverSource.rss) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      switch (_source) {
        case DiscoverSource.bgm:
          final q = _searchCtrl.text.trim();
          if (q.isEmpty) {
            setState(() => _candidates = const []);
            break;
          }
          final r = await api.searchBgm(q);
          _candidates = r.map(AniRssCandidate.fromBgm).toList();
          break;
        case DiscoverSource.mikan:
          final m = await api.mikan(
              text: _searchCtrl.text.trim(), season: _season);
          if (_seasons.isEmpty && m.seasons.isNotEmpty) {
            _seasons = m.seasons;
            _season = m.seasons.firstWhere((s) => s.select,
                orElse: () => m.seasons.first);
          }
          _candidates = m.allItems.map(AniRssCandidate.fromMikan).toList();
          break;
        case DiscoverSource.aniBT:
          final b = await api.aniBT();
          _candidates = b.allAnimes.map(AniRssCandidate.fromAnime).toList();
          break;
        case DiscoverSource.animeGarden:
          final weeks = await api.animeGardenList();
          final items = <MikanInfoModel>[];
          final seen = <String>{};
          for (final w in weeks) {
            for (final it in w.items) {
              final key = it.bangumiId ?? it.url ?? it.title;
              if (key.isEmpty || !seen.add(key)) continue;
              items.add(it);
            }
          }
          _candidates =
              items.map(AniRssCandidate.fromAnimeGarden).toList();
          break;
        case DiscoverSource.rss:
          break;
      }
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add(AniRssCandidate c, {bool preview = false}) async {
    final key = c.stableKey;
    setState(() => _busyKey = key);
    try {
      final ani = await resolveAniRssCandidate(context, api, c);
      if (ani == null) {
        setState(() => _busyKey = null);
        return;
      }
      if (preview) {
        if (!mounted) return;
        final ok = await showAniRssPreviewDialog(context, api, ani);
        if (ok != true) {
          if (mounted) setState(() => _busyKey = null);
          return;
        }
      }
      await api.addAni(ani);
      widget.parentRef.invalidate(aniListProvider);
      if (!mounted) return;
      _toast('已添加订阅「${c.title}」');
      widget.onAdded?.call();
    } catch (e) {
      if (mounted) {
        setState(() => _busyKey = null);
        _toast('添加失败：$e');
      }
    }
  }

  Future<void> _addFromRss({bool preview = false}) async {
    final url = _rssUrlCtrl.text.trim();
    if (url.isEmpty) {
      _toast('请填写 RSS 地址');
      return;
    }
    setState(() => _busyKey = 'rss');
    try {
      final ani = await api.rssToAni(
        url: url,
        type: DiscoverSource.rss.rssType,
        bgmUrl: _rssBgmCtrl.text.trim().isEmpty ? null : _rssBgmCtrl.text.trim(),
        subgroup: _rssSubgroupCtrl.text.trim().isEmpty
            ? '未知字幕组'
            : _rssSubgroupCtrl.text.trim(),
      );
      if (preview) {
        if (!mounted) return;
        final ok = await showAniRssPreviewDialog(context, api, ani);
        if (ok != true) {
          if (mounted) setState(() => _busyKey = null);
          return;
        }
      }
      await api.addAni(ani);
      widget.parentRef.invalidate(aniListProvider);
      if (!mounted) return;
      _toast('已添加订阅');
      widget.onAdded?.call();
    } catch (e) {
      if (mounted) {
        setState(() => _busyKey = null);
        _toast('添加失败：$e');
      }
    }
  }

  void _toast(String msg) {
    AppToast.show(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('添加订阅',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        _sourceSelector(),
        const SizedBox(height: 12),
        if (_source == DiscoverSource.rss)
          _rssForm()
        else ...[
          if (_source == DiscoverSource.bgm || _source == DiscoverSource.mikan)
            _searchRow(),
          if (_source == DiscoverSource.mikan && _seasons.isNotEmpty) ...[
            const SizedBox(height: 8),
            _seasonSelector(),
          ],
          const SizedBox(height: 12),
          Expanded(child: _resultsArea()),
        ],
      ],
    );
  }

  Widget _sourceSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final s in DiscoverSource.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(s.label),
                selected: _source == s,
                onSelected: (_) => _switchSource(s),
              ),
            ),
        ],
      ),
    );
  }

  Widget _searchRow() {
    final hint = switch (_source) {
      DiscoverSource.bgm => '输入番剧名（BGM 搜索）',
      DiscoverSource.mikan => '在 Mikan 季度内筛选（可留空）',
      _ => '在结果内筛选（可留空）',
    };
    final canSearch = _source == DiscoverSource.bgm ||
        _source == DiscoverSource.mikan;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              hintText: hint,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.search),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _loading ? null : _load,
          child: Text(canSearch ? '搜索' : '刷新'),
        ),
      ],
    );
  }

  Widget _seasonSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final s in _seasons)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(s.label),
                selected: _season?.label == s.label,
                onSelected: (_) {
                  setState(() => _season = s);
                  _load();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _rssForm() {
    final busy = _busyKey == 'rss';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _rssUrlCtrl,
            decoration: const InputDecoration(
              labelText: 'RSS 地址 *',
              hintText: 'https://mikanani.me/RSS/...',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _rssBgmCtrl,
            decoration: const InputDecoration(
              labelText: 'BGM 地址（可选，用于刮削）',
              hintText: 'https://bgm.tv/subject/...',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _rssSubgroupCtrl,
            decoration: const InputDecoration(
              labelText: '字幕组名',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => _addFromRss(preview: true),
                  icon: const Icon(Icons.preview_outlined),
                  label: const Text('预览'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : () => _addFromRss(),
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add),
                  label: const Text('添加'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _resultsArea() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_candidates.isEmpty) {
      final msg = _source == DiscoverSource.bgm
          ? '输入关键词后点搜索'
          : '暂无数据';
      return Center(
          child: Text(msg, style: const TextStyle(color: Colors.grey)));
    }
    return ListView.separated(
      itemCount: _candidates.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) => _candidateTile(_candidates[i]),
    );
  }

  Widget _candidateTile(AniRssCandidate c) {
    final busy = _busyKey == c.stableKey;
    final subtitle = <String>[
      if (c.score != null && c.score! > 0) '★ ${c.score!.toStringAsFixed(1)}',
      if (c.exists) '已订阅',
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 44,
        height: 60,
        child: MediaImage(
          imageUrl: c.cover,
          fit: BoxFit.cover,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
      trailing: busy
          ? const SizedBox(
              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '预览匹配',
                  icon: const Icon(Icons.preview_outlined),
                  onPressed:
                      _busyKey != null ? null : () => _add(c, preview: true),
                ),
                FilledButton.tonal(
                  onPressed: _busyKey != null ? null : () => _add(c),
                  child: const Text('添加'),
                ),
              ],
            ),
    );
  }
}

/// 字幕组选择对话框（多源共用）。返回选中的 [GroupModel]，取消返回 null。
Future<GroupModel?> showAniRssSubgroupPicker(
    BuildContext context, List<GroupModel> groups) {
  return showDialog<GroupModel>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('选择字幕组'),
      children: [
        for (final g in groups)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, g),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.rss_feed),
              title: Text(g.displayName,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: g.updateDay != null && g.updateDay!.isNotEmpty
                  ? Text('更新：${g.updateDay}',
                      maxLines: 1, overflow: TextOverflow.ellipsis)
                  : null,
            ),
          ),
      ],
    ),
  );
}

/// 预览订阅会匹配到的剧集（添加前确认）。点「添加」返回 true。
Future<bool?> showAniRssPreviewDialog(
    BuildContext context, AniRssApi api, AniModel ani) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => _PreviewDialog(api: api, ani: ani),
  );
}

class _PreviewDialog extends StatefulWidget {
  final AniRssApi api;
  final AniModel ani;
  const _PreviewDialog({required this.api, required this.ani});

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final preview = await widget.api.previewAni(widget.ani);
      setState(() {
        _items = AniRssApi.itemsOf(preview);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('预览匹配 · ${widget.ani.title}'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: _body(),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认添加')),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text(_error!, textAlign: TextAlign.center));
    }
    if (_items.isEmpty) {
      return const Center(
          child: Text('未匹配到剧集（仍可添加，后续自动追番）',
              style: TextStyle(color: Colors.grey)));
    }
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final it = _items[i];
        final title = (it['reName'] ?? it['title'] ?? it['name'] ?? '')
            .toString();
        final size = it['formatSize']?.toString();
        final ep = it['episode'];
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: ep != null
              ? CircleAvatar(
                  radius: 14,
                  child: Text((ep as num).toString(),
                      style: const TextStyle(fontSize: 11)))
              : const Icon(Icons.movie_outlined, size: 20),
          title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: size != null ? Text(size) : null,
        );
      },
    );
  }
}
