import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/feiniu_backend.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_playback.dart';
import '../../widgets/common/media_widgets.dart';

/// 飞牛媒体详情页：统一承载电影、单集与电视剧的季集选择、资源/轨道信息。
class FeiniuMediaDetailScreen extends StatefulWidget {
  const FeiniuMediaDetailScreen({
    super.key,
    required this.server,
    required this.entry,
  });

  final ServerConfig server;
  final SourceEntry entry;

  @override
  State<FeiniuMediaDetailScreen> createState() =>
      _FeiniuMediaDetailScreenState();
}

class _FeiniuMediaDetailScreenState extends State<FeiniuMediaDetailScreen> {
  final _backend = FeiniuBackend();

  FeiniuItemDetail? _detail;
  FeiniuMediaDetails? _media;
  List<SourceEntry> _episodes = const [];
  List<Map<String, dynamic>> _persons = const [];
  SourceEntry? _selectedEntry;
  String? _selectedSeasonId;
  String _core = 'nativeMpv';
  int _audioIndex = 0;
  int _subtitleIndex = -1;
  bool _loading = true;
  bool _loadingMedia = false;
  String? _error;
  int _loadGeneration = 0;

  bool get _isSeries => _detail?.seasons.isNotEmpty == true;

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
      final personGuid = detail.seriesGuid ?? widget.entry.id;
      final personsFuture = _backend.persons(widget.server, personGuid);
      if (!mounted) return;
      _detail = detail;
      await _restoreSeriesPreferences(detail);

