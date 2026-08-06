import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/api/discover/discover_models.dart';
import '../../../core/api/discover/external_media_models.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/external_media_providers.dart';
import '../../../core/providers/discover_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/providers/playback_providers.dart';
import '../../../core/providers/unified_resource_provider.dart';
import '../../../core/providers/server_card_stats_provider.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/providers/watch_history_providers.dart';
import '../../../core/services/watch_history/watch_history_models.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_playback.dart';
import '../../../core/sources/unified_media_adapter.dart';
import '../../widgets/common/collapsible_overview.dart';
import '../../widgets/common/media_metadata_badges.dart';
import '../../widgets/common/media_widgets.dart';
import '../../widgets/common/adaptive_poster_blend.dart';
import '../../widgets/common/playback_resource_card.dart';
import '../../utils/media_helpers.dart';
import '../discover/external_media_detail_screen.dart';

UnifiedMediaEntry unifiedEntryFromSource(SourceEntry source) => UnifiedMediaEntry(
      id: source.id,
      name: source.name,
      type: source.raw?['type']?.toString() ?? (source.isDir ? 'TV' : 'Movie'),
      posterUrl: source.thumbUrl,
      imageHeaders: source.thumbHeaders,
      sourceEntry: source,
    );

/// go_router /detail/:id 的扩展参数：携带真实服务器与完整 entry 打开详情页，
/// 供搜索/历史/飞牛库等入口使用（避免手动 Navigator.push 与 shell 混用）。
class UnifiedMediaDetailRouteExtra {
  const UnifiedMediaDetailRouteExtra({
    required this.server,
    required this.entry,
    this.autoPlay = false,
  });

  final ServerConfig server;
  final UnifiedMediaEntry entry;
  final bool autoPlay;
}


class UnifiedEmbyDetailRoute extends ConsumerWidget {
  const UnifiedEmbyDetailRoute({
    super.key,
    required this.itemId,
    this.autoPlay = false,
  });

  final String itemId;
  final bool autoPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(currentServerProvider);
    if (server == null) {
      return const Scaffold(body: Center(child: Text('请先选择服务器')));
    }
    return UnifiedMediaDetailScreen(
      server: server,
      entry: UnifiedMediaEntry(id: itemId, name: '', type: 'Movie'),
      autoPlay: autoPlay,
    );
  }
}

/// 飞牛视觉标准的统一影视首页。Emby 与飞牛仅替换数据适配器，不再切换页面。
class UnifiedMediaHomeScreen extends ConsumerStatefulWidget {
  const UnifiedMediaHomeScreen({super.key});

  @override
  ConsumerState<UnifiedMediaHomeScreen> createState() =>
      _UnifiedMediaHomeScreenState();
}

class _UnifiedMediaHomeScreenState
    extends ConsumerState<UnifiedMediaHomeScreen> {
  List<UnifiedMediaLibrary> _libraries = const [];
  List<UnifiedContinueItem> _continueItems = const [];
  final Map<String, List<UnifiedMediaEntry>> _previews = {};
  String? _serverId;
  String? _error;
  bool _loading = true;

  UnifiedMediaAdapter _adapter(ServerConfig server) => unifiedMediaAdapterFor(
        server,
        embyApi: server.sourceKind == SourceKind.emby
            ? ref.read(apiClientProvider)
            : null,
      );

  @override
  void initState() {
    super.initState();
    final initial = ref.read(currentServerProvider);
    if (initial != null) {
      _serverId = initial.id;
      Future<void>.microtask(_load);
    }
    ref.listenManual<ServerConfig?>(currentServerProvider, (previous, next) {
      if (next != null && next.id != _serverId) {
        _serverId = next.id;
        Future<void>.microtask(_load);
      }
    });
  }

  Future<void> _load() async {
    final server = ref.read(currentServerProvider);
    if (server == null ||
        (server.sourceKind != SourceKind.emby &&
            server.sourceKind != SourceKind.feiniu)) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _previews.clear();
    });
    final adapter = _adapter(server);
    try {
      final results = await Future.wait<dynamic>([
        adapter.libraries(),
        adapter.continueWatching().catchError(
              (_) => const <UnifiedContinueItem>[],
            ),
      ]);
      if (!mounted || server.id != _serverId) return;
      final hiddenLibraries = ref.read(hiddenLibrariesProvider);
      final libraries = (results[0] as List<UnifiedMediaLibrary>)
          .where((library) => !hiddenLibraries.contains(library.id))
          .toList();
      setState(() {
        _libraries = libraries;
        _continueItems = results[1] as List<UnifiedContinueItem>;
        _loading = false;
      });
      await Future.wait(libraries.map((library) async {
        try {
          final items = await adapter.preview(library.id);
          if (mounted && server.id == _serverId) {
            setState(() => _previews[library.id] = items);
          }
        } catch (_) {
          if (mounted && server.id == _serverId) {
            setState(() => _previews[library.id] = const []);
          }
        }
      }));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载影视首页失败: $error';
      });
    }
  }

  bool _navInFlight = false;

  Future<void> _openEntry(ServerConfig server, UnifiedMediaEntry entry) async {
    if (_navInFlight) return;
    _navInFlight = true;
    try {
      ref.read(currentServerProvider.notifier).state = server;
      // 直接使用影视详情页组件（真实 entry），飞牛/emby 均走统一影视详情 UI。
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UnifiedMediaDetailScreen(
            server: server,
            entry: entry,
          ),
        ),
      );
    } finally {
      _navInFlight = false;
    }
  }

  Future<void> _openContinueDetail(
      ServerConfig server, UnifiedContinueItem item) async {
    await _openEntry(server, item.entry);
  }

  Future<void> _playContinue(
      ServerConfig server, UnifiedContinueItem item) async {
    if (_navInFlight) return;
    _navInFlight = true;
    try {
      ref.read(currentServerProvider.notifier).state = server;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UnifiedMediaDetailScreen(
            server: server,
            entry: item.entry,
            autoPlay: true,
          ),
        ),
      );
      if (mounted) await _load();
    } finally {
      _navInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(currentServerProvider);
    if (server == null) {
      return const Scaffold(body: Center(child: Text('请先添加服务器')));
    }
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        leadingWidth: 96,
        leading: _UnifiedServerStats(current: server),
        title: _UnifiedServerSwitcher(current: server),
        actions: [
          _ServerLineAction(server: server, onChanged: _load),
        ],
      ),
      body: _error != null
          ? _ErrorRetry(message: _error!, onRetry: _load)
          : RefreshIndicator(
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
                          _ContinueSection(
                            items: _continueItems,
                            onTap: (item) => _openContinueDetail(server, item),
                            onPlay: (item) => _playContinue(server, item),
                          ),
                        for (final library in _libraries)
                          _LibrarySection(
                            library: library,
                            preview: _previews[library.id],
                            onOpenLibrary: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => UnifiedMediaLibraryScreen(
                                  server: server,
                                  library: library,
                                ),
                              ),
                            ),
                            onOpenEntry: (entry) => _openEntry(server, entry),
                          ),
                      ],
                    ),
            ),
    );
  }
}

class UnifiedMediaLibraryScreen extends ConsumerStatefulWidget {
  const UnifiedMediaLibraryScreen({
    super.key,
    required this.server,
    required this.library,
  });

  final ServerConfig server;
  final UnifiedMediaLibrary library;

  @override
  ConsumerState<UnifiedMediaLibraryScreen> createState() =>
      _UnifiedMediaLibraryScreenState();
}

