import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/feiniu_backend.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_playback.dart';
import '../../widgets/common/media_widgets.dart';

class FeiniuHomeScreen extends ConsumerStatefulWidget {
  const FeiniuHomeScreen({super.key});

  @override
  ConsumerState<FeiniuHomeScreen> createState() => _FeiniuHomeScreenState();
}

class _FeiniuHomeScreenState extends ConsumerState<FeiniuHomeScreen> {
  final FeiniuBackend _backend = FeiniuBackend();
  List<SourceEntry> _libraries = const [];
  final Map<String, List<SourceEntry>> _previews = {};
  String? _serverId;
  String? _error;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final server = ref.read(currentServerProvider);
    if (server != null && server.id != _serverId) {
      _serverId = server.id;
      Future<void>.microtask(_load);
    }
  }

  Future<void> _load() async {
    final server = ref.read(currentServerProvider);
    if (server == null || server.sourceKind != SourceKind.feiniu) return;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _previews.clear();
      });
    }
    try {
      final libraries = await _backend.libraries(server);
      if (!mounted || server.id != _serverId) return;
      setState(() {
        _libraries = libraries;
        _loading = false;
      });
      await Future.wait(libraries.map((library) async {
        try {
          final items = await _backend.libraryItems(server, library.id);
          if (mounted && server.id == _serverId) {
            setState(() => _previews[library.id] = items.take(12).toList());
          }
        } catch (_) {
          if (mounted && server.id == _serverId) {
            setState(() => _previews[library.id] = const []);
          }
        }
      }));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is SourceException ? e.message : '加载飞牛首页失败: $e';
      });
    }
  }

  void _openLibrary(ServerConfig server, SourceEntry library) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FeiniuLibraryScreen(server: server, root: library),
    ));
  }

  void _openEntry(ServerConfig server, SourceEntry entry) {
    if (entry.isDir) {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => FeiniuLibraryScreen(server: server, root: entry),
      ));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FeiniuDetailScreen(server: server, entry: entry),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(currentServerProvider);
    if (server == null || server.sourceKind != SourceKind.feiniu) {
      return const Scaffold(body: Center(child: Text('当前不是飞牛影视服务器')));
    }
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(server.name)),
        body: _ErrorRetry(message: _error!, onRetry: _load),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(server.name),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _libraries.isEmpty
            ? ListView(
                physics: AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(height: 260),
                  Center(child: Text('暂无媒体库')),
                ],
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: _libraries.length,
                itemBuilder: (context, index) {
                  final library = _libraries[index];
                  final preview = _previews[library.id];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 8, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                library.name,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            TextButton(
                              onPressed: () => _openLibrary(server, library),
                              child: const Text('查看全部'),
                            ),
                          ],
                        ),
                      ),
                      if (preview == null)
                        const SizedBox(
                          height: 190,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (preview.isEmpty)
                        const SizedBox(
                          height: 80,
                          child: Center(child: Text('暂无内容')),
                        )
                      else
                        SizedBox(
                          height: 220,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: preview.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 10),
                            itemBuilder: (_, i) => SizedBox(
                              width: 126,
                              child: _FeiniuMediaCard(
                                entry: preview[i],
                                onTap: () => _openEntry(server, preview[i]),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class FeiniuLibraryScreen extends StatefulWidget {
  const FeiniuLibraryScreen({
    super.key,
    required this.server,
    required this.root,
  });

  final ServerConfig server;
  final SourceEntry root;

  @override
  State<FeiniuLibraryScreen> createState() => _FeiniuLibraryScreenState();
}

class _FeiniuLibraryScreenState extends State<FeiniuLibraryScreen> {
  final FeiniuBackend _backend = FeiniuBackend();
  List<SourceEntry> _items = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _backend.listDir(widget.server, dirId: widget.root.id);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is SourceException ? e.message : '加载媒体库失败: $e';
      });
    }
  }

  void _open(SourceEntry entry) {
    if (entry.isDir) {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => FeiniuLibraryScreen(server: widget.server, root: entry),
      ));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FeiniuDetailScreen(server: widget.server, entry: entry),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.root.name),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorRetry(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _items.isEmpty
                      ? ListView(
                          physics: AlwaysScrollableScrollPhysics(),
                          children: [
                            SizedBox(height: 240),
                            Center(child: Text('暂无内容')),
                          ],
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 190,
                            childAspectRatio: 0.62,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 14,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (_, index) => _FeiniuMediaCard(
                            entry: _items[index],
                            onTap: () => _open(_items[index]),
                          ),
                        ),
                ),
    );
  }
}

