import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'playback_providers.dart';

class PlaybackPrefs {
  PlaybackPrefs({
    this.playerCore,
    this.audioIndex = -1,
    this.subtitleIndex = -1,
    this.lineIndex = 0,
  });

  final String? playerCore;
  final int audioIndex;
  final int subtitleIndex;
  final int lineIndex;

  Map<String, dynamic> toJson() => {
        if (playerCore != null) 'playerCore': playerCore,
        'audioIndex': audioIndex,
        'subtitleIndex': subtitleIndex,
        'lineIndex': lineIndex,
      };

  static PlaybackPrefs fromJson(Map<String, dynamic> json) => PlaybackPrefs(
        playerCore: json['playerCore'] as String?,
        audioIndex: json['audioIndex'] as int? ?? -1,
        subtitleIndex: json['subtitleIndex'] as int? ?? -1,
        lineIndex: json['lineIndex'] as int? ?? 0,
      );
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

  Future<void> remove(String itemId) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove('playback_prefs_$itemId');
  }
}
