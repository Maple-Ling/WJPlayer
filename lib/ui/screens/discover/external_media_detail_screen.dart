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
import '../../widgets/common/media_widgets.dart';

class ExternalMediaDetailScreen extends ConsumerStatefulWidget {
  const ExternalMediaDetailScreen({super.key, required this.entry});
  final DiscoverEntry entry;

  @override
  ConsumerState<ExternalMediaDetailScreen> createState() => _ExternalMediaDetailScreenState();
}

class _ExternalMediaDetailScreenState extends ConsumerState<ExternalMediaDetailScreen> {
  int _season = 1;
  ExternalEpisode? _episode;

  String _matchQuery(ExternalMediaDetail detail) {
    if (detail.mediaType != 'tv') return detail.title;
    final season = _season.toString().padLeft(2, '0');
    final episode = _episode?.number.toString().padLeft(2, '0');
    return episode == null ? '${detail.title} S$season' : '${detail.title} S${season}E$episode';
  }

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
    final seasonInfo = detail.mediaType == 'tv'
        ? ref.watch(externalSeasonProvider((tmdbId: detail.tmdbId, season: _season)))
        : const AsyncValue<ExternalSeason>.data(ExternalSeason(id: 0, number: 0, name: '电影'));
    final selectedEpisode = _episode ?? seasonInfo.asData?.value.episodes.firstOrNull;
    if (_episode == null && selectedEpisode != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _episode == null) setState(() => _episode = selectedEpisode);
      });
    }

    return Scaffold(
      body: Stack(children: [
        Positioned.fill(child: ColoredBox(color: Theme.of(context).scaffoldBackgroundColor)),
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
              background: Stack(fit: StackFit.expand, children: [
                MediaImage(imageUrl: detail.posterUrl ?? detail.backdropUrl, fit: BoxFit.cover, alignment: Alignment.topCenter),
                const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0x22000000), Color(0xFFF0F2F0)], stops: [0.45, 0.72, 1]))),
                Positioned(left: 28, right: 28, bottom: 28, child: Column(children: [
                  Text(detail.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Color(0xFF252525), shadows: [Shadow(color: Colors.white54, blurRadius: 8)])),
                  const SizedBox(height: 12),
                  Wrap(alignment: WrapAlignment.center, spacing: 10, runSpacing: 6, children: [
                    if (detail.rating != null) Text('⭐ ${detail.rating!.toStringAsFixed(1)}', style: _heroMeta),
                    if (detail.year != null) Text(detail.year!, style: _heroMeta),
                    if (detail.numberOfSeasons != null) Text('共${detail.numberOfSeasons}季', style: _heroMeta),
                  ]),
                  const SizedBox(height: 6),
                  Text(detail.genres.join(' · '), style: _heroMeta, textAlign: TextAlign.center),
                ])),
              ]),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
            sliver: SliverList.list(children: [
              _primaryPlayButton(matches, selectedEpisode),
              const SizedBox(height: 14),
              if ((detail.overview ?? '').isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  initiallyExpanded: false,
                  title: const Text('简介', style: TextStyle(fontWeight: FontWeight.w800)),
                  children: [Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(detail.overview!, style: const TextStyle(fontSize: 12, height: 1.65, color: Color(0xFF4F4F4F))))],
                ),
              if (detail.mediaType == 'tv') ...[
                const SizedBox(height: 18),
                _seasonSelector(detail),
                const SizedBox(height: 18),
                seasonInfo.when(
                  loading: () => const SizedBox(height: 220, child: Center(child: CircularProgressIndicator())),
                  error: (_, __) => const Text('分集加载失败'),
                  data: (value) => _episodes(value),
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
            ]),
          ),
        ]),
      ]),
    );
  }

  static const _heroMeta = TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF3B3B3B));

  Widget _roundButton(IconData icon, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.all(6),
    child: Material(color: Colors.black.withValues(alpha: 0.42), shape: const CircleBorder(), child: IconButton(onPressed: onTap, icon: Icon(icon, color: Colors.white, size: 30))),
  );

  Widget _primaryPlayButton(AsyncValue<List<ServerMatchInfo>> matches, ExternalEpisode? episode) {
    final first = matches.asData?.value.firstOrNull;
    return Center(child: SizedBox(width: 185, height: 50, child: FilledButton.icon(
      style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, shape: const StadiumBorder(), elevation: 0),
      onPressed: first == null ? null : () => _openMatch(first, directPlay: true),
      icon: const Icon(Icons.play_arrow_rounded, size: 23),
      label: Text(first == null ? '搜索中' : '播放', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
    )));
  }

  Widget _seasonSelector(ExternalMediaDetail detail) => Row(children: [
    Text('第 $_season 季', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
    PopupMenuButton<int>(icon: const Icon(Icons.unfold_more_rounded), onSelected: (value) => setState(() { _season = value; _episode = null; }), itemBuilder: (_) => [for (final season in detail.seasons.where((e) => e.number > 0)) PopupMenuItem(value: season.number, child: Text(season.name))]),
  ]);

  Widget _episodes(ExternalSeason season) => SizedBox(height: 220, child: ListView.separated(
    scrollDirection: Axis.horizontal,
    itemCount: season.episodes.length,
    separatorBuilder: (_, __) => const SizedBox(width: 8),
    itemBuilder: (_, index) {
      final episode = season.episodes[index];
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

  Widget _resources(AsyncValue<List<ServerMatchInfo>> async) => async.when(
    loading: () => const SizedBox(height: 150, child: Center(child: CircularProgressIndicator())),
    error: (_, __) => const Text('资源搜索失败'),
    data: (matches) => matches.isEmpty
        ? const SizedBox(height: 100, child: Center(child: Text('所有媒体库均未找到匹配资源')))
        : SizedBox(
            height: 105,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: matches.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, index) {
                final match = matches[index];
                final specs = _resourceSpecs(match.item);
                return SizedBox(
                  width: 220,
                  child: Card(
                    child: InkWell(
                      onTap: () => _openMatch(match, directPlay: true),
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              const Icon(Icons.play_circle_fill_rounded, color: Color(0xFF4CAF50)),
                              const SizedBox(width: 8),
                              Expanded(child: Text(match.serverName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800))),
                              if (index == 0) const Chip(label: Text('最佳资源'), visualDensity: VisualDensity.compact),
                            ]),
                            const Spacer(),
                            Text(match.item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 3),
                            Text(match.episodeCount == null ? match.item.type : '共 ${match.episodeCount} 集', style: const TextStyle(color: Colors.black54)),
                            if (specs.isNotEmpty) ...[
                              const SizedBox(height: 5),
                              Text(specs.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
  );

  List<String> _resourceSpecs(MediaItem item) {
    final sources = item.mediaSources;
    if (sources == null || sources.isEmpty) return const [];
    final source = sources.first;
    final video = source.primaryVideoStream;
    if (video == null) return const [];
    final values = <String>[
      if (video.resolution.isNotEmpty) video.resolution,
      if (video.videoRangeLabel.isNotEmpty) video.videoRangeLabel,
      if (video.videoCodecLabel.isNotEmpty) video.videoCodecLabel,
      if (source.size != null && source.size! > 0) _formatSize(source.size!),
      if (video.bitRate != null && video.bitRate! > 0) '${(video.bitRate! / 1000000).toStringAsFixed(1)} Mbps',
    ];
    return values;
  }

  String _formatSize(int bytes) {
    if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  Widget _people(List<ExternalPerson> people) => SizedBox(height: 105, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: people.length, separatorBuilder: (_, __) => const SizedBox(width: 9), itemBuilder: (_, index) { final person = people[index]; return InkWell(onTap: () => _showPerson(person), child: SizedBox(width: 78, child: Column(children: [ClipOval(child: SizedBox(width: 58, height: 58, child: MediaImage(imageUrl: person.profileUrl, fit: BoxFit.cover))), const SizedBox(height: 8), Text(person.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)), Text(person.character ?? person.originalName ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black54))]))); }));

  Widget _gallery(List<String> images) => SizedBox(height: 150, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: images.length, separatorBuilder: (_, __) => const SizedBox(width: 9), itemBuilder: (_, index) => InkWell(onTap: () => _showImage(images, index), child: AspectRatio(aspectRatio: 16 / 9, child: ClipRRect(borderRadius: BorderRadius.circular(18), child: MediaImage(imageUrl: images[index], fit: BoxFit.cover))))));

  Widget _recommendations(List<DiscoverEntry> items) => SizedBox(height: 180, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: items.length, separatorBuilder: (_, __) => const SizedBox(width: 8), itemBuilder: (_, index) { final item = items[index]; return InkWell(onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExternalMediaDetailScreen(entry: item))), child: SizedBox(width: 100, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(18), child: MediaImage(imageUrl: item.posterUrl, fit: BoxFit.cover))), const SizedBox(height: 8), Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)), Text(item.year ?? '', style: const TextStyle(color: Colors.black54))]))); }));

  Widget _links(ExternalMediaDetail detail) { final values = <(String,String)>[('TMDB','https://www.themoviedb.org/${detail.mediaType}/${detail.tmdbId}'), if (detail.imdbId != null) ('IMDb','https://www.imdb.com/title/${detail.imdbId}/'), if (detail.doubanId != null) ('豆瓣','https://movie.douban.com/subject/${detail.doubanId}/')]; return Wrap(spacing: 12, runSpacing: 10, children: [for (final value in values) ActionChip(avatar: const Icon(Icons.open_in_new_rounded, size: 17), label: Text(value.$1), onPressed: () => launchUrl(Uri.parse(value.$2), mode: LaunchMode.externalApplication))]); }

  Widget _companies(List<ExternalCompany> companies) => SizedBox(height: 54, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: companies.length, separatorBuilder: (_, __) => const SizedBox(width: 12), itemBuilder: (_, index) => ActionChip(avatar: companies[index].logoUrl == null ? null : SizedBox(width: 28, height: 20, child: MediaImage(imageUrl: companies[index].logoUrl, fit: BoxFit.contain)), label: Text(companies[index].name), onPressed: () {})));

  Widget _sectionTitle(String title, {Widget? trailing}) => Row(children: [Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)), const Spacer(), if (trailing != null) trailing]);

  void _openMatch(ServerMatchInfo match, {required bool directPlay}) { final source = match.sourceEntry; if (source != null && match.sourceServerId != null) { final server = ref.read(serverListProvider).where((s) => s.id == match.sourceServerId).firstOrNull; if (server != null) { ref.read(currentServerProvider.notifier).state = server; context.push('/source-player', extra: SourcePlayback(server: server, entry: source)); return; } } if (directPlay && (match.item.type == 'Movie' || match.item.type == 'Episode')) { final origin = match.item.sourceServerId; if (origin != null) ref.read(currentServerProvider.notifier).syncWithAvailableServers(ref.read(serverListProvider), preferredServerId: origin); context.push('/player/${match.item.id}'); } else { openMediaItem(ref, context, match.item); } }

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