class _UnifiedMediaLibraryScreenState
    extends ConsumerState<UnifiedMediaLibraryScreen> {
  List<UnifiedMediaEntry> _items = const [];
  String _sortKey = 'create_time';
  bool _descending = true;
  String? _error;
  bool _loading = true;

  UnifiedMediaAdapter get _adapter => unifiedMediaAdapterFor(
        widget.server,
        embyApi: widget.server.sourceKind == SourceKind.emby
            ? ref.read(apiClientProvider)
            : null,
      );

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _adapter.libraryItems(widget.library.id);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载媒体库失败: $error';
      });
    }
  }

  List<UnifiedMediaEntry> get _sortedItems {
    final items = [..._items];
    // 与影视栏"查看更多"排序逻辑完全一致：
    // create_time 保持入库顺序（倒序时反转）；标题 A-Z；年份升序；评分降序；再按方向反转。
    if (_sortKey == 'create_time') {
      return _descending ? items : items.reversed.toList();
    }
    int compare(UnifiedMediaEntry a, UnifiedMediaEntry b) {
      return switch (_sortKey) {
        'rating' => (b.rating ?? -1).compareTo(a.rating ?? -1),
        'title' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        'year' => (a.year ?? 0).compareTo(b.year ?? 0),
        _ => 0,
      };
    }

    items.sort((a, b) {
      final value = compare(a, b);
      return _descending ? -value : value;
    });
    return items;
  }

  void _toggleSort(String key) {
    setState(() {
      if (_sortKey == key) {
        _descending = !_descending;
      } else {
        _sortKey = key;
        _descending = key != 'title';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.library.name),
        // 排序：复用影视栏"查看更多"的排序选项与展示（kDiscoverSortOptions + 勾选态）。
        actions: [
          PopupMenuButton<String>(
            tooltip: '排序',
            icon: const Icon(Icons.sort_rounded),
            onSelected: _toggleSort,
            itemBuilder: (_) => [
              for (final option in kDiscoverSortOptions)
                PopupMenuItem(
                  value: option.key,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(option.label),
                      if (option.key == _sortKey)
                        const Icon(Icons.check_rounded,
                            size: 18, color: Color(0xFF34C759)),
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
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 240),
                            Center(child: Text('暂无内容')),
                          ],
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 138,
                            childAspectRatio: 0.58,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 14,
                          ),
                          itemCount: _sortedItems.length,
                          itemBuilder: (_, index) {
                            final entry = _sortedItems[index];
                            return _UnifiedMediaCard(
                              entry: entry,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => UnifiedMediaDetailScreen(
                                    server: widget.server,
                                    entry: entry,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
    );
  }
}

/// 飞牛详情视觉标准的统一详情页。
/// A 模板分集展示模型：由 UnifiedMediaEntry 转换而来（转换层），
/// 仅承载 A 页分段胶囊/剧集卡片所需展示字段，保留业务引用 [entry]。
class _UiEpisode {
  const _UiEpisode({
    required this.number,
    required this.name,
    required this.entry,
    this.overview,
    this.stillUrl,
    this.airDate,
    this.runtime,
  });

  final int number;
  final String name;
  final String? overview;
  final String? stillUrl;
  final String? airDate;
  final int? runtime;
  final UnifiedMediaEntry entry;
}

class UnifiedMediaDetailScreen extends ConsumerStatefulWidget {
  const UnifiedMediaDetailScreen({
    super.key,
    required this.server,
    required this.entry,
    this.autoPlay = false,
  });

  final ServerConfig server;
  final UnifiedMediaEntry entry;
  final bool autoPlay;

  @override
  ConsumerState<UnifiedMediaDetailScreen> createState() =>
      _UnifiedMediaDetailScreenState();
}


class _UnifiedMediaDetailScreenState
    extends ConsumerState<UnifiedMediaDetailScreen> {
  UnifiedMediaDetail? _detail;
  List<UnifiedMediaEntry> _episodes = const [];
  List<UnifiedMediaResource> _resources = const [];
  UnifiedMediaEntry? _selectedEntry;
  String? _selectedSeasonId;
  int _resourceIndex = 0;
  int _audioIndex = 0;
  int _subtitleIndex = -1;
  int _selectedCrossServerIndex = 0;
  // 单击跨服务器资源卡选中的匹配（用于顶部播放按钮直接播放该服务器资源）。
  ServerMatchInfo? _selectedCrossServerMatch;
  int _lastWatchedEpIndex = 0;
  String _core = 'nativeMpv';
  bool _loading = true;
  bool _loadingMedia = false;
  String? _error;
  ExternalMediaDetail? _externalDetail;
  Color? _backgroundColor;
  int _generation = 0;
  int? _resumePositionTicks;
  int? _resumeRuntimeTicks;
  List<WatchHistoryRecord> _scopeRecords = const [];
  final Map<String, UnifiedMediaDetail> _detailCache = {};
  final Map<String, List<UnifiedMediaResource>> _resourceCache = {};
  final ScrollController _episodeController = ScrollController();

  UnifiedMediaAdapter get _adapter => unifiedMediaAdapterFor(
        widget.server,
        embyApi: widget.server.sourceKind == SourceKind.emby
            ? ref.read(apiClientProvider)
            : null,
      );

  bool get _isSeries => _detail?.seasons.isNotEmpty == true;
  UnifiedMediaResource? get _resource =>
      _resources.isEmpty ? null : _resources[_resourceIndex];

  @override
  void initState() {
    super.initState();
    _core = normalizePlayerCore(ref.read(playerCoreProvider));
    Future<void>.microtask(_load);
  }

  @override
  void dispose() {
    _episodeController.dispose();
    super.dispose();
  }

  Future<void> _loadPlaybackHistory() async {
    final scopeKey = buildWatchHistoryScopeKey(widget.server);
    if (scopeKey == null) return;
    try {
      _scopeRecords = await ref.read(watchHistoryProvider).loadScope(scopeKey);
      final matching = _scopeRecords.where((record) =>
          record.sourceEntryId == widget.entry.id ||
          record.lastEmbyItemId == widget.entry.id);
      final record = matching.isNotEmpty ? matching.first : null;
      final core = record?.playerCore;
      _core = core != null && core.isNotEmpty
          ? normalizePlayerCore(core)
          : normalizePlayerCore(ref.read(playerCoreProvider));
    } catch (_) {
      _scopeRecords = const [];
      _core = normalizePlayerCore(ref.read(playerCoreProvider));
    }
  }

  Future<void> _load() async {
    final cacheKey = '${widget.server.id}:${widget.entry.id}';
    final cached = _detailCache[cacheKey];
    if (cached != null) {
      _detail = cached;
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await _adapter.detail(widget.entry);
      if (!mounted) return;
      _detailCache[cacheKey] = detail;
      _detail = detail;
      // 外部详情（TMDB/豆瓣演员、剧照、推荐等）与季/集加载并行，
      // 避免外部接口慢时详情页长时间停在 loading（进入卡顿感）。
      unawaited(_loadExternalDetail(detail.entry));
      final scopeKey = buildWatchHistoryScopeKey(widget.server);
      if (scopeKey != null) {
        _scopeRecords = await ref.read(watchHistoryProvider).loadScope(scopeKey);
        final matching = _scopeRecords.where((record) =>
            record.sourceEntryId == widget.entry.id ||
            record.lastEmbyItemId == widget.entry.id);
        final record = matching.isNotEmpty ? matching.first : null;
        final core = record?.playerCore;
        if (core != null && core.isNotEmpty) {
          _core = normalizePlayerCore(core);
        } else {
          _core = normalizePlayerCore(ref.read(playerCoreProvider));
        }
      }
      if (detail.seasons.isNotEmpty) {
        final preferred = detail.seasons.where((season) {
          final id = season.id.contains(':')
              ? season.id.substring(season.id.indexOf(':') + 1)
              : season.id;
          return season.id == detail.initialSeasonId || id == detail.initialSeasonId;
        }).firstOrNull;
        await _selectSeason((preferred ?? detail.seasons.first).id);
      } else {
        _selectedEntry = detail.entry;
        await _loadResources(detail.entry);
        if (widget.autoPlay && mounted) await _play();
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '获取媒体详情失败: $error';
      });
    }
  }

  Future<void> _loadExternalDetail(UnifiedMediaEntry entry) async {
    final selectedSource = ref.read(reviewSourceProvider);
    final discoverEntry = DiscoverEntry(
      id: switch (selectedSource) {
        ReviewSource.tmdb => entry.providerIds['tmdb'] ?? entry.id,
        ReviewSource.imdb => entry.providerIds['imdb'] ?? entry.id,
        ReviewSource.douban => entry.providerIds['douban'] ?? entry.id,
      },
      title: entry.name,
      source: selectedSource,
      posterUrl: entry.posterUrl,
      backdropUrl: entry.backdropUrl,
      rating: entry.rating,
      year: entry.year?.toString(),
      overview: entry.overview,
      mediaType: entry.isSeries ? 'tv' : 'movie',
      tmdbId: entry.providerIds['tmdb'],
      imdbId: entry.providerIds['imdb'],
      doubanId: entry.providerIds['douban'],
    );
    try {
      _externalDetail = await ref
          .read(externalMediaServiceProvider)
          .detail(discoverEntry, source: selectedSource);
    } catch (_) {
      _externalDetail = null;
    }
    // 并行加载完成后刷新界面（进入时不再被 await 阻塞）。
    if (mounted) setState(() {});
  }

  Future<void> _selectSeason(String seasonId) async {
    setState(() {
      _selectedSeasonId = seasonId;
      _episodes = const [];
      _loadingMedia = true;
    });
    try {
      final detail = _detail!;
      final episodes = await _adapter.episodes(
        detail.seriesId ?? detail.entry.id,
        seasonId,
      );
      if (!mounted || _selectedSeasonId != seasonId) return;
      final preferred = episodes
          .where((episode) => episode.id == detail.initialEntryId)
          .firstOrNull;
      final selected =
          preferred ?? (episodes.isEmpty ? null : episodes.first);
      setState(() {
        _episodes = episodes;
        _selectedEntry = selected;
        _loadingMedia = selected != null;
        if (_scopeRecords.isNotEmpty) {
          _lastWatchedEpIndex = _lastWatchedEpisodeIndex(episodes);
        }
      });
      if (selected != null) {
        await _loadResources(selected);
        if (widget.autoPlay && mounted) await _play();
      }
      // Q5：进入详情后，自动无感滑动到最近播放的剧集（若有）。
      if (_lastWatchedEpIndex > 0 && _episodeController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_episodeController.hasClients) return;
          _episodeController.jumpTo(
            (_lastWatchedEpIndex * 228.0)
                .clamp(0.0, _episodeController.position.maxScrollExtent),
          );
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _episodes = const [];
        _selectedEntry = null;
        _loadingMedia = false;
      });
    }
  }

  Future<void> _selectEpisode(UnifiedMediaEntry entry) async {
    if (_selectedEntry?.id == entry.id) return;
    final cached = _resourceCache[entry.id];
    setState(() {
      _selectedEntry = entry;
      _updateResume(entry);
      if (cached != null) {
        _resources = cached;
        _resourceIndex = 0;
        _normalizeTracks();
      }
    });
    if (cached == null) await _loadResources(entry, showLoading: false);
  }

  Future<void> _loadResources(UnifiedMediaEntry entry,
      {bool showLoading = true}) async {
    final cached = _resourceCache[entry.id];
    if (cached != null) {
      setState(() {
        _resources = cached;
        _resourceIndex = 0;
        _normalizeTracks();
        _loadingMedia = false;
      });
      return;
    }
    final generation = ++_generation;
    if (showLoading) {
      setState(() => _loadingMedia = true);
    }
    try {
      final resources = await _adapter.mediaResources(entry);
      if (!mounted || generation != _generation) return;
      _resourceCache[entry.id] = resources;
      setState(() {
        _resources = resources;
        _resourceIndex = resources.isEmpty
            ? 0
            : _resourceIndex.clamp(0, resources.length - 1).toInt();
        _normalizeTracks();
        if (_subtitleIndex < 0 && _resource?.subtitles.isNotEmpty == true) {
          _subtitleIndex = _preferredSubtitleIndex(_resource!.subtitles);
        }
        _loadingMedia = false;
      });
      if (_scopeRecords.isNotEmpty) _updateResume(entry);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _resources = const [];
        _loadingMedia = false;
      });
    }
  }

  int _preferredSubtitleIndex(List<Map<String, dynamic>> tracks) {
    String text(Map<String, dynamic> track) => [
          track['title'], track['display_title'], track['language'],
          track['codec_name'],
        ].where((value) => value != null).join(' ').toLowerCase();
    const simplified = ['简体', '简中', 'chs', 'zh-hans', 'zh_cn', 'gb'];
    const chinese = ['中文', '中字', 'chi', 'zho', 'zh-cn', ' zh '];
    for (var i = 0; i < tracks.length; i++) {
      if (simplified.any(text(tracks[i]).contains)) return i;
    }
    for (var i = 0; i < tracks.length; i++) {
      if (chinese.any(text(tracks[i]).contains)) return i;
    }
    return -1;
  }

  void _normalizeTracks() {
    final resource = _resource;
    final audioMax = (resource?.audios.length ?? 0) - 1;
    final subtitleMax = (resource?.subtitles.length ?? 0) - 1;
    _audioIndex =
        audioMax < 0 ? 0 : _audioIndex.clamp(0, audioMax).toInt();
    _subtitleIndex = subtitleMax < 0
        ? -1
        : _subtitleIndex.clamp(-1, subtitleMax).toInt();
  }

  void _updateResume(UnifiedMediaEntry entry) {
    _resumePositionTicks = null;
    _resumeRuntimeTicks = null;
    for (final record in _scopeRecords) {
      final matchId = record.sourceEntryId ?? record.lastEmbyItemId;
      if (matchId == entry.id) {
        _resumePositionTicks = record.lastPositionTicks;
        _resumeRuntimeTicks = record.runTimeTicks;
        return;
      }
    }
  }

  int _lastWatchedEpisodeIndex(List<UnifiedMediaEntry> episodes) {
    // 记录按最近播放排序，取第一个命中本季的记录对应索引。
    final wantedSeason = int.tryParse(_selectedSeasonId ?? '') ?? -1;
    for (final record in _scopeRecords) {
      final seasonMatch = wantedSeason < 0 ||
          (record.seasonNumber ?? -1) == wantedSeason;
      if (!seasonMatch || record.episodeNumber == null) continue;
      for (var i = 0; i < episodes.length; i++) {
        final ep = episodes[i];
        final epNum = ep.mediaItem?.indexNumber ?? ep.indexNumber;
        if (epNum == record.episodeNumber) return i;
      }
    }
    return 0;
  }

  /// 解析季号：仅识别明确的季格式（第 X 季 / Season X / S1 / season:X）。
  /// 注意：Emby 的 season.id 是纯数字内部 ID、飞牛的 season.id 是
  /// "season:<guid>"（guid 可能以数字开头），都不能作为季号兜底，
  /// 否则会把 ID/guid 误判为季号导致季识别错误。
  int? _seasonNumber(String? seasonId) {
    if (seasonId == null) return null;
    // 只认明确的季格式：中文"第 N 季"（含中文数字）、"season:N"（1-4 位，
    // 防止飞牛 'season:'+guid 长串数字被误判为巨大季号）、"Season N"、"S1"。
    final match = RegExp(
            r'第\s*(\d+)\s*季|第\s*([一二三四五六七八九十]+)\s*季|'
            r'^season[:\s]*(\d{1,4})$|[Ss]eason\s*(\d+)|[Ss](\d+)\b',
            caseSensitive: false)
        .firstMatch(seasonId);
    if (match == null) return null;
    final arabic = match.group(1) ?? match.group(3) ?? match.group(4) ??
        match.group(5);
    if (arabic != null) return int.tryParse(arabic);
    return _chineseSeasonToInt(match.group(2));
  }

  /// 中文数字季号 → 阿拉伯数字（十/十一/二十/二十一…）。
  int? _chineseSeasonToInt(String? s) {
    if (s == null || s.isEmpty) return null;
    const digits = {
      '一': 1, '二': 2, '三': 3, '四': 4, '五': 5,
      '六': 6, '七': 7, '八': 8, '九': 9,
    };
    if (s == '十') return 10;
    if (s.length == 2 && s[0] == '十') {
      return 10 + (digits[s[1]] ?? 0);
    }
    if (s.length == 2 && s[1] == '十') {
      return (digits[s[0]] ?? 0) * 10;
    }
    if (s.length == 1) return digits[s];
    return null;
  }

  /// 最近播放的季/集：按 lastPlayedAt 取最新记录（_scopeRecords 顺序不保证按时间）。
  ({int? season, int? episode}) _latestPlayedEpisode() {
    WatchHistoryRecord? latest;
    for (final record in _scopeRecords) {
      if (record.seasonNumber == null || record.episodeNumber == null) {
        continue;
      }
      if (latest == null || record.lastPlayedAt.isAfter(latest.lastPlayedAt)) {
        latest = record;
      }
    }
    if (latest == null) return (season: null, episode: null);
    return (season: latest.seasonNumber, episode: latest.episodeNumber);
  }

  String _resumeLabel() {    final ticks = _resumePositionTicks;
    final runtime = _resumeRuntimeTicks;
    if (ticks == null || ticks <= 0) return '播放';
    if (runtime != null && runtime > 0 && ticks >= runtime) return '重新播放';
    final seconds = ticks ~/ 10000000;
    if (seconds <= 0) return '播放';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0
        ? '继续播放 ${two(h)}:${two(m)}:${two(s)}'
        : '继续播放 ${two(m)}:${two(s)}';
  }

  bool _playInFlight = false;

  Future<void> _play() async {
    if (_playInFlight) return;
    final entry = _selectedEntry;
    if (entry == null) return;
    // 防重复点击：连点播放键只 push 一个播放器，避免并发进入多个播放实例
    // 导致路由栈错乱、方向锁竞争与"看似无响应"。
    _playInFlight = true;
    try {
      // 点击播放即刻锁定横屏，网络解析在横屏播放器内等待，避免竖屏停留。
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      if (!mounted) return;
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      // 方向锁定期间用户可能已返回，页面销毁后不再导航。
      if (!mounted) return;
      // Emby 走 /player/:id（内部自行解析媒体源，与外部详情页同路径，稳定可播）；
      // 其它源（飞牛/网盘）走 /source-player（source-player 依赖 MediaSourceBackend.resolvePlay）。
      if (widget.server.sourceKind == SourceKind.emby) {
      ref.read(selectedMediaSourceProvider.notifier).state = _resource?.id;
      ref.read(audioTrackProvider.notifier).state =
          _resource?.audios.isNotEmpty == true
              ? (_resource!.audios[_audioIndex]['index'] as num?)?.toInt()
              : null;
      ref.read(subtitleTrackProvider.notifier).state = _subtitleIndex < 0
          ? -1
          : (_resource!.subtitles[_subtitleIndex]['index'] as num?)?.toInt();
      final mediaSourceQuery = _resource == null
          ? ''
          : '&mediaSourceId=${Uri.encodeQueryComponent(_resource!.id)}';
      ref.read(unifiedResourceProvider.notifier).state = _resource;
      await context.push(
        '/player/${entry.id}?core=${Uri.encodeQueryComponent(_core)}$mediaSourceQuery',
      );
    } else {
      final source = entry.sourceEntry;
      if (source == null) return;
      ref.read(unifiedResourceProvider.notifier).state = _resource;
      await context.push(
        '/source-player',
        extra: SourcePlayback(
          server: ref.read(serverListProvider).firstWhere(
              (server) => server.id == widget.server.id,
              orElse: () => widget.server),
          entry: source,
          httpHeaders: source.thumbHeaders,
          playerCoreOverride: _core,
          preferredAudioListIndex:
              _resource?.audios.isNotEmpty == true ? _audioIndex : null,
          preferredSubtitleListIndex: _subtitleIndex,
          logoUrl: _externalDetail?.logoUrl,
          playlist: _episodes
              .map((item) => item.sourceEntry)
              .whereType<SourceEntry>()
              .toList(),
        ),
      );
    }
    if (mounted) await _loadResources(entry);
    } finally {
      // push 完成后释放防抖标志，允许后续再次进入播放。
      _playInFlight = false;
    }
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
    final entry = detail.entry;
    final background = _backgroundColor ?? Theme.of(context).scaffoldBackgroundColor;
    return Scaffold(
      backgroundColor: background,
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        color: background,
        child: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              expandedHeight: MediaQuery.sizeOf(context).height * 0.44,
              pinned: true,
              stretch: true,
              backgroundColor: Colors.transparent,
              leading: _roundButton(
                  Icons.arrow_back_rounded, () => Navigator.of(context).maybePop()),
              actions: [
                if (_externalDetail != null)
                  _roundButton(Icons.more_vert_rounded,
                      () => _showLinks(_externalDetail!)),
              ],
              flexibleSpace: FlexibleSpaceBar(
                collapseMode: CollapseMode.parallax,
                background: AdaptivePosterBlend(
                  imageUrl: entry.posterUrl?.isNotEmpty == true
                      ? entry.posterUrl
                      : entry.backdropUrl,
                  httpHeaders: entry.imageHeaders,
                  onBackgroundChanged: (color) {
                    if (mounted && color != _backgroundColor) {
                      setState(() => _backgroundColor = color);
                    }
                  },
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 28),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        if (_externalDetail?.logoUrl?.isNotEmpty == true)
                          SizedBox(
                            width: 250,
                            height: 90,
                            child: MediaImage(
                              imageUrl: _externalDetail!.logoUrl,
                              fit: BoxFit.contain,
                            ),
                          )
                        else
                          Text(entry.name,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 29,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF252525),
                                  shadows: [
                                    Shadow(color: Colors.white70, blurRadius: 10)
                                  ])),
                        const SizedBox(height: 12),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 10,
                          runSpacing: 6,
                          children: [
                            if ((_externalDetail?.rating ?? entry.rating) != null)
                              Text(
                                  '⭐ ${(_externalDetail?.rating ?? entry.rating)!.toStringAsFixed(1)}',
                                  style: _heroMeta),
                            if ((_externalDetail?.year ??
                                    entry.year?.toString()) !=
                                null)
                              Text(
                                  '${_externalDetail?.year ?? entry.year}',
                                  style: _heroMeta),
                            if (_externalDetail?.numberOfSeasons != null)
                              Text('共${_externalDetail!.numberOfSeasons}季',
                                  style: _heroMeta)
                            else if (detail.seasons.isNotEmpty)
                              Text('共${detail.seasons.length}季',
                                  style: _heroMeta),
                          ],
                        ),
                        if (_externalDetail?.genres.isNotEmpty == true) ...[
                          const SizedBox(height: 6),
                          Text(_externalDetail!.genres.join(' · '),
                              style: _heroMeta, textAlign: TextAlign.center),
                        ],
                      ]),
                    ),
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
              sliver: SliverList.list(children: [
                _primaryPlayButton(),
                const SizedBox(height: 14),
                _buildPlaybackOptionCapsules(),
                const SizedBox(height: 14),
                if (entry.overview?.isNotEmpty == true)
                  CollapsibleOverview(text: entry.overview!),
                if (detail.seasons.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _buildSeasonSelector(detail.seasons),
                  const SizedBox(height: 18),
                  _buildEpisodes(),
                ],
                const SizedBox(height: 20),
                _sectionTitle(
                  '播放资源',
                  trailing: TextButton(
                    onPressed: () => _showAllCrossServerResources(entry.name),
                    child: const Text('查看更多  ›'),
                  ),
                ),
                const SizedBox(height: 14),
                _buildCrossServerResourceList(entry.name),
                if (_peopleList.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _sectionTitle('演员'),
                  const SizedBox(height: 16),
                  _people(_peopleList),
                ],
                if (_externalDetail?.images.isNotEmpty == true) ...[
                  const SizedBox(height: 20),
                  _sectionTitle('剧照'),
                  const SizedBox(height: 16),
                  _gallery(_externalDetail!.images),
                ],
                if (_externalDetail?.recommendations.isNotEmpty == true) ...[
                  const SizedBox(height: 20),
                  _sectionTitle('相似推荐'),
                  const SizedBox(height: 16),
                  _recommendations(_externalDetail!.recommendations),
                ],
                const SizedBox(height: 20),
                _sectionTitle('媒体信息'),
                const SizedBox(height: 14),
                _mediaInfo(detail),
                if (_resource != null) ...[
                  const SizedBox(height: 16),
                  _buildStreamInfoCards(),
                ],
                if (_resource?.path?.isNotEmpty == true) ...[
                  const SizedBox(height: 12),
                  _buildFileInfoCard(_resource!),
                ],
                if (_externalDetail != null) ...[
                  const SizedBox(height: 20),
                  _sectionTitle('链接'),
                  const SizedBox(height: 14),
                  _links(_externalDetail!),
                ],
                if (_externalDetail?.companies.isNotEmpty == true) ...[
                  const SizedBox(height: 20),
                  _sectionTitle('工作室'),
                  const SizedBox(height: 14),
                  _companies(_externalDetail!.companies),
                ],
              ]),
            ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _primaryPlayButton() => Center(
        child: SizedBox(
          width: 185,
          height: 50,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              shape: const StadiumBorder(),
              elevation: 0,
            ),
            // 优先播放单击选中的跨服务器资源；无选择时播放本地资源。
            onPressed: _selectedCrossServerMatch != null
                ? _playSelectedOrLocal
                : (_selectedEntry == null || _loadingMedia ? null : _play),
            icon: const Icon(Icons.play_arrow_rounded, size: 23),
            label: Text(
              _selectedEntry == null && _selectedCrossServerMatch == null
                  ? '搜索中'
                  : (_selectedEntry == null ? '播放' : _resumeLabel()),
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      );

  /// 播放所选：有跨服务器选择时播放该服务器资源，否则走本地资源播放。
  void _playSelectedOrLocal() {
    final match = _selectedCrossServerMatch;
    if (match != null) {
      _openCrossServerMatch(match);
      return;
    }
    _play();
  }

  /// 演员：优先 A 模板所需的外部演员（可点开作品）；无外部数据时由
  /// UnifiedPerson 转换（role→character、imageUrl→profileUrl，id 为空不可点）。
  List<ExternalPerson> get _peopleList {
    final external = _externalDetail;
    if (external != null && external.people.isNotEmpty) return external.people;
    final detail = _detail;
    if (detail == null || detail.people.isEmpty) return const [];
    return [
      for (final person in detail.people)
        ExternalPerson(
          id: '',
          name: person.name,
          source: ReviewSource.tmdb,
          originalName: person.role,
          character: person.role,
          profileUrl: person.imageUrl,
        ),
    ];
  }

  Widget _buildSeasonSelector(List<UnifiedSeason> seasons) => Row(children: [
        Text(
          seasons
              .where((season) => season.id == _selectedSeasonId)
              .firstOrNull
              ?.name ??
              '选择季',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.unfold_more_rounded),
          onSelected: _selectSeason,
          itemBuilder: (_) => [
            for (final season in seasons)
              PopupMenuItem(value: season.id, child: Text(season.name)),
          ],
        ),
      ]);

  Widget _buildEpisodes() => SizedBox(
        height: 220,
        child: _episodes.isEmpty
            ? const Center(child: Text('本季暂无剧集'))
            : ListView.separated(
                controller: _episodeController,
                scrollDirection: Axis.horizontal,
                itemCount: _episodes.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, index) {
                  final episode = _episodes[index];
                  final selected = _selectedEntry?.id == episode.id;
                  return SizedBox(
                    width: 220,
                    child: InkWell(
                      onTap: () => _selectEpisode(episode),
                      borderRadius: BorderRadius.circular(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AspectRatio(
                            aspectRatio: 16 / 9,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: Stack(fit: StackFit.expand, children: [
                                MediaImage(
                                  imageUrl:
                                      episode.backdropUrl?.isNotEmpty == true
                                          ? episode.backdropUrl
                                          : episode.posterUrl,
                                  httpHeaders: episode.imageHeaders,
                                  fit: BoxFit.cover,
                                ),
                                if (selected)
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          width: 4),
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                  ),
                              ]),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(episode.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 5),
                          Text(episode.overview ?? '',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  height: 1.35, color: Colors.black54)),
                        ],
                      ),
                    ),
                  );
                },
              ),
      );

  Widget _buildCrossServerResourceList(String query) => Consumer(
        builder: (context, ref, _) {
          final async = ref.watch(rankingCrossServerMatchProvider(query));
          return async.when(
            loading: () => const SizedBox(
                height: 155, child: Center(child: CircularProgressIndicator())),
            error: (_, __) => const Text('资源搜索失败'),
            data: (matches) {
              if (matches.isEmpty) return _buildResourceList();
              return SizedBox(
                height: 155,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: matches.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, index) {
                    final match = matches[index];
                    final info = matchPlaybackInfo(match);
                    return SizedBox(
                      width: 250,
                      child: PlaybackResourceCard(
                        serverName: match.serverName,
                        isBest: index == 0,
                        // 单击选中高亮当前点选的跨服务器资源；默认高亮命中排第一的
                        isSelected: index == _selectedCrossServerIndex,
                        resolution: info.resolution,
                        dynamicRange: info.dynamicRange,
                        codec: info.codec,
                        frameRate: info.frameRate,
                        size: info.size,
                        bitrate: info.bitrate,
                        // 单击 = 选择该服务器资源（高亮 + 记录，播放由顶部播放键触发）
                        onTap: () => setState(() {
                          _selectedCrossServerIndex = index;
                          _selectedCrossServerMatch = match;
                        }),
                        // 双击 = 进入该服务器对应的媒体详情页
                        onDoubleTap: () => _openServerDetail(match),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      );

  void _openCrossServerMatch(ServerMatchInfo match) {
    final servers = ref.read(serverListProvider);
    // 与影视（外部）详情页一致：优先 match.sourceServerId，缺失时回退
    // match.item.sourceServerId（部分源只在 MediaItem 上打来源标记）。
    final server = servers
            .where((item) => item.id == match.sourceServerId)
            .firstOrNull ??
        (match.item.sourceServerId != null
            ? servers
                .where((s) => s.id == match.item.sourceServerId)
                .firstOrNull
            : null);
    if (server == null) return;
    ref.read(currentServerProvider.notifier).state = server;
    if (!mounted) return;
    if (match.sourceEntry != null) {
      context.push('/source-player',
          extra: SourcePlayback(server: server, entry: match.sourceEntry!));
      return;
    }
    // 与影视（外部）详情页同路径：按 item 的源服务器同步可用服务器再进 /player/:id，
    // 避免 currentServer 与资源归属不一致导致聚合资源无法播放。
    if (match.item.type == 'Movie' || match.item.type == 'Episode') {
      final origin = match.item.sourceServerId;
      if (origin != null) {
        ref.read(currentServerProvider.notifier).syncWithAvailableServers(
            ref.read(serverListProvider),
            preferredServerId: origin);
      } else {
        ref.read(currentServerProvider.notifier).state = server;
      }
      if (!mounted) return;
      context.push('/player/${match.item.id}');
      return;
    }
    // Series 等顶层剧集：进入该服务器对应的媒体详情页（详情页内选集播放），
    // 与 A 页聚合资源行为一致；不能直接 push /player（Series 无可播源）。
    if (!mounted) return;
    openMediaItem(ref, context, match.item);
  }

  /// 双击跨服务器资源卡：进入该服务器对应的媒体详情页（复用 UnifiedMediaDetailScreen）。
  void _openServerDetail(ServerMatchInfo match) {
    // 与 A 页一致：优先 match.sourceServerId（飞牛打标），缺失回退
    // match.item.sourceServerId（Emby 由公共链路在 item 上打标）。
    final server = ref
            .read(serverListProvider)
            .where((item) => item.id == match.sourceServerId)
            .firstOrNull ??
        (match.item.sourceServerId != null
            ? ref
                .read(serverListProvider)
                .where((s) => s.id == match.item.sourceServerId)
                .firstOrNull
            : null);
    if (server == null) return;
    ref.read(currentServerProvider.notifier).state = server;
    // Emby/飞牛的媒体详情统一入口：先切服务器再 push /detail/:id。
    final itemId = match.item.id;
    if (itemId.isNotEmpty) {
      context.push('/detail/${Uri.encodeComponent(itemId)}');
    } else if (match.sourceEntry != null) {
      context.push('/detail/${Uri.encodeComponent(match.sourceEntry!.id)}');
    }
  }

  void _showAllCrossServerResources(String query) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .75,
          child: Consumer(builder: (context, ref, _) {
            return ref.watch(rankingCrossServerMatchProvider(query)).when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => const Center(child: Text('搜索失败')),
              data: (matches) => ListView(
                padding: const EdgeInsets.all(18),
                children: [
                  const Text('全部播放资源',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 12),
                  for (final match in matches)
                    ListTile(
                      leading: const Icon(Icons.play_circle_outline_rounded),
                      title: Text(match.serverName),
                      subtitle: Text(match.item.name),
                      onTap: () {
                        Navigator.pop(context);
                        _openCrossServerMatch(match);
                      },
                    ),
                ],
              ),
            );
          }),
        ),
      );

  Widget _buildResourceList() {
    if (_resources.isEmpty) {
      return const SizedBox(
          height: 100, child: Center(child: Text('暂无播放资源')));
    }
    return SizedBox(
      height: 155,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _resources.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final resource = _resources[index];
          final selected = index == _resourceIndex;
          final video = resource.video ?? const <String, dynamic>{};
          final range = (video['video_range_type'] ?? video['video_range'])
              ?.toString();
          return SizedBox(
            width: 250,
            child: PlaybackResourceCard(
              serverName: widget.server.name,
              serverIcon: widget.server.iconUrl?.isNotEmpty == true
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: MediaImage(
                        imageUrl: widget.server.iconUrl,
                        fit: BoxFit.contain,
                        useDefaultUserAgent: true,
                      ),
                    )
                  : null,
              isSelected: selected,
              resolution: _resolution(video),
              dynamicRange: range,
              codec: video['codec_name']?.toString(),
              size: resource.size,
              bitrate: (video['bitrate'] as num?)?.toInt(),
              onTap: () {
                setState(() {
                  _resourceIndex = index;
                  _normalizeTracks();
                });
                _play();
              },
            ),
          );
        },
      ),
    );
  }

  Widget _gallery(List<String> images) => SizedBox(
        height: 150,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: images.length,
          separatorBuilder: (_, __) => const SizedBox(width: 9),
          itemBuilder: (_, index) => InkWell(
            onTap: () => _showImage(images, index),
            borderRadius: BorderRadius.circular(18),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: MediaImage(
                    imageUrl: images[index],
                    fit: BoxFit.cover,
                    cacheWidth: 320),
              ),
            ),
          ),
        ),
      );

  Widget _recommendations(List<DiscoverEntry> items) => SizedBox(
        height: 180,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, index) {
            final item = items[index];
            return InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => ExternalMediaDetailScreen(entry: item))),
              child: SizedBox(
                width: 100,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: MediaImage(
                            imageUrl: item.posterUrl,
                            fit: BoxFit.cover,
                            cacheWidth: 200),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(item.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(item.year ?? '',
                        style: const TextStyle(color: Colors.black54)),
                  ],
                ),
              ),
            );
          },
        ),
      );

  Widget _links(ExternalMediaDetail detail) {
    final query =
        Uri.encodeQueryComponent('${detail.title} ${detail.year ?? ''}'.trim());
    final values = <(String, String)>[
      (
        'TMDB',
        detail.tmdbId > 0
            ? 'https://www.themoviedb.org/${detail.mediaType}/${detail.tmdbId}'
            : 'https://www.themoviedb.org/search?query=$query',
      ),
      (
        'IMDb',
        detail.imdbId?.isNotEmpty == true
            ? 'https://www.imdb.com/title/${detail.imdbId}/'
            : 'https://www.imdb.com/find/?q=$query',
      ),
      (
        '豆瓣',
        detail.doubanId?.isNotEmpty == true
            ? 'https://movie.douban.com/subject/${detail.doubanId}/'
            : 'https://search.douban.com/movie/subject_search?search_text=$query',
      ),
    ];
    return Wrap(spacing: 12, runSpacing: 10, children: [
      for (final value in values)
        ActionChip(
          avatar: const Icon(Icons.open_in_new_rounded, size: 17),
          label: Text(value.$1),
          onPressed: () => launchUrl(
            Uri.parse(value.$2),
            mode: LaunchMode.externalApplication,
          ),
        ),
    ]);
  }

  static const TextStyle _heroMeta = TextStyle(
      fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF3B3B3B));

  Widget _roundButton(IconData icon, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.all(6),
        child: Material(
          color: Colors.black.withValues(alpha: 0.42),
          shape: const CircleBorder(),
          child: IconButton(
              onPressed: onTap,
              icon: Icon(icon, color: Colors.white, size: 30)),
        ),
      );

  void _showLinks(ExternalMediaDetail detail) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: _links(detail),
          ),
        ),
      );

  Widget _companies(List<ExternalCompany> companies) => SizedBox(
        height: 54,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: companies.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, index) => ActionChip(
            avatar: companies[index].logoUrl == null
                ? null
                : SizedBox(
                    width: 28,
                    height: 20,
                    child: MediaImage(
                        imageUrl: companies[index].logoUrl,
                        fit: BoxFit.contain)),
            label: Text(companies[index].name),
            onPressed: () {},
          ),
        ),
      );

  Widget _people(List<ExternalPerson> people) => SizedBox(
        height: 105,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: people.length,
          separatorBuilder: (_, __) => const SizedBox(width: 9),
          itemBuilder: (_, index) {
            final person = people[index];
            return InkWell(
              onTap:
                  person.id.isEmpty ? null : () => _showPerson(person),
              child: SizedBox(
                width: 78,
                child: Column(children: [
                  ClipOval(
                    child: SizedBox(
                      width: 58,
                      height: 58,
                      child: MediaImage(
                        imageUrl: person.profileUrl,
                        fit: BoxFit.cover,
                        cacheWidth: 120,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(person.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(person.character ?? person.originalName ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.black54)),
                ]),
              ),
            );
          },
        ),
      );

  void _showPerson(ExternalPerson person) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .78,
        child: Consumer(
          builder: (context, ref, _) {
            final async = ref.watch(externalPersonCreditsProvider(person));
            return Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  Row(
                    children: [
                      ClipOval(
                        child: SizedBox(
                          width: 80,
                          height: 80,
                          child: MediaImage(
                            imageUrl: person.profileUrl,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              person.name,
                              style: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w800),
                            ),
                            Text(person.character ?? person.originalName ?? ''),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: async.when(
                      loading: () => const Center(
                        child: CircularProgressIndicator(),
                      ),
                      error: (_, __) =>
                          const Center(child: Text('作品加载失败')),
                      data: (items) => GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: .55,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: items.length,
                        itemBuilder: (_, index) {
                          final item = items[index];
                          return InkWell(
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    ExternalMediaDetailScreen(entry: item),
                              ),
                            ),
                            child: Column(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: MediaImage(
                                      imageUrl: item.posterUrl,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _mediaInfo(UnifiedMediaDetail detail) {
    final entry = detail.entry;
    final resource = _resource;
    final video = resource?.video;
    final videoDisplay =
        video == null ? '' : _videoDisplay(video);
    final values = <(String, String)>[
      ('来源', widget.server.name),
      ('类型', entry.isSeries ? '剧集' : '电影'),
      if (_externalDetail?.originalTitle?.isNotEmpty == true)
        ('原名', _externalDetail!.originalTitle!),
      if (entry.year != null) ('年份', '${entry.year}'),
      if (_externalDetail?.runtime != null &&
          _externalDetail!.runtime! > 0)
        ('时长', '${_externalDetail!.runtime} 分钟'),
      if (entry.isSeries && detail.seasons.isNotEmpty)
        ('季数', '${detail.seasons.length}'),
      if (_externalDetail?.status?.isNotEmpty == true)
        ('状态', _externalDetail!.status!),
      if (video != null && _resolution(video).isNotEmpty)
        ('分辨率', _resolution(video)),
      if (videoDisplay.isNotEmpty && videoDisplay != '-')
        ('编码', videoDisplay),
      if (resource?.size != null && resource!.size! > 0)
        ('大小', formatSourceFileSize(resource.size!)),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          Chip(label: Text('${value.$1}  ${value.$2}')),
      ],
    );
  }

  /// ---- 迁移自旧 B/C/D：播放选项胶囊（内核/线路/音频/字幕/版本）----
  /// A 风格呈现：横向滚动浅色描边胶囊（不复用旧的四等分布局），
  /// 点击弹出对应选择器；无资源/线路时对应项禁用。放置于播放键下方。
  Widget _buildPlaybackOptionCapsules() {
    final resource = _resource;
    final audios = resource?.audios ?? const [];
    final subtitles = resource?.subtitles ?? const [];
    final scheme = Theme.of(context).colorScheme;
    final options = <({
      IconData icon,
      String label,
      String value,
      VoidCallback? onTap,
    })>[
      if (_resources.length > 1)
        (
          icon: Icons.video_file_rounded,
          label: '版本',
          value: resource?.name ?? '默认资源',
          onTap: _showResourcePicker,
        ),
      (
        icon: Icons.memory_rounded,
        label: '内核',
        value: _core == 'exoPlayer' ? 'ExoPlayer' : 'MPV',
        onTap: _showCorePicker,
      ),
      (
        icon: Icons.route_rounded,
        label: '线路',
        value: _lineLabel(widget.server),
        onTap: widget.server.lines.isEmpty ? null : _showLinePicker,
      ),
      (
        icon: Icons.audiotrack_rounded,
        label: '音频',
        value: audios.isEmpty
            ? '自动'
            : _trackLabel(audios[_audioIndex], _audioIndex, '音轨'),
        onTap: audios.isEmpty ? null : _showAudioPicker,
      ),
      (
        icon: Icons.subtitles_rounded,
        label: '字幕',
        value: _subtitleIndex < 0
            ? (subtitles.isEmpty ? '自动' : '关闭')
            : _trackLabel(subtitles[_subtitleIndex], _subtitleIndex, '字幕'),
        onTap: subtitles.isEmpty ? null : _showSubtitlePicker,
      ),
    ];
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final option = options[index];
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: option.onTap,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(option.icon, size: 14,
                        color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      option.label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        option.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// ---- 迁移自旧 B/C/D：媒体信息分类栏（视频/音频/字幕流信息）----
  /// A 风格呈现：圆角 12 卡片 + 字段标签化（标签胶囊），横滑分组。
  Widget _buildStreamInfoCards() {
    final resource = _resource;
    if (resource == null) {
      return const SizedBox(
          height: 80, child: Center(child: Text('暂无媒体流信息')));
    }
    String value(dynamic item) => item == null ? '' : '$item';
    final cards = <Widget>[
      if (resource.video != null)
        _streamInfoCard('视频', Icons.videocam_rounded, [
          ('编码', _videoDisplay(resource.video!)),
          ('封装', value(resource.video!['container'])),
          ('分辨率', _resolution(resource.video!)),
          ('SAR', value(resource.video!['sample_aspect_ratio'])),
          ('DAR', value(
              resource.video!['aspect_ratio'] ?? _aspectRatio(resource.video!))),
          ('帧率', _frameRate(resource.video!)),
          ('码率', _bitrate(resource.video!['bitrate'])),
          ('像素', value(resource.video!['pixel_format'])),
          ('位深', resource.video!['bit_depth'] == null
              ? ''
              : '${resource.video!['bit_depth']} bit'),
          ('色彩范围', value(resource.video!['color_range'])),
          ('色彩空间', value(resource.video!['color_space'])),
          ('色彩矩阵', value(resource.video!['color_matrix'])),
          ('色域/传输', value(resource.video!['color_transfer'])),
          ('HDR', value(resource.video!['video_range_type'])),
          ('GOP', value(resource.video!['gop_size'])),
          ('时间基', value(resource.video!['time_base'])),
        ]),
      for (var i = 0; i < resource.audios.length; i++)
        _streamInfoCard('音频 ${i + 1}', Icons.audiotrack_rounded, [
          ('编码', value(resource.audios[i]['codec_name'])),
          ('语言', value(resource.audios[i]['language'])),
          ('采样率', resource.audios[i]['sample_rate'] == null
              ? ''
              : '${resource.audios[i]['sample_rate']} Hz'),
          ('位深', resource.audios[i]['bit_depth'] == null
              ? ''
              : '${resource.audios[i]['bit_depth']} bit'),
          ('声道', value(resource.audios[i]['channel_layout'] ??
              resource.audios[i]['channels'])),
          ('码率', _bitrate(resource.audios[i]['bitrate'])),
        ]),
      for (var i = 0; i < resource.subtitles.length; i++)
        _streamInfoCard('字幕 ${i + 1}', Icons.subtitles_rounded, [
          ('编码', value(resource.subtitles[i]['codec_name'])),
          ('语言', value(resource.subtitles[i]['language'])),
          ('标题', value(resource.subtitles[i]['title'])),
          ('外挂', resource.subtitles[i]['is_external'] == true ? '是' : '否'),
        ]),
    ];
    if (cards.isEmpty) {
      return const SizedBox(
          height: 80, child: Center(child: Text('暂无媒体流信息')));
    }
    return SizedBox(
      height: 300,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, index) => cards[index],
      ),
    );
  }

  /// A 风格流信息卡片：圆角 12 卡片 + 标题行 + 字段标签 Wrap。
  Widget _streamInfoCard(
      String title, IconData icon, List<(String, String)> rows) {
    final visible =
        rows.where((row) => row.$2.isNotEmpty).toList();
    final scheme = Theme.of(context).colorScheme;
    Widget tag(String text) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Text(text,
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant)),
        );
    return SizedBox(
      width: 240,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 10),
              Expanded(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final row in visible) tag('${row.$1} ${row.$2}'),
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

  /// ---- 迁移自旧 B/C/D：文件信息卡（文件名/路径/大小）----
  /// A 风格呈现：圆角 12 卡片。
  Widget _buildFileInfoCard(UnifiedMediaResource resource) => Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                Icon(Icons.folder_open_rounded, size: 20),
                SizedBox(width: 8),
                Text('视频文件',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 10),
              SelectableText(resource.name),
              if (resource.path?.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                SelectableText(resource.path!,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
              if ((resource.size ?? 0) > 0) ...[
                const SizedBox(height: 8),
                Text(formatSourceFileSize(resource.size!)),
              ],
            ],
          ),
        ),
      );

  Widget _sectionTitle(String title, {Widget? trailing}) => Row(children: [
        Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
        if (trailing != null) trailing,
      ]);

  String _resolution(Map<String, dynamic> stream) {
    final width = (stream['width'] as num?)?.toInt() ?? 0;
    final height = (stream['height'] as num?)?.toInt() ?? 0;
    return width > 0 && height > 0 ? '${width}×$height' : '';
  }

  String _bitrate(dynamic value) {
    final bitrate = value is num ? value.toInt() : int.tryParse('$value') ?? 0;
    return bitrate <= 0 ? '' : '${(bitrate / 1000000).toStringAsFixed(1)} Mbps';
  }

  String _videoDisplay(Map<String, dynamic> stream) {
    final codec = stream['codec_name']?.toString().trim().toUpperCase() ?? '';
    final profile = stream['profile']?.toString().trim() ?? '';
    final parts = <String>[codec, profile.toUpperCase()].where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? '-' : parts.join(' / ');
  }

  String _trackLabel(Map<String, dynamic> track, int index, String fallback) {
    final title = track['title']?.toString().trim() ?? '';
    final language = track['language']?.toString().trim() ?? '';
    final codec = track['codec_name']?.toString().trim().toUpperCase() ?? '';
    if (title.isNotEmpty) return title;
    final parts = [language, codec].where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? '$fallback ${index + 1}' : parts.join(' · ');
  }

  String _aspectRatio(Map<String, dynamic> stream) {
    final width = (stream['width'] as num?)?.toInt() ?? 0;
    final height = (stream['height'] as num?)?.toInt() ?? 0;
    if (width <= 0 || height <= 0) return '';
    final ratio = width / height;
    if ((ratio - 16 / 9).abs() < 0.02) return '16:9';
    if ((ratio - 4 / 3).abs() < 0.02) return '4:3';
    if ((ratio - 21 / 9).abs() < 0.02) return '21:9';
    if ((ratio - 2.35).abs() < 0.05) return '2.35:1';
    if ((ratio - 1.85).abs() < 0.05) return '1.85:1';
    return ratio.toStringAsFixed(2);
  }

  String _frameRate(Map<String, dynamic> stream) {
    final rate = (stream['real_frame_rate'] ?? stream['average_frame_rate']);
    if (rate is! num || rate <= 0) return '';
    final value = rate.toDouble();
    if ((value - 23976 / 1000).abs() < 0.001) return '23.976 fps';
    if ((value - 24000 / 1000).abs() < 0.001) return '24 fps';
    if ((value - 25000 / 1000).abs() < 0.001) return '25 fps';
    if ((value - 30000 / 1000).abs() < 0.001) return '30 fps';
    if ((value - 48000 / 1000).abs() < 0.001) return '48 fps';
    if ((value - 60000 / 1000).abs() < 0.001) return '60 fps';
    return '${value.toStringAsFixed(2)} fps';
  }

  String _lineLabel(ServerConfig server) {
    if (server.lines.isEmpty) return '默认线路';
    final index = server.activeLineIndex.clamp(0, server.lines.length - 1);
    return server.lines[index].name;
  }

  void _showPicker({required List<Widget> children}) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(shrinkWrap: true, children: children),
      ),
    );
  }

  void _showLinePicker() {
    final lines = widget.server.lines;
    _showPicker(children: [
      for (var index = 0; index < lines.length; index++)
        RadioListTile<int>(
          value: index,
          groupValue: widget.server.activeLineIndex,
          title: Text(lines[index].name),
          subtitle: Text(lines[index].url,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          onChanged: (value) {
            if (value == null) return;
            ref
                .read(serverListProvider.notifier)
                .setActiveLine(widget.server.id, value);
            Navigator.pop(context);
          },
        ),
    ]);
  }

  void _showResourcePicker() => _showPicker(
        children: [
          for (var index = 0; index < _resources.length; index++)
            RadioListTile<int>(
              value: index,
              groupValue: _resourceIndex,
              title: Text(_resources[index].name),
              subtitle: Text(_resources[index].path ?? ''),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _resourceIndex = value;
                  _audioIndex = 0;
                  _subtitleIndex = -1;
                  _normalizeTracks();
                });
                Navigator.pop(context);
              },
            ),
        ],
      );

  void _showCorePicker() => _showPicker(children: [
        RadioListTile<String>(
          value: 'exoPlayer',
          groupValue: _core,
          title: const Text('ExoPlayer'),
          subtitle: const Text('Android Media3，轻量硬解'),
          onChanged: (value) {
            if (value == null) return;
            setState(() => _core = value);
            Navigator.pop(context);
          },
        ),
        RadioListTile<String>(
          value: 'nativeMpv',
          groupValue: _core,
          title: const Text('MPV 原生'),
          subtitle: const Text('全格式、多音轨与高级字幕'),
          onChanged: (value) {
            if (value == null) return;
            setState(() => _core = value);
            Navigator.pop(context);
          },
        ),
      ]);

  void _showAudioPicker() => _showPicker(
        children: [
          for (var index = 0; index < _resource!.audios.length; index++)
            RadioListTile<int>(
              value: index,
              groupValue: _audioIndex,
              title: Text(_trackLabel(_resource!.audios[index], index, '音轨')),
              onChanged: (value) {
                if (value == null) return;
                setState(() => _audioIndex = value);
                Navigator.pop(context);
              },
            ),
        ],
      );

  void _showSubtitlePicker() => _showPicker(children: [
        RadioListTile<int>(
          value: -1,
          groupValue: _subtitleIndex,
          title: const Text('关闭字幕'),
          onChanged: (_) {
            setState(() => _subtitleIndex = -1);
            Navigator.pop(context);
          },
        ),
        for (var index = 0; index < _resource!.subtitles.length; index++)
          RadioListTile<int>(
            value: index,
            groupValue: _subtitleIndex,
            title: Text(_trackLabel(_resource!.subtitles[index], index, '字幕')),
            onChanged: (value) {
              if (value == null) return;
              setState(() => _subtitleIndex = value);
              Navigator.pop(context);
            },
          ),
      ]);

  void _showImage(List<String> images, int initial) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(children: [
          PageView.builder(
            controller: PageController(initialPage: initial),
            itemCount: images.length,
            itemBuilder: (_, index) => InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(
                child: MediaImage(imageUrl: images[index], fit: BoxFit.contain),
              ),
            ),
          ),
          SafeArea(
            child: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded, color: Colors.white, size: 30),
            ),
          ),
        ]),
      ),
    );
  }
}

