import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/sources/feiniu_backend.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_playback.dart';
import 'unified_media_screens.dart';
import '../../widgets/common/media_widgets.dart';
import '../../widgets/common/media_metadata_badges.dart';

class FeiniuHomeScreen extends ConsumerStatefulWidget {
  const FeiniuHomeScreen({super.key});

  @override
  ConsumerState<FeiniuHomeScreen> createState() => _FeiniuHomeScreenState();
}

class _FeiniuHomeScreenState extends ConsumerState<FeiniuHomeScreen> {
  final FeiniuBackend _backend = FeiniuBackend();
  List<SourceEntry> _libraries = const [];
  List<FeiniuContinueItem> _continueItems = const [];
  final Map<String, List<SourceEntry>> _previews = {};
  String? _serverId;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final initial = ref.read(currentServerProvider);
    if (initial?.sourceKind == SourceKind.feiniu) {
      _serverId = initial!.id;
      Future<void>.microtask(_load);
    }
    ref.listenManual<ServerConfig?>(currentServerProvider, (previous, next) {
      if (next?.sourceKind == SourceKind.feiniu && next!.id != _serverId) {
        _serverId = next.id;
        Future<void>.microtask(_load);
      }
    });
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
      final results = await Future.wait<dynamic>([
        _backend.libraries(server),
        _backend.continueWatching(server).catchError(
              (_) => const <FeiniuContinueItem>[],
            ),
      ]);
      final libraries = results[0] as List<SourceEntry>;
      final continueItems = results[1] as List<FeiniuContinueItem>;
      if (!mounted || server.id != _serverId) return;
      setState(() {
        _libraries = libraries;
        _continueItems = continueItems;
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

  Future<void> _openEntry(ServerConfig server, SourceEntry entry) async {
    if (entry.isDir) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => FeiniuLibraryScreen(server: server, root: entry),
      ));
    } else {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => UnifiedMediaDetailScreen(
          server: server,
          entry: unifiedEntryFromSource(entry),
        ),
      ));
    }
    if (mounted) await _load();
  }

  Future<void> _openContinueDetail(
      ServerConfig server, FeiniuContinueItem item) async {
    await _openEntry(server, item.entry);
  }

  Future<void> _playContinue(
      ServerConfig server, FeiniuContinueItem item) async {
    await context.push(
      '/source-player',
      extra: SourcePlayback(server: server, entry: item.entry),
    );
    if (mounted) await _load();
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
        appBar: AppBar(
          automaticallyImplyLeading: false,
          centerTitle: true,
          title: _FeiniuServerSwitcher(current: server),
        ),
        body: _ErrorRetry(message: _error!, onRetry: _load),
      );
    }
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        title: _FeiniuServerSwitcher(current: server),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _libraries.isEmpty && _continueItems.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 260),
                  Center(child: Text('暂无媒体内容')),
                ],
              )
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  if (_continueItems.isNotEmpty)
                    _FeiniuContinueSection(
                      items: _continueItems,
                      onTap: (item) => _openContinueDetail(server, item),
                      onPlay: (item) => _playContinue(server, item),
                    ),
                  for (final library in _libraries)
                    _FeiniuLibrarySection(
                      library: library,
                      preview: _previews[library.id],
                      onOpenLibrary: () => _openLibrary(server, library),
                      onOpenEntry: (entry) => _openEntry(server, entry),
                    ),
                ],
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
  String _sortKey = 'create_time';
  bool _sortDescending = true;

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
      final items =
          await _backend.listDir(widget.server, dirId: widget.root.id);
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

  void _toggleSort(String key) {
    setState(() {
      if (_sortKey == key) {
        _sortDescending = !_sortDescending;
      } else {
        _sortKey = key;
        _sortDescending = key != 'title';
      }
    });
  }

  List<SourceEntry> get _sortedItems {
    final items = [..._items];
    Object value(SourceEntry entry) {
      final raw = entry.raw ?? const <String, dynamic>{};
      return switch (_sortKey) {
        'title' => entry.name.toLowerCase(),
        'year' => '${raw['year'] ?? raw['release_date'] ?? ''}',
        'rating' => (raw['vote_average'] as num?)?.toDouble() ?? -1.0,
        _ => '${raw['create_time'] ?? raw['created_at'] ?? ''}',
      };
    }

    items.sort((a, b) {
      final av = value(a);
      final bv = value(b);
      final result = av is num && bv is num
          ? av.compareTo(bv)
          : av.toString().compareTo(bv.toString());
      return _sortDescending ? -result : result;
    });
    return items;
  }

  void _open(SourceEntry entry) {
    if (entry.isDir) {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => FeiniuLibraryScreen(server: widget.server, root: entry),
      ));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          builder: (_) => UnifiedMediaDetailScreen(
            server: widget.server,
            entry: unifiedEntryFromSource(entry),
          ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.root.name),
        actions: [
          PopupMenuButton<String>(
            tooltip: '排序',
            icon: const Icon(Icons.sort_rounded),
            onSelected: _toggleSort,
            itemBuilder: (context) => [
              for (final option in const [
                (key: 'create_time', label: '入库时间'),
                (key: 'title', label: '标题排序'),
                (key: 'year', label: '出品年份'),
                (key: 'rating', label: '评分'),
              ])
                PopupMenuItem(
                  value: option.key,
                  child: Row(
                    children: [
                      Expanded(child: Text(option.label)),
                      if (_sortKey == option.key)
                        Icon(
                          _sortDescending
                              ? Icons.arrow_downward_rounded
                              : Icons.arrow_upward_rounded,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                    ],
                  ),
                ),
            ],
          ),
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
                            // 与首页 126dp 海报卡统一视觉尺寸；大屏仅增加列数。
                            maxCrossAxisExtent: 138,
                            childAspectRatio: 0.58,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 14,
                          ),
                          itemCount: _sortedItems.length,
                          itemBuilder: (_, index) => _FeiniuMediaCard(
                            entry: _sortedItems[index],
                            onTap: () => _open(_sortedItems[index]),
                          ),
                        ),
                ),
    );
  }
}

