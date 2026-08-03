enum SubtitleKind {
  text,
  ass,
  bitmap,
}

class SubtitleTrackMatcher {
  static SubtitleKind classifyKind({
    String? codec,
    String? title,
    bool isBitmap = false,
    bool isAss = false,
    String? expectedCodec,
    String? expectedTitle,
  }) {
    if (isBitmap || isGraphicalSubtitleCodec(codec)) {
      return SubtitleKind.bitmap;
    }
    if (isAss || isAssSubtitleCodec(codec)) {
      return SubtitleKind.ass;
    }
    if (isGraphicalSubtitleCodec(expectedCodec)) {
      return SubtitleKind.bitmap;
    }
    if (isAssSubtitleCodec(expectedCodec)) {
      return SubtitleKind.ass;
    }

    final lowerTitle = (title ?? '').toLowerCase();
    if (_looksLikeGraphicalSubtitleTitle(lowerTitle)) {
      return SubtitleKind.bitmap;
    }
    if (lowerTitle.contains('ass') || lowerTitle.contains('ssa')) {
      return SubtitleKind.ass;
    }

    final lowerExpectedTitle = (expectedTitle ?? '').toLowerCase();
    if (_looksLikeGraphicalSubtitleTitle(lowerExpectedTitle)) {
      return SubtitleKind.bitmap;
    }
    if (lowerExpectedTitle.contains('ass') || lowerExpectedTitle.contains('ssa')) {
      return SubtitleKind.ass;
    }

    return SubtitleKind.text;
  }

  static bool isAssSubtitleCodec(String? codec) {
    final lower = _normalizeCodec(codec);
    if (lower.isEmpty) {
      return false;
    }
    return lower == 'ass' || lower == 'ssa' || lower.contains('substation');
  }

  static bool isGraphicalSubtitleCodec(String? codec) {
    final lower = _normalizeCodec(codec);
    if (lower.isEmpty) {
      return false;
    }
    return lower == 'pgssub' ||
        lower == 'sup' ||
        lower == 'pgs' ||
        lower == 'dvdsub' ||
        lower == 'dvd_subtitle' ||
        lower == 'vobsub' ||
        lower == 'dvbsub' ||
        lower.contains('hdmv') ||
        lower.contains('pgs') ||
        lower.endsWith('_sup');
  }

  static int? extractEmbySubtitleIndex(String? trackId) {
    if (trackId == null || trackId.isEmpty) {
      return null;
    }
    final parts = trackId.split('_');
    if (parts.length != 2) {
      return null;
    }
    return int.tryParse(parts.first);
  }

  static String? matchTrackId({
    required List<Map<String, dynamic>> subtitleTracks,
    required SubtitleKind targetKind,
    required int targetStreamIndex,
    required int typedStreamPosition,
    String? targetLang,
    String? targetTitle,
    required bool Function(String expected, String actual) titlesMatch,
  }) {
    final realTracks = subtitleTracks
        .where((track) => track['id'] != 'auto' && track['id'] != 'no')
        .toList();
    if (realTracks.isEmpty) {
      return null;
    }

    final candidates = _filterCandidates(realTracks, targetKind);
    var working = candidates.isEmpty ? realTracks : candidates;
    final directIndexMatches = working
        .where((track) => extractEmbySubtitleIndex(track['id']?.toString()) == targetStreamIndex)
        .toList();
    if (directIndexMatches.isNotEmpty) {
      working = directIndexMatches;
    }

    final titleMatch = _findTitleMatch(
      working,
      targetTitle: targetTitle,
      titlesMatch: titlesMatch,
    );
    if (titleMatch != null) {
      return titleMatch;
    }

    final normalizedTargetLang = (targetLang ?? '').trim().toLowerCase();
    if (normalizedTargetLang.isNotEmpty) {
      final langMatches = working.where((track) {
        final language = (track['language'] ?? '').toString().trim().toLowerCase();
        return language == normalizedTargetLang || language == 'chi' || language == 'zh';
      }).toList();

      if (langMatches.length == 1) {
        return langMatches.first['id']?.toString();
      }
      if (langMatches.length > 1) {
        final langTitleMatch = _findTitleMatch(
          langMatches,
          targetTitle: targetTitle,
          titlesMatch: titlesMatch,
        );
        if (langTitleMatch != null) {
          return langTitleMatch;
        }
        if (typedStreamPosition >= 0 && typedStreamPosition < langMatches.length) {
          return langMatches[typedStreamPosition]['id']?.toString();
        }
        working = langMatches;
      }
    }

    if (typedStreamPosition >= 0 && typedStreamPosition < working.length) {
      return working[typedStreamPosition]['id']?.toString();
    }

    return working.first['id']?.toString();
  }

  static List<Map<String, dynamic>> _filterCandidates(
    List<Map<String, dynamic>> tracks,
    SubtitleKind targetKind,
  ) {
    return tracks.where((track) {
      final trackKind = classifyKind(
        codec: track['codec']?.toString(),
        title: track['title']?.toString(),
        isBitmap: track['isBitmap'] == true || track['type'] == 'bitmap',
        isAss: track['isAss'] == true,
      );

      if (targetKind == SubtitleKind.bitmap) {
        return trackKind == SubtitleKind.bitmap;
      }

      return trackKind != SubtitleKind.bitmap;
    }).toList();
  }

  static String? _findTitleMatch(
    List<Map<String, dynamic>> tracks, {
    required String? targetTitle,
    required bool Function(String expected, String actual) titlesMatch,
  }) {
    if (targetTitle == null || targetTitle.isEmpty) {
      return null;
    }

    for (final track in tracks) {
      final title = (track['title'] ?? '').toString();
      if (title.isNotEmpty && titlesMatch(targetTitle, title)) {
        return track['id']?.toString();
      }
    }
    return null;
  }

  static String _normalizeCodec(String? codec) {
    return (codec ?? '').trim().toLowerCase();
  }

  static bool _looksLikeGraphicalSubtitleTitle(String title) {
    if (title.isEmpty) {
      return false;
    }
    return title.contains('pgs') ||
        title.contains('sup') ||
        title.contains('hdmv') ||
        title.contains('vobsub') ||
        title.contains('dvdsub') ||
        title.contains('dvd sub') ||
        title.contains('dvd subtitle') ||
        title.contains('dvbsub');
  }
}
