import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/api/discover/discover_models.dart';
import '../../../core/api/discover/external_media_models.dart';
import '../../../core/providers/external_media_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/sources/source_playback.dart';
import '../../utils/media_helpers.dart';
import '../source/unified_media_screens.dart';
import '../../widgets/common/collapsible_overview.dart';
import '../../widgets/common/media_widgets.dart';
import '../../widgets/common/adaptive_poster_blend.dart';
import '../../widgets/common/playback_resource_card.dart';
import '../../widgets/common/tv_focusable.dart';
import '../../widgets/common/app_toast.dart';

class ExternalMediaDetailScreen extends ConsumerStatefulWidget {
  const ExternalMediaDetailScreen({super.key, required this.entry});
  final DiscoverEntry entry;

  @override
  ConsumerState<ExternalMediaDetailScreen> createState() => _ExternalMediaDetailScreenState();
}

class _ExternalMediaDetailScreenState extends ConsumerState<ExternalMediaDetailScreen> {
  int _season = 1;
  int _episodeRangeStart = 1;
  ExternalEpisode? _episode;
  int _selectedServerIndex = 0;
  List<ServerMatchInfo> _latestMatches = const [];
  bool _hasSelectedServer = false;
  Color? _backgroundColor;

  /// 跨服务器搜索关键词：一律用纯标题（与 BCD 详情页/播放器聚合一致）。
  /// 注意：不能拼接 SxxExx —— Emby search 的 IncludeItemTypes 硬编码
  /// Movie,Series（单集永远搜不到），飞牛库内 contains 匹配也必空，
  /// 带季集号只会让顶层剧集/电影全部落空。
  String _matchQuery(ExternalMediaDetail detail) => detail.title;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(externalMediaDetailProvider(widget.entry));
    return async.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_rounded, size: 48),
          const SizedBox(height: 12),
          Text('详情加载失败\n$error', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => ref.invalidate(externalMediaDetailProvider(widget.entry)), child: const Text('重试')),
        ])),
      ),
      data: _buildDetail,
    );
  }

  Widget _buildDetail(ExternalMediaDetail detail) {
    final query = _matchQuery(detail);
    final matches = ref.watch(rankingCrossServerMatchProvider(query));
    matches.whenData((value) {
      if (value.isNotEmpty && !_hasSelectedServer) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _hasSelectedServer) return;
          setState(() {
            _latestMatches = value;
            _selectedServerIndex = 0;
          });
        });
      } else if (value.isNotEmpty) {
        _latestMatches = value;
      }
    });
    final seasonInfo = widget.entry.source == ReviewSource.tmdb &&
            detail.mediaType == 'tv' &&
            detail.tmdbId > 0
        ? ref.watch(externalSeasonProvider((tmdbId: detail.tmdbId, season: _season)))
        : const AsyncValue<ExternalSeason>.data(
            ExternalSeason(id: 0, number: 0, name: '暂无分集'));
    final selectedEpisode = _episode ?? seasonInfo.asData?.value.episodes.firstOrNull;
    if (_episode == null && selectedEpisode != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _episode == null) setState(() => _episode = selectedEpisode);
      });
    }

    final background = _backgroundColor ?? Theme.of(context).scaffoldBackgroundColor;
    return Scaffold(
      backgroundColor: background,
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        color: background,
        child: Stack(children: [
        CustomScrollView(slivers: [
          SliverAppBar(
            expandedHeight: MediaQuery.sizeOf(context).height * 0.44,
            pinned: true,
            stretch: true,
            backgroundColor: Colors.transparent,
            leading: _roundButton(Icons.arrow_back_rounded, () => context.pop()),
            actions: [_roundButton(Icons.more_vert_rounded, () => _showLinks(detail))],
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.parallax,
              background: AdaptivePosterBlend(
                imageUrl: detail.backdropUrl ?? detail.posterUrl,
                onBackgroundChanged: (color) {
                  if (mounted && color != _backgroundColor) {
                    setState(() => _backgroundColor = color);
                  }
                },
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (detail.logoUrl?.isNotEmpty == true)
                    SizedBox(
                      width: 250,
                      height: 90,
                      child: MediaImage(imageUrl: detail.logoUrl, fit: BoxFit.contain),
                    )
                  else
                    Text(detail.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 29, fontWeight: FontWeight.w900, color: Color(0xFF252525), shadows: [Shadow(color: Colors.white70, blurRadius: 10)])),
                  const SizedBox(height: 12),
                  Wrap(alignment: WrapAlignment.center, spacing: 10, runSpacing: 6, children: [
                    if (detail.rating != null) Text('⭐ ${detail.rating!.toStringAsFixed(1)}', style: _heroMeta),
                    if (detail.year != null) Text(detail.year!, style: _heroMeta),
                    if (detail.numberOfSeasons != null) Text('共${detail.numberOfSeasons}季', style: _heroMeta),
                  ]),
                  const SizedBox(height: 6),
                  Text(detail.genres.join(' · '), style: _heroMeta, textAlign: TextAlign.center),
                    ]),
                  ),
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
            sliver: SliverList.list(children: [
              _primaryPlayButton(matches, selectedEpisode),
              const SizedBox(height: 14),
              if ((detail.overview ?? '').isNotEmpty)
                CollapsibleOverview(text: detail.overview!),
              if (detail.seasons.isNotEmpty) ...[
                const SizedBox(height: 18),
                _seasonSelector(detail),
                const SizedBox(height: 18),
                seasonInfo.when(
                  loading: () => const SizedBox(height: 220, child: Center(child: CircularProgressIndicator())),
                  error: (_, __) => const Text('分集加载失败'),
                  data: (value) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _episodeRangeCapsules(value),
                      const SizedBox(height: 10),
                      _episodes(value),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              _sectionTitle('播放资源', trailing: TextButton(onPressed: () => _showAllResources(query), child: const Text('查看更多  ›'))),
              const SizedBox(height: 14),
              _resources(matches),
              if (detail.people.isNotEmpty) ...[
                const SizedBox(height: 20), _sectionTitle('演员'), const SizedBox(height: 16), _people(detail.people),
              ],
              if (detail.images.isNotEmpty) ...[
                const SizedBox(height: 20), _sectionTitle('剧照'), const SizedBox(height: 16), _gallery(detail.images),
              ],
              if (detail.recommendations.isNotEmpty) ...[
                const SizedBox(height: 20), _sectionTitle('相似推荐'), const SizedBox(height: 16), _recommendations(detail.recommendations),
              ],
              const SizedBox(height: 20), _sectionTitle('链接'), const SizedBox(height: 14), _links(detail),
              if (detail.companies.isNotEmpty) ...[
                const SizedBox(height: 20), _sectionTitle('工作室'), const SizedBox(height: 14), _companies(detail.companies),
              ],
              const SizedBox(height: 20), _sectionTitle('媒体信息'), const SizedBox(height: 14), _mediaInfo(detail),
            ]),
          ),
        ]),
      ]),
    ),
    );
  }

  static const _heroMeta = TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF3B3B3B));

  Widget _roundButton(IconData icon, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.all(6),
    child: Material(color: Colors.black.withValues(alpha: 0.42), shape: const CircleBorder(), child: IconButton(onPressed: onTap, icon: Icon(icon, color: Colors.white, size: 30))),
  );

  Widget _primaryPlayButton(AsyncValue<List<ServerMatchInfo>> matches, ExternalEpisode? episode) {
    final list = _latestMatches.isNotEmpty
        ? _latestMatches
        : (matches.asData?.value ?? const <ServerMatchInfo>[]);
    final selected = list.isEmpty
        ? null
        : list[_selectedServerIndex.clamp(0, list.length - 1)];
    return Center(child: SizedBox(width: 185, height: 50, child: TvFocusable(
      autofocus: true,
      enabled: selected != null,
      borderRadius: 999,
      onActivate: selected == null ? () {} : () => _openMatch(selected, directPlay: true),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, shape: const StadiumBorder(), elevation: 0),
        onPressed: selected == null ? null : () => _openMatch(selected, directPlay: true),
        icon: const Icon(Icons.play_arrow_rounded, size: 23),
        label: Text(selected == null ? '搜索中' : '播放', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
      ),
    )));
  }

  Widget _seasonSelector(ExternalMediaDetail detail) {
    final seasons = detail.seasons.where((e) => e.number > 0).toList();
    if (seasons.isEmpty) return const SizedBox.shrink();
    return Row(children: [
      const Icon(Icons.video_library_rounded, size: 16, color: Color(0xFF5B8DEF)),
      const SizedBox(width: 6),
      Text('第 $_season 季', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
      const SizedBox(width: 6),
      ExcludeFocus(
        child: PopupMenuButton<int>(
          icon: const Icon(Icons.unfold_more_rounded, size: 20),
          tooltip: '切换分季',
          onSelected: (value) => setState(() {
            _season = value;
            _episode = null;
            _episodeRangeStart = 1;
          }),
          itemBuilder: (_) => [for (final season in seasons) PopupMenuItem(value: season.number, child: Text(season.name))],
        ),
      ),
    ]);
  }

  /// 1-10 / 11-20 / 21-30 分段切换胶囊，选中态带主色 + 阴影，未选中浅色描边。
  Widget _episodeRangeCapsules(ExternalSeason season) {
    final episodes = season.episodes;
    if (episodes.length <= 10) return const SizedBox.shrink();
    final ranges = <int>[
      for (var start = 1; start <= episodes.length; start += 10) start,
    ];
    final selectedStart = _episodeRangeStart.clamp(1, ranges.last);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: ranges.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final start = ranges[index];
          final end = (start + 9).clamp(start, episodes.length);
          final selected = start == selectedStart;
          return GestureDetector(
            onTap: () => setState(() {
              _episodeRangeStart = start;
              final current = _episode?.number ?? 0;
              if (current < start || current > end) _episode = null;
            }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                gradient: selected
                    ? LinearGradient(
                        colors: [scheme.primary, scheme.primary.withValues(alpha: 0.78)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                color: selected ? null : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
                border: selected
                    ? null
                    : Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.32),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) ...[
                    const Icon(Icons.check_rounded, size: 14, color: Colors.white),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    '$start-$end',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                      color: selected
                          ? Colors.white
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _episodes(ExternalSeason season) {
    final end = (_episodeRangeStart + 9).clamp(_episodeRangeStart, season.episodes.length);
    final visible = season.episodes.where((episode) =>
        episode.number >= _episodeRangeStart && episode.number <= end).toList();
    return SizedBox(height: 232, child: ListView.separated(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      itemCount: visible.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10),
      itemBuilder: (_, index) {
        final episode = visible[index];
        final selected = _episode?.number == episode.number;
        return SizedBox(width: 220, child: InkWell(
          onTap: () => setState(() => _episode = episode),
          borderRadius: BorderRadius.circular(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AspectRatio(aspectRatio: 16 / 9, child: ClipRRect(borderRadius: BorderRadius.circular(18), child: Stack(fit: StackFit.expand, children: [MediaImage(imageUrl: episode.stillUrl, fit: BoxFit.cover), if (selected) DecoratedBox(decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.primary, width: 4), borderRadius: BorderRadius.circular(18)))]))),
            const SizedBox(height: 12),
            Row(children: [Text('第 ${episode.number} 集', style: const TextStyle(fontWeight: FontWeight.w800)), const SizedBox(width: 8), Text(episode.runtime == null ? '' : '· ${episode.runtime}m', style: const TextStyle(color: Colors.black54)), const Spacer(), Text(episode.airDate ?? '', style: const TextStyle(color: Colors.black54))]),
            const SizedBox(height: 5),
            Text(episode.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
            const SizedBox(height: 5),
            Text(episode.overview ?? '', maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(height: 1.35, color: Colors.black54)),
          ]),
        ));
      },
    ));
  }

  Widget _resources(AsyncValue<List<ServerMatchInfo>> async) => async.when(
    loading: () => const SizedBox(height: 150, child: Center(child: CircularProgressIndicator())),
    error: (_, __) => const Text('资源搜索失败'),
    data: (matches) => matches.isEmpty
        ? const SizedBox(height: 100, child: Center(child: Text('所有媒体库均未找到匹配资源')))
        : SizedBox(
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
                  child: TvFocusable(
                    onActivate: () => setState(() {
                      _latestMatches = matches;
                      _selectedServerIndex = index;
                      _hasSelectedServer = true;
                    }),
                    borderRadius: 12,
                    child: PlaybackResourceCard(
                      serverName: match.serverName,
                      isBest: index == 0,
                      isSelected: _latestMatches.isNotEmpty &&
                          _selectedServerIndex == index,
                      resolution: info.resolution,
                      dynamicRange: info.dynamicRange,
                      codec: info.codec,
                      frameRate: info.frameRate,
                      size: info.size,
                      bitrate: info.bitrate,
                      onTap: () {
                        setState(() {
                          _latestMatches = matches;
                          _selectedServerIndex = index;
                          _hasSelectedServer = true;
                        });
                      },
                      onDoubleTap: () => _openMatch(match, directPlay: false),
                    ),
                  ),
                );
              },
            ),
          ),
  );

  Widget _people(List<ExternalPerson> people) => SizedBox(height: 105, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: people.length, separatorBuilder: (_, __) => const SizedBox(width: 9), itemBuilder: (_, index) { final person = people[index]; return SizedBox(width: 78, child: TvFocusable(onActivate: () => _showPerson(person), borderRadius: 30, child: InkWell(onTap: () => _showPerson(person), child: Column(children: [ClipOval(child: SizedBox(width: 58, height: 58, child: MediaImage(imageUrl: person.profileUrl, fit: BoxFit.cover, cacheWidth: 120))), const SizedBox(height: 8), Text(person.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)), Text(person.character ?? person.originalName ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black54))])))); }));

  Widget _gallery(List<String> images) => SizedBox(height: 150, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: images.length, separatorBuilder: (_, __) => const SizedBox(width: 9), itemBuilder: (_, index) => TvFocusable(onActivate: () => _showImage(images, index), borderRadius: 18, child: InkWell(onTap: () => _showImage(images, index), child: AspectRatio(aspectRatio: 16 / 9, child: ClipRRect(borderRadius: BorderRadius.circular(18), child: MediaImage(imageUrl: images[index], fit: BoxFit.cover, cacheWidth: 320)))))));

  Widget _recommendations(List<DiscoverEntry> items) => SizedBox(height: 196, child: ListView.separated(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10), itemBuilder: (_, index) { final item = items[index]; return TvFocusable(onActivate: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExternalMediaDetailScreen(entry: item))), borderRadius: 18, child: InkWell(onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExternalMediaDetailScreen(entry: item))), child: SizedBox(width: 100, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(18), child: MediaImage(imageUrl: item.posterUrl, fit: BoxFit.cover, cacheWidth: 200))), const SizedBox(height: 8), Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)), Text(item.year ?? '', style: const TextStyle(color: Colors.black54))])))); }));

  Widget _mediaInfo(ExternalMediaDetail detail) {
    final values = <(String, String)>[
      ('来源', widget.entry.source.label),
      ('类型', detail.mediaType == 'tv' ? '剧集' : '电影'),
      if (detail.originalTitle?.isNotEmpty == true)
        ('原名', detail.originalTitle!),
      if (detail.year?.isNotEmpty == true) ('年份', detail.year!),
      if (detail.runtime != null && detail.runtime! > 0)
        ('时长', '${detail.runtime} 分钟'),
      if (detail.numberOfSeasons != null && detail.numberOfSeasons! > 0)
        ('季数', '${detail.numberOfSeasons}'),
      if (detail.status?.isNotEmpty == true) ('状态', detail.status!),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          TvFocusable(
            onActivate: () {},
            borderRadius: 999,
            child: Chip(label: Text('${value.$1}  ${value.$2}')),
          ),
      ],
    );
  }

  Widget _links(ExternalMediaDetail detail) {
    final query = Uri.encodeQueryComponent('${detail.title} ${detail.year ?? ''}'.trim());
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
        TvFocusable(
          onActivate: () => launchUrl(
            Uri.parse(value.$2),
            mode: LaunchMode.externalApplication,
          ),
          borderRadius: 999,
          child: ActionChip(
            avatar: const Icon(Icons.open_in_new_rounded, size: 17),
            label: Text(value.$1),
            onPressed: () => launchUrl(
              Uri.parse(value.$2),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ),
    ]);
  }

  Widget _companies(List<ExternalCompany> companies) => SizedBox(height: 54, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: companies.length, separatorBuilder: (_, __) => const SizedBox(width: 12), itemBuilder: (_, index) => TvFocusable(onActivate: () {}, borderRadius: 999, child: ActionChip(avatar: companies[index].logoUrl == null ? null : SizedBox(width: 28, height: 20, child: MediaImage(imageUrl: companies[index].logoUrl, fit: BoxFit.contain)), label: Text(companies[index].name), onPressed: () {}))));

  Widget _sectionTitle(String title, {Widget? trailing}) => Row(children: [Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)), const Spacer(), if (trailing != null) trailing]);

  void _openMatch(ServerMatchInfo match, {required bool directPlay}) {
    // 非飞牛服务器匹配：sourceServerId 可能只在 MediaItem 上。
    final server = match.sourceServerId != null
        ? ref.read(serverListProvider).where((s) => s.id == match.sourceServerId).firstOrNull
        : match.item.sourceServerId != null
            ? ref.read(serverListProvider).where((s) => s.id == match.item.sourceServerId).firstOrNull
            : null;
    final source = match.sourceEntry;
    if (!directPlay) {
      if (server != null) {
        ref.read(currentServerProvider.notifier).state = server;
      }
      if (server != null) {
        openMediaItem(ref, context, match.item);
      }
      return;
    }
    if (source != null && server != null) {
      ref.read(currentServerProvider.notifier).state = server;
      if (!context.mounted) return;
      // 飞牛顶层剧集（tv/series）无直接媒体流：resolvePlay 拿不到 media_guid
      // 必报「未获取到播放媒体」。进该服务器详情页自动播放所选集
      // （未选集则继续上次/首集），与 BCD 行为一致。
      final feiniuType =
          source.raw?['type']?.toString().trim().toLowerCase();
      if (feiniuType == 'tv' || feiniuType == 'series') {
        context.push(
          '/detail/${Uri.encodeComponent(source.id)}',
          extra: UnifiedMediaDetailRouteExtra(
            server: server,
            entry: unifiedEntryFromSource(source),
            autoPlay: true,
            targetEpisodeNumber: _episode?.number,
          ),
        );
        return;
      }
      context.push('/source-player', extra: SourcePlayback(server: server, entry: source));
      return;
    }
    if (match.item.type == 'Movie' || match.item.type == 'Episode') {
      final origin = match.item.sourceServerId;
      if (origin != null) {
        ref.read(currentServerProvider.notifier).syncWithAvailableServers(
            ref.read(serverListProvider), preferredServerId: origin);
      }
      if (!context.mounted) return;
      context.push('/player/${match.item.id}');
    } else {
      openMediaItem(ref, context, match.item);
    }
  }

  void _showAllResources(String query) => showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => SizedBox(height: MediaQuery.sizeOf(context).height * .75, child: Consumer(builder: (context, ref, _) => Padding(padding: const EdgeInsets.all(18), child: Column(children: [const Text('全部播放资源', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)), const SizedBox(height: 12), Expanded(child: ref.watch(rankingCrossServerMatchProvider(query)).when(loading: () => const Center(child: CircularProgressIndicator()), error: (_, __) => const Center(child: Text('搜索失败')), data: (matches) => ListView(children: [for (final match in matches) ListTile(leading: const Icon(Icons.play_circle_outline_rounded), title: Text(match.serverName), subtitle: Text(match.item.name), onTap: () { Navigator.pop(context); _openMatch(match, directPlay: true); })])))])))));

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
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(person.originalName ?? person.character ?? ''),
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
                      error: (_, __) => const Center(
                        child: Text('作品加载失败'),
                      ),
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

  void _showImage(List<String> images, int initial) => showDialog<void>(context: context, barrierColor: Colors.black, builder: (_) => Dialog.fullscreen(backgroundColor: Colors.black, child: Stack(children: [PageView.builder(controller: PageController(initialPage: initial), itemCount: images.length, itemBuilder: (_, i) => InteractiveViewer(minScale: 1, maxScale: 5, child: Center(child: MediaImage(imageUrl: images[i], fit: BoxFit.contain)))), SafeArea(child: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.white, size: 30)))])));

  void _showLinks(ExternalMediaDetail detail) => showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (_) => SafeArea(child: Padding(padding: const EdgeInsets.all(18), child: _links(detail))));
}
