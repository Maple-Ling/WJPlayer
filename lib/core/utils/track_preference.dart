/// 基于正则的「版本 / 字幕 / 音频」偏好匹配工具。
///
/// 用户可在设置页用正则表达式表达对片源版本、字幕轨、音频轨的偏好（如
/// 「4K」「中文|简|繁|chi」「jpn|日|flac」）。播放初始化时按这些正则自动挑选最
/// 符合的媒体源 / 轨道。正则统一大小写不敏感、开启 unicode（便于匹配中文）。
library;

import '../api/api_interfaces.dart';

/// 把正则字符串安全编译为大小写不敏感的 [RegExp]。
///
/// 空串或非法正则返回 null —— 调用方据此回退到默认（语言匹配/首个）行为，
/// 避免用户输错正则导致播放选轨异常。
RegExp? compilePreferenceRegex(String? pattern) {
  final p = pattern?.trim() ?? '';
  if (p.isEmpty) return null;
  try {
    return RegExp(p, caseSensitive: false, unicode: true);
  } catch (_) {
    return null;
  }
}

/// 媒体源（版本）的可匹配文本：名称 + 容器 + 视频分辨率/编码 + 显示名。
///
/// 用于「版本选择」正则反查，例如正则 `4K|2160` 命中 4K 片源。
String mediaSourceSearchText(MediaSource source) {
  final parts = <String?>[source.name, source.container];
  for (final s in source.mediaStreams) {
    if (s.isVideo) {
      parts
        ..add(s.resolution)
        ..add(s.codec)
        ..add(s.displayTitle);
    }
  }
  return parts.where((e) => e != null && e.isNotEmpty).join(' ');
}

/// 字幕 / 音频轨道的可匹配文本：显示名 + 标题 + 语言 + 编码（音频附带声道）。
///
/// 用于「字幕/音频选择」正则筛选，例如 `中文|简|繁|chi|zh` 命中各种中文字幕。
String mediaStreamSearchText(MediaStream stream) {
  final parts = <String?>[
    stream.displayTitle,
    stream.title,
    stream.language,
    stream.codec,
    if (stream.isAudio && stream.channels != null) '${stream.channels}ch',
  ];
  return parts.where((e) => e != null && e.isNotEmpty).join(' ');
}

/// 按版本正则挑选媒体源；正则为空/非法或无命中时返回 null。
MediaSource? matchPreferredMediaSource(
    List<MediaSource> sources, String? regex) {
  final re = compilePreferenceRegex(regex);
  if (re == null) return null;
  for (final s in sources) {
    if (re.hasMatch(mediaSourceSearchText(s))) return s;
  }
  return null;
}

/// 按正则挑选轨道（字幕/音频）；正则为空/非法或无命中时返回 null。
MediaStream? matchPreferredStream(List<MediaStream> streams, String? regex) {
  final re = compilePreferenceRegex(regex);
  if (re == null) return null;
  for (final s in streams) {
    if (re.hasMatch(mediaStreamSearchText(s))) return s;
  }
  return null;
}

/// 音频 codec 优先级（数值越小越优先）。
///
/// [preferQuality] = true（mpv 系内核，软解任意格式）：**音质优先**——
/// 无损/高清（TrueHD、DTS-HD MA、DTS-HD、DTS）排前，压缩格式靠后；
/// = false（ExoPlayer 内核）：**兼容优先**——手机 MediaCodec 通常没有
/// DTS/TrueHD 解码器，Media3 内置软解（AAC/Opus/Vorbis/MP3/FLAC/PCM）必可
/// 播排前，设备硬解（AC3/EAC3/WMA）次之，基本不可解的 DTS 系排最后
/// （仅当整片没有任何可解音轨时才轮到它，配合自动切内核兜底）。
///
/// 注意：具体格式必须排在泛格式之前（contains 匹配），如
/// `dts-hd ma` → `dts-hd` → `dts`。
int audioCodecRank(String? codec, {required bool preferQuality}) {
  final c = (codec ?? '').trim().toLowerCase();
  const qualityOrder = <String>[
    'truehd', 'dts-hd ma', 'dts-hd master audio', 'dts-hd', 'dts',
    'eac3', 'ac3', 'flac', 'opus', 'vorbis', 'aac', 'mp3', 'pcm', 'wma',
  ];
  const compatOrder = <String>[
    'aac', 'opus', 'vorbis', 'mp3', 'flac', 'pcm',
    'ac3', 'eac3', 'wma',
    'dts', 'truehd', 'dts-hd',
  ];
  final order = preferQuality ? qualityOrder : compatOrder;
  for (var i = 0; i < order.length; i++) {
    if (c.contains(order[i])) return i;
  }
  return order.length;
}

/// 提取任意音频轨道结构里的 codec 名：兼容详情页 audios Map
/// （codec_name/codec/Codec）、unifiedResource.audios（codec_name）与
/// [MediaStream]（codec）。取不到返回空串。
String audioCodecOf(Object? track) {
  if (track == null) return '';
  if (track is MediaStream) return track.codec ?? '';
  if (track is Map) {
    for (final key in const ['codec_name', 'codec', 'Codec', 'audio_codec']) {
      final v = track[key]?.toString();
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
  }
  return '';
}

/// 按内核策略对音频轨道排序：返回排序后的索引列表，**第一个即应默认选中**。
/// 同优先级保持原顺序（稳定排序）。
List<int> sortAudioIndexes(
  int count,
  String Function(int index) codecOf, {
  required bool preferQuality,
}) {
  final indexes = List<int>.generate(count, (i) => i);
  indexes.sort((a, b) {
    final ra = audioCodecRank(codecOf(a), preferQuality: preferQuality);
    final rb = audioCodecRank(codecOf(b), preferQuality: preferQuality);
    if (ra != rb) return ra.compareTo(rb);
    return a.compareTo(b);
  });
  return indexes;
}

/// 从条目名提取「标题主干」：反复去掉尾部常见后缀 token
/// （年份 / 分辨率 / 编码 / 来源 / 语言标记，如 `.2023`、`.1080p`、`.x264`、
/// `.WEB-DL`、`.国语`），提高跨服务器检索命中率——飞牛条目名常带这些后缀
/// （如「凡人修仙传.2023.1080p」），而 Emby 搜索要求完整包含匹配，
/// 带后缀的 query 会搜不到干净标题的条目。提取不出主干时原样返回。
String normalizeSearchTitle(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return t;
  var result = t;
  // 后缀 token：点号/空格分隔的常见标记（贪婪匹配到主干，逐个剥离）。
  final suffix = RegExp(
    r'^(.+?)[. ]'
    r'((?:19|20)\d{2}|[248]k|2160p|1080p|720p|480p|x264|x265|h264|h265|hevc|av1|bluray|bdremux|remux|web-?dl|webrip|hdrip|bdrip|dvdrip|国语|粤语|中字|双语|chinese|mandarin)'
    r'([. ]|$)',
    caseSensitive: false,
  );
  while (true) {
    final m = suffix.firstMatch(result);
    if (m == null) break;
    result = m.group(1)!;
  }
  final clean = result.trim();
  return clean.isEmpty ? t : clean;
}