class _UnifiedServerStats extends ConsumerWidget {
  const _UnifiedServerStats({required this.current});
  final ServerConfig current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(serverCardStatsProvider(current.id));
    Widget line(IconData icon, String label, int? value) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13),
            const SizedBox(width: 3),
            Text('$label ${value ?? '—'}',
                style:
                    const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
          ],
        );
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          stats.when(
            data: (value) => line(Icons.movie_outlined, '电影', value.movieCount),
            loading: () => line(Icons.movie_outlined, '电影', null),
            error: (_, __) => line(Icons.movie_outlined, '电影', null),
          ),
          stats.when(
            data: (value) => line(Icons.tv_outlined, '电视剧', value.seriesCount),
            loading: () => line(Icons.tv_outlined, '电视剧', null),
            error: (_, __) => line(Icons.tv_outlined, '电视剧', null),
          ),
          stats.when(
            data: (value) =>
                line(Icons.video_library_outlined, '媒体', value.episodeCount),
            loading: () => line(Icons.video_library_outlined, '媒体', null),
            error: (_, __) => line(Icons.video_library_outlined, '媒体', null),
          ),
        ],
      ),
    );
  }
}

class _ServerLineAction extends ConsumerWidget {
  const _ServerLineAction({required this.server, required this.onChanged});
  final ServerConfig server;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (server.lines.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<int>(
      tooltip: '切换线路',
      icon: const Icon(Icons.route_rounded),
      onSelected: (index) async {
        ref.read(serverListProvider.notifier).setActiveLine(server.id, index);
        final updated = ref.read(serverListProvider).firstWhere((item) => item.id == server.id);
        ref.read(currentServerProvider.notifier).state = updated;
        await onChanged();
      },
      itemBuilder: (_) => [
        for (var i = 0; i < server.lines.length; i++)
          CheckedPopupMenuItem<int>(value: i, checked: i == server.activeLineIndex, child: Text(server.lines[i].name)),
      ],
    );
  }
}