class _FeiniuServerSwitcher extends ConsumerWidget {
  const _FeiniuServerSwitcher({required this.current});

  final ServerConfig current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serverListProvider);
    return PopupMenuButton<String>(
      tooltip: '切换服务器',
      onSelected: (serverId) {
        if (serverId == '__manage__') {
          context.go('/servers');
          return;
        }
        final server = servers.where((item) => item.id == serverId).firstOrNull;
        if (server == null || server.id == current.id) return;
        ref.read(currentServerProvider.notifier).state = server;
        if (server.authToken != null || server.isFileBrowse) {
          ref.read(authStateProvider.notifier).state = AuthState.authenticated;
        }
        context.go('/home');
      },
      itemBuilder: (context) => [
        for (final server in servers)
          PopupMenuItem<String>(
            value: server.id,
            child: Row(
              children: [
                Icon(
                  server.sourceKind == SourceKind.feiniu
                      ? Icons.video_library_rounded
                      : server.isFileBrowse
                          ? Icons.cloud_rounded
                          : Icons.dns_rounded,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(server.name, overflow: TextOverflow.ellipsis),
                ),
                if (server.id == current.id)
                  const Icon(Icons.check_rounded, size: 18),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: '__manage__',
          child: Row(
            children: [
              Icon(Icons.settings_rounded, size: 20),
              SizedBox(width: 10),
              Text('管理服务器'),
            ],
          ),
        ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, maxWidth: 220),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.video_library_rounded, size: 22),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                current.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
          ],
        ),
      ),
    );
  }
}

class _FeiniuContinueSection extends StatelessWidget {
  const _FeiniuContinueSection({required this.items, required this.onTap, required this.onPlay});