class FeiniuDetailScreen extends StatefulWidget {
  const FeiniuDetailScreen({
    super.key,
    required this.server,
    required this.entry,
  });

  final ServerConfig server;
  final SourceEntry entry;

  @override
  State<FeiniuDetailScreen> createState() => _FeiniuDetailScreenState();
}

class _FeiniuDetailScreenState extends State<FeiniuDetailScreen> {
  final FeiniuBackend _backend = FeiniuBackend();
  FeiniuItemDetail? _detail;
  List<SourceEntry> _episodes = const [];
  String? _selectedSeason;
  String? _error;
  bool _loading = true;
  bool _loadingEpisodes = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await _backend.itemDetail(widget.server, widget.entry);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
      if (detail.seasons.isNotEmpty) {
        await _selectSeason(detail.seasons.first.id);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is SourceException ? e.message : '获取详情失败: $e';
      });
    }
  }

  Future<void> _selectSeason(String seasonId) async {
    setState(() {
      _selectedSeason = seasonId;
      _loadingEpisodes = true;
    });
    try {
      final episodes = await _backend.episodes(widget.server, seasonId);
      if (!mounted || _selectedSeason != seasonId) return;
      setState(() {
        _episodes = episodes;
        _loadingEpisodes = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _episodes = const [];
        _loadingEpisodes = false;
      });
    }
  }

  void _play(SourceEntry entry) {
    context.push('/source-player',
        extra: SourcePlayback(server: widget.server, entry: entry));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null || _detail == null) {
      return Scaffold(
        appBar: AppBar(),
        body: _ErrorRetry(message: _error ?? '详情为空', onRetry: _load),
      );
    }
    final detail = _detail!;
    final item = detail.item;
    final entry = detail.entry;
    final type = (detail.playInfo['type'] ?? item['type'] ?? entry.raw?['type'])
        ?.toString();
    final overview = item['overview']?.toString() ?? '';
    final backdrop = item['backdrops']?.toString() ?? '';
    final backdropUrl = _backend.imageUrl(widget.server, backdrop, width: 1200);
    final playable = type == 'Movie' || type == 'Video' || type == 'Episode';

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 260,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(entry.name, maxLines: 1),
              background: MediaImage(
                imageUrl: backdropUrl.isNotEmpty ? backdropUrl : entry.thumbUrl,
                httpHeaders: entry.thumbHeaders,
                fit: BoxFit.cover,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
            sliver: SliverList.list(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 116,
                      height: 170,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: MediaImage(
                          imageUrl: entry.thumbUrl,
                          httpHeaders: entry.thumbHeaders,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(entry.name,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          Text([
                            item['release_date'],
                            if (item['vote_average'] != null)
                              '评分 ${item['vote_average']}',
                            type,
                          ].where((e) => e != null && '$e'.isNotEmpty).join(' · ')),
                          if (playable) ...[
                            const SizedBox(height: 18),
                            FilledButton.icon(
                              onPressed: () => _play(entry),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: const Text('播放'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (overview.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('简介', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(overview, style: const TextStyle(height: 1.55)),
                ],
                if (detail.seasons.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text('剧集', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedSeason,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '季',
                    ),
                    items: detail.seasons
                        .map((season) => DropdownMenuItem(
                              value: season.id,
                              child: Text(season.name),
                            ))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) _selectSeason(value);
                    },
                  ),
                  const SizedBox(height: 12),
                  if (_loadingEpisodes)
                    const Center(child: CircularProgressIndicator())
                  else
                    ..._episodes.map((episode) => Card(
                          child: ListTile(
                            leading: SizedBox(
                              width: 72,
                              child: MediaImage(
                                imageUrl: episode.thumbUrl,
                                httpHeaders: episode.thumbHeaders,
                                fit: BoxFit.cover,
                              ),
                            ),
                            title: Text(episode.name),
                            trailing: const Icon(Icons.play_circle_outline),
                            onTap: () => _play(episode),
                          ),
                        )),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FeiniuMediaCard extends StatelessWidget {
  const _FeiniuMediaCard({required this.entry, required this.onTap});

  final SourceEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox.expand(
                child: entry.thumbUrl?.isNotEmpty == true
                    ? MediaImage(
                        imageUrl: entry.thumbUrl,
                        httpHeaders: entry.thumbHeaders,
                        fit: BoxFit.cover,
                      )
                    : ColoredBox(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: Icon(
                          entry.isDir ? Icons.folder_rounded : Icons.movie_rounded,
                          size: 42,
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            entry.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 1.25),
          ),
        ],
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 44),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
