import 'dart:async';

/// 二创版本默认不接入任何第三方遥测服务。
///
/// 保留统一入口，便于后续由仓库所有者显式接入自己的崩溃平台；在此之前，
/// 应用异常仅由本地 [AppLogger] 与 Android 原生退出诊断记录，不向上游发送数据。
class Telemetry {
  Telemetry._();

  static Future<void> runGuarded(FutureOr<void> Function() appRunner) async {
    await Future<void>.sync(appRunner);
  }
}