  final List<FeiniuContinueItem> items;
  final ValueChanged<FeiniuContinueItem> onTap;
  final ValueChanged<FeiniuContinueItem> onPlay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
          child: Text(
            '继续观看',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        SizedBox(
          height: 166,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                width: 220,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onTap(item),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              GestureDetector(
                                onTap: () => onPlay(item),
                                child: MediaImage(
                                  imageUrl: item.entry.thumbUrl,
                                  httpHeaders: item.entry.thumbHeaders,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black54
                                    ],
                                  ),
                                ),
                              ),
                              Center(
                                child: GestureDetector(
                                  onTap: () => onPlay(item),
                                  child: const Icon(Icons.play_circle_fill_rounded,
                                      color: Colors.white, size: 42),
                                ),
                              ),
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: LinearProgressIndicator(
                                  value: item.progress,
                                  minHeight: 4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        item.entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '已观看 ${(item.progress * 100).round()}%',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FeiniuLibrarySection extends StatelessWidget {
  const _FeiniuLibrarySection({
    required this.library,
    required this.preview,
    required this.onOpenLibrary,
    required this.onOpenEntry,
  });

  final SourceEntry library;
  final List<SourceEntry>? preview;
  final VoidCallback onOpenLibrary;
  final ValueChanged<SourceEntry> onOpenEntry;

  @override
  Widget build(BuildContext context) {
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
              TextButton(onPressed: onOpenLibrary, child: const Text('查看全部')),
            ],
          ),
        ),
        if (preview == null)
          const SizedBox(
            height: 190,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (preview!.isEmpty)
          const SizedBox(height: 80, child: Center(child: Text('暂无内容')))
        else
          SizedBox(
            height: 220,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: preview!.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, index) => SizedBox(
                width: 126,
                child: _FeiniuMediaCard(
                  entry: preview![index],
                  onTap: () => onOpenEntry(preview![index]),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FeiniuMediaCard extends ConsumerWidget {
  const _FeiniuMediaCard({required this.entry, required this.onTap});

  final SourceEntry entry;
  final VoidCallback onTap;

  String _entryFormat(Map<String, dynamic> raw, String name) {
    final text = [
      name,
      raw['codec_name'],
      raw['video_codec'],
      raw['video_range'],
      raw['video_range_type'],
      raw['profile'],
    ].where((e) => e != null).join(' ').toLowerCase();
    final labels = <String>[];
    if (text.contains('dovi') ||
        text.contains('dolby') ||
        text.contains('dvhe')) {
      labels.add('DV');
    } else if (text.contains('hdr') || text.contains('smpte2084')) {
      labels.add('HDR');
    } else if (!entry.isDir) {
      labels.add('SDR');
    }
    if (text.contains('hevc') || text.contains('265')) {
      labels.add('265/HEVC');
    } else if (text.contains('h264') ||
        text.contains('264') ||
        text.contains('avc')) {
      labels.add('264');
    }
    return labels.join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final raw = entry.raw ?? const <String, dynamic>{};
    final providerIds = <String, String>{};
    for (final pair in [
      ('tmdb', raw['tmdb_id'] ?? raw['tmdb']),
      ('imdb', raw['imdb_id'] ?? raw['imdb']),
      ('douban', raw['douban_id'] ?? raw['douban']),
    ]) {
      final value = pair.$2?.toString().trim() ?? '';
      if (value.isNotEmpty) providerIds[pair.$1] = value;
    }
    final ratingItem = MediaItem(
      id: entry.id,
      name: entry.name,
      type:
          '${raw['type'] ?? ''}'.toLowerCase() == 'movie' ? 'Movie' : 'Series',
      providerIds: providerIds,
    );
    final format = _entryFormat(raw, entry.name);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (entry.thumbUrl?.isNotEmpty == true)
                    MediaImage(
                      imageUrl: entry.thumbUrl,
                      httpHeaders: entry.thumbHeaders,
                      fit: BoxFit.cover,
                    )
                  else
                    ColoredBox(
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Icon(
                        entry.isDir
                            ? Icons.folder_rounded
                            : Icons.movie_rounded,
                        size: 42,
                      ),
                    ),
                  if (!entry.isDir)
                    Positioned(
                      left: 7,
                      top: 7,
                      child: SelectedRatingBadge(item: ratingItem),
                    ),
                  if (format.isNotEmpty)
                    Positioned(
                      right: 7,
                      bottom: 7,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.76),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(format,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                ],
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