class _UnifiedServerSwitcher extends ConsumerWidget {
  const _UnifiedServerSwitcher({required this.current});
  final ServerConfig current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref
        .watch(serverListProvider)
        .where((server) =>
            server.sourceKind == SourceKind.emby ||
            server.sourceKind == SourceKind.feiniu)
        .toList();
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
        ref.read(authStateProvider.notifier).state = AuthState.authenticated;
        context.go('/home');
      },
      itemBuilder: (_) => [
        for (final server in servers)
          PopupMenuItem<String>(
            value: server.id,
            child: Row(children: [
              const Icon(Icons.video_library_rounded, size: 20),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(server.name, overflow: TextOverflow.ellipsis)),
              if (server.id == current.id)
                const Icon(Icons.check_rounded, size: 18),
            ]),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: '__manage__',
          child: Row(children: [
            Icon(Icons.settings_rounded, size: 20),
            SizedBox(width: 10),
            Text('管理服务器'),
          ]),
        ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, maxWidth: 220),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.video_library_rounded, size: 22),
          const SizedBox(width: 8),
          Flexible(
            child: Text(current.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
        ]),
      ),
    );
  }
}

class _ContinueSection extends StatelessWidget {
  const _ContinueSection({required this.items, required this.onTap, required this.onPlay});
  final List<UnifiedContinueItem> items;
  final ValueChanged<UnifiedContinueItem> onTap;
  final ValueChanged<UnifiedContinueItem> onPlay;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
            child: Text('继续观看',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          SizedBox(
            height: 166,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, index) {
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
                            child: Stack(fit: StackFit.expand, children: [
                              GestureDetector(
                                onTap: () => onPlay(item),
                                child: MediaImage(
                                  imageUrl:
                                      item.entry.backdropUrl?.isNotEmpty == true
                                          ? item.entry.backdropUrl
                                          : item.entry.posterUrl,
                                  httpHeaders: item.entry.imageHeaders,
                                  fit: BoxFit.cover,
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
                            ]),
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(item.entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text('已观看 ${(item.progress * 100).round()}%',
                            style: Theme.of(context).textTheme.bodySmall),
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

class _LibrarySection extends StatelessWidget {
  const _LibrarySection({
    required this.library,
    required this.preview,
    required this.onOpenLibrary,
    required this.onOpenEntry,
  });
  final UnifiedMediaLibrary library;
  final List<UnifiedMediaEntry>? preview;
  final VoidCallback onOpenLibrary;
  final ValueChanged<UnifiedMediaEntry> onOpenEntry;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 8, 8),
            child: Row(children: [
              Expanded(
                child: Text(library.name,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              TextButton(onPressed: onOpenLibrary, child: const Text('查看全部')),
            ]),
          ),
          if (preview == null)
            const SizedBox(
                height: 190, child: Center(child: CircularProgressIndicator()))
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
                  child: _UnifiedMediaCard(
                    entry: preview![index],
                    onTap: () => onOpenEntry(preview![index]),
                  ),
                ),
              ),
            ),
        ],
      );
}

class _UnifiedMediaCard extends StatelessWidget {
  const _UnifiedMediaCard({required this.entry, required this.onTap});
  final UnifiedMediaEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final source = entry.mediaItem?.mediaSources?.firstOrNull;
    final video = source?.primaryVideoStream;
    final labels = <String>[];
    if (video?.isDolbyVision == true) {
      labels.add('DV');
    } else if ((video?.videoRange ?? '').toUpperCase().contains('HDR')) {
      labels.add('HDR');
    }
    final codec = (video?.codec ?? video?.videoCodec ?? '').toLowerCase();
    if (codec.contains('hevc') || codec.contains('265')) {
      labels.add('265/HEVC');
    } else if (codec.contains('264') || codec.contains('avc')) {
      labels.add('264');
    }
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(fit: StackFit.expand, children: [
              MediaImage(
                imageUrl: entry.posterUrl,
                httpHeaders: entry.imageHeaders,
                fit: BoxFit.cover,
              ),
              Positioned(
                left: 7,
                top: 7,
                child: SelectedRatingBadge(item: entry.ratingItem),
              ),
              if (labels.isNotEmpty)
                Positioned(
                  right: 7,
                  bottom: 7,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.76),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(labels.join(' · '),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 7),
        Text(entry.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 1.25)),
      ]),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline_rounded, size: 44),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ]),
        ),
      );
}
