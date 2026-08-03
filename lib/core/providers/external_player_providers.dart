import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/external_player/external_player_session_service.dart';
import 'playback_providers.dart';
import 'server_providers.dart';
import 'watch_history_providers.dart';

final externalPlayerSessionServiceProvider =
    Provider<ExternalPlayerSessionService>((ref) {
  final service = ExternalPlayerSessionService(
    watchHistory: ref.watch(watchHistoryProvider),
    apiReader: () => ref.read(apiClientProvider),
    scopeKeyReader: () =>
        buildWatchHistoryScopeKey(ref.read(currentServerProvider)),
    watchedThresholdReader: () => ref.read(watchedThresholdProvider),
  );
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});