      if (detail.seasons.isNotEmpty) {
        final currentSeasonGuid =
            (detail.playInfo['parent_guid'] ?? detail.item['parent_guid'])
                ?.toString();
        final current = detail.seasons.where((season) =>
            _stripPrefix(season.id) == currentSeasonGuid).firstOrNull;
        await _selectSeason((current ?? detail.seasons.first).id,
            preferredEpisodeGuid:
                detail.playInfo['guid']?.toString() ?? widget.entry.id);
      } else {
        _selectedEntry = detail.entry;
        await _loadMedia(detail.entry);
      }
      final persons = await personsFuture;
      if (!mounted) return;
      setState(() {
        _persons = persons;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is SourceException
            ? error.message
            : '获取飞牛详情失败: $error';
      });
    }
  }

  Future<void> _restoreSeriesPreferences(FeiniuItemDetail detail) async {
    final seriesGuid = detail.seriesGuid;
    if (seriesGuid == null || seriesGuid.isEmpty) return;
    final raw = SharedPreferences.getInstance()
        .then((prefs) => prefs.getString(_preferenceKey(seriesGuid)));
    final value = await raw;
    if (value == null || value.isEmpty) return;
    try {
      final map = jsonDecode(value) as Map<String, dynamic>;
      _core = _normalizeCore(map['core']?.toString());
      _audioIndex = (map['audio'] as num?)?.toInt() ?? 0;
      _subtitleIndex = (map['subtitle'] as num?)?.toInt() ?? -1;
    } catch (_) {
      // 损坏的偏好直接忽略，不阻断详情。
    }
  }

  Future<void> _saveSeriesPreferences() async {
    final seriesGuid = _detail?.seriesGuid;
    if (seriesGuid == null || seriesGuid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _preferenceKey(seriesGuid),
      jsonEncode({
        'core': _core,
        'audio': _audioIndex,
        'subtitle': _subtitleIndex,
      }),
    );
  }

  String _preferenceKey(String seriesGuid) =>
      'wjplayer_feiniu_playback_${widget.server.id}_$seriesGuid';

  Future<void> _selectSeason(String seasonId,
      {String? preferredEpisodeGuid}) async {
    setState(() {
      _selectedSeasonId = seasonId;
      _episodes = const [];
      _loadingMedia = true;
    });
    final episodes = await _backend.episodes(widget.server, seasonId);
    if (!mounted || _selectedSeasonId != seasonId) return;
    final preferred = episodes.where((episode) =>
        episode.id == preferredEpisodeGuid).firstOrNull;
    final selected = preferred ?? (episodes.isNotEmpty ? episodes.first : null);
    setState(() {
      _episodes = episodes;
      _selectedEntry = selected;
      _loadingMedia = selected != null;
    });
    if (selected != null) {
      await _loadMedia(selected);
    }
  }

  Future<void> _selectEpisode(SourceEntry entry) async {
    if (_selectedEntry?.id == entry.id) return;
    setState(() => _selectedEntry = entry);
    await _loadMedia(entry);
  }

  Future<void> _loadMedia(SourceEntry entry) async {
    final generation = ++_loadGeneration;
    setState(() {
      _loadingMedia = true;
      _media = null;
    });
    try {
      final media = await _backend.mediaDetails(widget.server, entry);
      if (!mounted || generation != _loadGeneration) return;
      final maxAudio = media.audios.length - 1;
      final maxSubtitle = media.subtitles.length - 1;
      setState(() {
        _media = media;
        _audioIndex =
            maxAudio < 0 ? 0 : _audioIndex.clamp(0, maxAudio).toInt();
        _subtitleIndex = maxSubtitle < 0
            ? -1
            : _subtitleIndex.clamp(-1, maxSubtitle).toInt();
        _loadingMedia = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _media = const FeiniuMediaDetails(playInfo: {}, stream: {});
        _loadingMedia = false;
      });
    }
  }

  Future<void> _play() async {
    final entry = _selectedEntry;
    if (entry == null) return;
    if (_isSeries) await _saveSeriesPreferences();
    await context.push(
      '/source-player',
      extra: SourcePlayback(
        server: widget.server,
        entry: entry,
        playerCoreOverride: _core,
        preferredAudioListIndex:
            _media?.audios.isNotEmpty == true ? _audioIndex : null,
        preferredSubtitleListIndex: _subtitleIndex,
      ),
    );
    if (mounted) await _loadMedia(entry);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null || _detail == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, size: 44),
                const SizedBox(height: 12),
                Text(_error ?? '详情为空', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.tonal(onPressed: _load, child: const Text('重试')),
              ],
            ),
          ),
        ),
      );
    }

    final detail = _detail!;
    final item = detail.item;
    final title = _seriesTitle(item, detail.entry);
    final overview = item['overview']?.toString() ?? '';
    final backdropPath = _firstImagePath(
      item['backdrops'] ?? item['still_path'] ?? item['poster'],
    );
    final backdropUrl =
        _backend.imageUrl(widget.server, backdropPath, width: 1400);
    final posterUrl = detail.entry.thumbUrl;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              expandedHeight: 310,
              pinned: true,
              stretch: true,
              flexibleSpace: FlexibleSpaceBar(
                title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                background: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaImage(
                      imageUrl: backdropUrl.isNotEmpty ? backdropUrl : posterUrl,
                      httpHeaders: detail.entry.thumbHeaders,
                      fit: BoxFit.cover,
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black12, Colors.black87],
                          stops: [0.45, 1],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
              sliver: SliverList.list(children: [
                _buildSummary(context, detail, title),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _selectedEntry == null || _loadingMedia
                        ? null
                        : _play,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(_playLabel()),
                  ),
                ),
                if (overview.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  Text(overview,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(height: 1.65)),
                ],
                if (detail.seasons.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  _sectionTitle(context, '剧集'),
                  const SizedBox(height: 10),
                  _buildSeasons(detail.seasons),
                  const SizedBox(height: 12),
                  _buildEpisodes(),
                ],
                const SizedBox(height: 28),
                _sectionTitle(context, '资源'),
                const SizedBox(height: 12),
                _buildPlaybackOptions(context),
                if (_persons.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  _sectionTitle(context, '演员阵容'),
                  const SizedBox(height: 12),
                  _buildPersons(),
                ],
                const SizedBox(height: 28),
                _sectionTitle(context, '媒体信息'),
                const SizedBox(height: 12),
                if (_loadingMedia)
                  const SizedBox(
                    height: 180,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else
                  _buildMediaCards(context),
                if (_media?.file != null) ...[
                  const SizedBox(height: 14),
                  _buildFileCard(context, _media!.file!),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummary(
      BuildContext context, FeiniuItemDetail detail, String title) {
    final item = detail.item;
    final runtime = (item['runtime'] as num?)?.toInt() ?? 0;
    final chips = <String>[
      if ((item['vote_average']?.toString() ?? '').isNotEmpty)
        '★ ${item['vote_average']}',
      if ((item['release_date']?.toString() ?? '').isNotEmpty)
        item['release_date'].toString().split('-').first,
      if (runtime > 0) '$runtime 分钟',
      if ((item['status']?.toString() ?? '').isNotEmpty)
        item['status'].toString(),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 104,
            height: 150,
            child: MediaImage(
              imageUrl: detail.entry.thumbUrl,
              httpHeaders: detail.entry.thumbHeaders,
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: chips
                    .map((text) => Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text(text),
                        ))
                    .toList(),
              ),
              if (_selectedEntry != null && _isSeries) ...[
                const SizedBox(height: 10),
                Text(
                  _selectedEntry!.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSeasons(List<SourceEntry> seasons) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: seasons.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final season = seasons[index];
          return ChoiceChip(
            label: Text(season.name),
            selected: _selectedSeasonId == season.id,
            onSelected: (_) => _selectSeason(season.id),
          );
        },
      ),
    );
  }

  Widget _buildEpisodes() {
    if (_episodes.isEmpty) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('本季暂无本地剧集')),
      );
    }
    return SizedBox(
      height: 142,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _episodes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, index) {
          final episode = _episodes[index];
          final selected = _selectedEntry?.id == episode.id;
          return SizedBox(
            width: 200,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _selectEpisode(episode),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).dividerColor,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      MediaImage(
                        imageUrl: episode.thumbUrl,
                        httpHeaders: episode.thumbHeaders,
                        fit: BoxFit.cover,
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black87],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 10,
                        right: 10,
                        bottom: 8,
                        child: Text(
                          episode.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (selected)
                        const Positioned(
                          top: 8,
                          right: 8,
                          child: Icon(Icons.check_circle_rounded,
                              color: Colors.white),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlaybackOptions(BuildContext context) {
    final audios = _media?.audios ?? const [];
    final subtitles = _media?.subtitles ?? const [];
    return Column(
      children: [
        _optionRow(
          context,
          icon: Icons.memory_rounded,
          label: '播放内核',
          value: _coreLabel(_core),
          onTap: () => _showCorePicker(context),
        ),
        const SizedBox(height: 8),
        _optionRow(
          context,
          icon: Icons.audiotrack_rounded,
          label: '音频',
          value: audios.isEmpty
              ? '播放后由内核识别'
              : _trackLabel(audios[_audioIndex], _audioIndex, '音轨'),
          onTap: audios.isEmpty ? null : () => _showAudioPicker(context),
        ),
        const SizedBox(height: 8),
        _optionRow(
          context,
          icon: Icons.subtitles_rounded,
          label: '字幕',
          value: _subtitleIndex < 0
              ? (subtitles.isEmpty ? '播放后由内核识别' : '关闭')
              : _trackLabel(
                  subtitles[_subtitleIndex], _subtitleIndex, '字幕'),
          onTap:
              subtitles.isEmpty ? null : () => _showSubtitlePicker(context),
        ),
      ],
    );
  }

  Widget _optionRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              Icon(icon),
              const SizedBox(width: 12),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(value,
                    textAlign: TextAlign.end,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
              if (onTap != null) const Icon(Icons.chevron_right_rounded),
            ]),
          ),
        ),
      ),
    );
  }

  void _showCorePicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          RadioListTile<String>(
            title: const Text('ExoPlayer'),
            subtitle: const Text('Android Media3，轻量硬解'),
            value: 'exoPlayer',
            groupValue: _core,
            onChanged: (value) {
              if (value == null) return;
              setState(() => _core = value);
              Navigator.pop(context);
            },
          ),
          RadioListTile<String>(
            title: const Text('MPV 原生'),
            subtitle: const Text('全格式、多音轨与高级字幕'),
            value: 'nativeMpv',
            groupValue: _core,
            onChanged: (value) {
              if (value == null) return;
              setState(() => _core = value);
              Navigator.pop(context);
            },
          ),
        ]),
      ),
    );
  }

  void _showAudioPicker(BuildContext context) {
    final tracks = _media?.audios ?? const [];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: tracks.length,
          itemBuilder: (_, index) => RadioListTile<int>(
            value: index,
            groupValue: _audioIndex,
            title: Text(_trackLabel(tracks[index], index, '音轨')),
            subtitle: Text(_audioDescription(tracks[index])),
            onChanged: (value) {
              if (value == null) return;
              setState(() => _audioIndex = value);
              Navigator.pop(context);
            },
          ),
        ),
      ),
    );
  }

  void _showSubtitlePicker(BuildContext context) {
    final tracks = _media?.subtitles ?? const [];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            RadioListTile<int>(
              value: -1,
              groupValue: _subtitleIndex,
              title: const Text('关闭字幕'),
              onChanged: (value) {
                setState(() => _subtitleIndex = -1);
                Navigator.pop(context);
              },
            ),
            for (var index = 0; index < tracks.length; index++)
              RadioListTile<int>(
                value: index,
                groupValue: _subtitleIndex,
                title: Text(_trackLabel(tracks[index], index, '字幕')),
                subtitle: Text((tracks[index]['codec_name'] ?? '未知编码')
                    .toString()
                    .toUpperCase()),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _subtitleIndex = value);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPersons() {
    return SizedBox(
      height: 112,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _persons.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, index) {
          final person = _persons[index];
          final image = _backend.imageUrl(
              widget.server, person['profile_path']?.toString(),
              width: 240);
          return SizedBox(
            width: 76,
            child: Column(children: [
              ClipOval(
                child: SizedBox(
                  width: 66,
                  height: 66,
                  child: MediaImage(
                    imageUrl: image,
                    httpHeaders: _detail!.entry.thumbHeaders,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text((person['name'] ?? '未知').toString(),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              Text((person['job'] ?? '').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11)),
            ]),
          );
        },
      ),
    );
  }

  Widget _buildMediaCards(BuildContext context) {
    final media = _media;
    if (media == null ||
        (media.video == null && media.audios.isEmpty && media.subtitles.isEmpty)) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('服务端未返回媒体流信息，播放后仍可由内核识别轨道')),
      );
    }
    final cards = <Widget>[
      if (media.video != null) _videoInfoCard(context, media.video!),
      for (var i = 0; i < media.audios.length; i++)
        _audioInfoCard(context, media.audios[i], i),
      for (var i = 0; i < media.subtitles.length; i++)
        _subtitleInfoCard(context, media.subtitles[i], i),
    ];
    return SizedBox(
      height: 240,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, index) => cards[index],
      ),
    );
  }

  Widget _videoInfoCard(BuildContext context, Map<String, dynamic> stream) {
    return _infoCard(context, '视频', Icons.videocam_rounded, [
      ('编码', stream['codec_name']),
      ('分辨率', _resolution(stream)),
      ('帧率', stream['r_frame_rate']),
      ('码率', _bitrate(stream['bps'])),
      ('位深', stream['bit_depth']),
      ('色彩', stream['color_transfer'] ?? stream['color_space']),
      ('像素格式', stream['pix_fmt']),
    ]);
  }

  Widget _audioInfoCard(
      BuildContext context, Map<String, dynamic> stream, int index) {
    return _infoCard(context, '音频 ${index + 1}', Icons.audiotrack_rounded, [
      ('编码', stream['codec_name']),
      ('语言', stream['language']),
      ('标题', stream['title']),
      ('声道', stream['channels']),
      ('码率', _bitrate(stream['bitrate'])),
      ('流序号', stream['index']),
    ]);
  }

  Widget _subtitleInfoCard(
      BuildContext context, Map<String, dynamic> stream, int index) {
    return _infoCard(context, '字幕 ${index + 1}', Icons.subtitles_rounded, [
      ('编码', stream['codec_name']),
      ('语言', stream['language']),
      ('标题', stream['title']),
      ('流序号', stream['index']),
      ('外挂', stream['is_external'] == true ? '是' : '否'),
    ]);
  }

  Widget _infoCard(
    BuildContext context,
    String title,
    IconData icon,
    List<(String, dynamic)> rows,
  ) {
    final visible = rows.where((row) {
      final value = row.$2;
      return value != null && value.toString().isNotEmpty && value != 0;
    }).toList();
    return Container(
      width: 224,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 12),
          for (final row in visible)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 60,
                    child: Text(row.$1,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                  Expanded(
                    child: Text(row.$2.toString(),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFileCard(BuildContext context, Map<String, dynamic> file) {
    final name = (file['file_name'] ?? '').toString();
    final path = (file['path'] ?? '').toString();
    final size = (file['size'] as num?)?.toInt() ?? 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.folder_open_rounded, size: 20),
          SizedBox(width: 8),
          Text('视频文件', style: TextStyle(fontWeight: FontWeight.w800)),
        ]),
        if (name.isNotEmpty) ...[
          const SizedBox(height: 10),
          SelectableText(name),
        ],
        if (path.isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText(path,
              style: Theme.of(context).textTheme.bodySmall),
        ],
        if (size > 0) ...[
          const SizedBox(height: 8),
          Text(formatSourceFileSize(size)),
        ],
      ]),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleLarge
            ?.copyWith(fontWeight: FontWeight.w800),
      );

  String _playLabel() {
    final entry = _selectedEntry;
    if (entry == null) return '暂无可播放资源';
    final ts = (_media?.playInfo['ts'] as num?)?.toInt() ?? 0;
    return ts > 0 ? '继续播放  ${entry.name}' : '播放  ${entry.name}';
  }

  String _seriesTitle(Map<String, dynamic> item, SourceEntry entry) =>
      (item['tv_title'] ?? item['title'] ?? entry.name).toString();

  String _stripPrefix(String value) =>
      value.contains(':') ? value.substring(value.indexOf(':') + 1) : value;

  String _normalizeCore(String? core) =>
      core == 'exoPlayer' ? 'exoPlayer' : 'nativeMpv';

  String _coreLabel(String core) =>
      core == 'exoPlayer' ? 'ExoPlayer' : 'MPV 原生';

  String _trackLabel(Map<String, dynamic> track, int index, String fallback) {
    final title = track['title']?.toString().trim() ?? '';
    final language = track['language']?.toString().trim() ?? '';
    final codec = track['codec_name']?.toString().trim().toUpperCase() ?? '';
    if (title.isNotEmpty) return title;
    final parts = [language, codec].where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? '$fallback ${index + 1}' : parts.join(' · ');
  }

  String _audioDescription(Map<String, dynamic> track) {
    final parts = <String>[];
    final codec = track['codec_name']?.toString().toUpperCase() ?? '';
    if (codec.isNotEmpty) parts.add(codec);
    final channels = (track['channels'] as num?)?.toInt() ?? 0;
    if (channels > 0) parts.add('$channels 声道');
    final bitrate = _bitrate(track['bitrate']);
    if (bitrate.isNotEmpty) parts.add(bitrate);
    return parts.isEmpty ? '音频流' : parts.join(' · ');
  }

  String _resolution(Map<String, dynamic> stream) {
    final width = (stream['width'] as num?)?.toInt() ?? 0;
    final height = (stream['height'] as num?)?.toInt() ?? 0;
    return width > 0 && height > 0 ? '${width}×$height' : '';
  }

  String _bitrate(dynamic value) {
    final bitrate = value is num ? value.toInt() : int.tryParse('$value') ?? 0;
    if (bitrate <= 0) return '';
    return '${(bitrate / 1000000).toStringAsFixed(1)} Mbps';
  }

  String? _firstImagePath(dynamic value) {
    if (value is String && value.isNotEmpty) return value;
    if (value is List && value.isNotEmpty) return value.first?.toString();
    return null;
  }
}
