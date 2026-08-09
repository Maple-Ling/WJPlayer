import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'playback_providers.dart';

class PlaybackPrefs {
  PlaybackPrefs({
    this.playerCore,
    this.audioIndex = -1,
    this.subtitleIndex,
    this.lineIndex = 0,
  });

  final String? playerCore;
  final int audioIndex;

  /// 用户手动选择的字幕：null = 未手动选过（播放器按正则/语言自动猜测）、
  /// -1 = 显式关闭、>=0 = 选中的字幕索引
  /// （Emby 播放链 = MediaStream.index；飞牛/直链 = 字幕列表索引）。
  final int? subtitleIndex;
  final int lineIndex;

  Map<String, dynamic> toJson() => {
        if (playerCore != null) 'playerCore': playerCore,
        'audioIndex': audioIndex,
        if (subtitleIndex != null) 'subtitleIndex': subtitleIndex,
        'lineIndex': lineIndex,
        'v': 2,
      };

  static PlaybackPrefs fromJson(Map<String, dynamic> json) {
    final v = json['v'] as int?;
    // v<2 的旧记录 subtitleIndex 恒为占位默认 -1（非用户选择），归一为 null
    // 避免把「从未手动选过」误判成「显式关闭字幕」。
    final rawSubtitle =
        v != null && v >= 2 ? json['subtitleIndex'] as int? : null;
    return PlaybackPrefs(
      playerCore: json['playerCore'] as String?,
      audioIndex: json['audioIndex'] as int? ?? -1,
      subtitleIndex: rawSubtitle,
      lineIndex: json['lineIndex'] as int? ?? 0,
    );
  }
}

class PlaybackPrefsStore {
  PlaybackPrefsStore._();
  static final PlaybackPrefsStore instance = PlaybackPrefsStore._();

  Future<PlaybackPrefs> read(String itemId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('playback_prefs_$itemId');
    if (raw == null) return PlaybackPrefs();
    try {
      return PlaybackPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Exception {
      return PlaybackPrefs();
    }
  }

  Future<String?> readPlayerCore(String itemId) async {
    final value = (await read(itemId)).playerCore;
    return value == null || value.isEmpty ? null : normalizePlayerCore(value);
  }

  Future<void> write(String itemId, PlaybackPrefs prefs) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('playback_prefs_$itemId', jsonEncode(prefs.toJson()));
  }

  Future<void> writePlayerCore(String itemId, String core) async {
    final current = await read(itemId);
    await write(itemId, PlaybackPrefs(
      playerCore: normalizePlayerCore(core),
      audioIndex: current.audioIndex,
      subtitleIndex: current.subtitleIndex,
      lineIndex: current.lineIndex,
    ));
  }

  /// 写入用户手动选择的字幕：null = 清除记录（恢复自动猜测）、
  /// -1 = 显式关闭、>=0 = 选中的字幕索引。保留内核等其它字段。
  Future<void> writeSubtitleIndex(String itemId, int? index) async {
    final current = await read(itemId);
    await write(itemId, PlaybackPrefs(
      playerCore: current.playerCore,
      audioIndex: current.audioIndex,
      subtitleIndex: index,
      lineIndex: current.lineIndex,
    ));
  }

  Future<void> remove(String itemId) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove('playback_prefs_$itemId');
  }
}
