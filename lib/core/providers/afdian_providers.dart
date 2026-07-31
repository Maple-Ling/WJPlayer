import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_preferences.dart';
import '../services/afdian_service.dart';

const String _afdianOrderKey = 'wjplayer_afdian_order';

/// 已校验通过的爱发电订单号（空=未解锁）。
///
/// ponytail: 明文存 SharedPreferences，是软锁——能改。付费功能是追剧日历，
///           不值得上加密/防篡改（投入产出比极低），故意保持最简。
final afdianOrderProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '',
    readValue: (prefs) => prefs.getString(_afdianOrderKey),
    writeValue: (prefs, value) async {
      await prefs.setString(_afdianOrderKey, value);
    },
  );
});

/// 付费功能是否已解锁（有已校验订单号即为已解锁）。
final premiumUnlockedProvider = Provider<bool>((ref) {
  return ref.watch(afdianOrderProvider).isNotEmpty;
});

final afdianServiceProvider = Provider<AfdianService>((ref) => AfdianService());
