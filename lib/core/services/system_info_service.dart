import 'dart:async';
import 'package:flutter/services.dart';

/// 播放器状态栏系统信息：电量 / 网速（原生 MethodChannel）。
class SystemInfoService {
  static const _channel = MethodChannel('com.mapleling.wjplayer/system_info');

  SystemInfoService._();
  static final SystemInfoService instance = SystemInfoService._();

  int _battery = 100;
  double _rxSpeed = 0;
  double _txSpeed = 0;
  Timer? _timer;
  final List<void Function()> _listeners = [];

  int get battery => _battery;
  double get rxSpeed => _rxSpeed;
  double get txSpeed => _txSpeed;

  /// 订阅变化，返回取消订阅函数。
  void Function() addListener(void Function() cb) {
    _listeners.add(cb);
    return () => _listeners.remove(cb);
  }

  void _notify() {
    for (final cb in List.of(_listeners)) {
      cb();
    }
  }

  /// 开始周期刷新（默认 1 秒）。
  void start({Duration interval = const Duration(seconds: 1)}) {
    _timer ??= Timer.periodic(interval, (_) => _refresh());
    _refresh();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _refresh() async {
    try {
      final battery = await _channel.invokeMethod<int>('getBattery');
      if (battery != null) _battery = battery;
    } catch (_) {}
    try {
      final speeds = await _channel
          .invokeMethod<List<dynamic>>('getTrafficBytes');
      if (speeds != null && speeds.length >= 2) {
        _rxSpeed = (speeds[0] as num?)?.toDouble() ?? 0;
        _txSpeed = (speeds[1] as num?)?.toDouble() ?? 0;
      }
    } catch (_) {}
    _notify();
  }
}
