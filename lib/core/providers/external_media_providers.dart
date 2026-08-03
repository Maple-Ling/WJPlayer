import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/discover/discover_models.dart';
import '../api/discover/external_media_models.dart';
import '../api/discover/external_media_service.dart';

final externalMediaServiceProvider = Provider<ExternalMediaService>((ref) => ExternalMediaService());

final externalMediaDetailProvider = FutureProvider.autoDispose
    .family<ExternalMediaDetail, DiscoverEntry>((ref, entry) async {
  return ref.watch(externalMediaServiceProvider).detail(entry);
});

final externalSeasonProvider = FutureProvider.autoDispose
    .family<ExternalSeason, ({int tmdbId, int season})>((ref, args) async {
  return ref.watch(externalMediaServiceProvider).season(args.tmdbId, args.season);
});

final externalPersonCreditsProvider = FutureProvider.autoDispose
    .family<List<DiscoverEntry>, ExternalPerson>((ref, person) async {
  return ref.watch(externalMediaServiceProvider).personCredits(person);
});
