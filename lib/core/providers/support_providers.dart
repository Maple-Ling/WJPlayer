import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cache_service.dart';
import '../services/ext_domain_service.dart';

final imageCacheExpiryDaysProvider = StateProvider<int>((ref) => 14);
final videoCacheMaxSizeMBProvider = StateProvider<int>((ref) => 1024);

class CacheSizeInfo {
  final int imageBytes;
  final int videoBytes;

  CacheSizeInfo({
    required this.imageBytes,
    required this.videoBytes,
  });

  int get totalBytes => imageBytes + videoBytes;
  String get imageFormatted => CacheService.formatBytes(imageBytes);
  String get videoFormatted => CacheService.formatBytes(videoBytes);
  String get totalFormatted => CacheService.formatBytes(totalBytes);
}

final cacheSizeProvider = FutureProvider<CacheSizeInfo>((ref) async {
  return CacheSizeInfo(
    imageBytes: await CacheService.getImageCacheSize(),
    videoBytes: await CacheService.getVideoCacheSize(),
  );
});

final webdavConfigProvider = StateNotifierProvider<WebdavConfigNotifier, WebdavConfig?>((ref) {
  return WebdavConfigNotifier();
});

class WebdavConfigNotifier extends StateNotifier<WebdavConfig?> {
  WebdavConfigNotifier() : super(null);

  void setConfig(String serverUrl, String username, String password) {
    state = WebdavConfig(
      serverUrl: serverUrl,
      username: username,
      password: password,
    );
  }

  void clearConfig() {
    state = null;
  }
}

class WebdavConfig {
  final String serverUrl;
  final String username;
  final String password;

  WebdavConfig({
    required this.serverUrl,
    required this.username,
    required this.password,
  });
}

final extDomainServiceProvider = Provider<ExtDomainService>((ref) {
  return ExtDomainService();
});
