import 'package:dio/dio.dart';

import 'sync/sync_config.dart';
import 'sync/sync_models.dart' show kSyncUserAgent;
import 'app_logger.dart';

/// 爱发电赞助页地址（解锁对话框里展示给用户去赞助）。
const String kAfdianSponsorUrl = 'https://afdian.com/a/zzzwannasleep';

/// 爱发电订单校验结果。
class AfdianVerifyResult {
  final bool valid;
  final String planTitle;
  final String amount;
  final String? reason;

  const AfdianVerifyResult({
    required this.valid,
    this.planTitle = '',
    this.amount = '',
    this.reason,
  });
}

/// 爱发电付费校验：把订单号发给自建代理（代理持 token 调 query-order），
/// 客户端不接触 afdian token。
///
/// ponytail: 这是软锁——开源客户端里「已解锁」的判断随时可被改；校验只是
///           抬高门槛 + 走个仪式，别指望它防破解（详见设置页说明）。
class AfdianService {
  static final _logger = AppLogger();

  final Dio _dio;

  AfdianService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              headers: {'User-Agent': kSyncUserAgent},
              validateStatus: (_) => true,
            ));

  /// 校验订单号。网络/服务异常时返回 valid:false + reason。
  Future<AfdianVerifyResult> verifyOrder(String orderNo) async {
    final trimmed = orderNo.trim();
    if (trimmed.isEmpty) {
      return const AfdianVerifyResult(valid: false, reason: '请输入订单号');
    }
    if (!kUseSyncProxy) {
      return const AfdianVerifyResult(valid: false, reason: '未配置校验服务');
    }
    try {
      final resp = await _dio.post(
        '$kSyncProxyBaseUrl/afdian/verify',
        data: {'out_trade_no': trimmed},
        options: Options(headers: {
          ...syncProxyHeaders(),
          'Content-Type': 'application/json',
        }),
      );
      final data = resp.data;
      if (data is! Map) {
        return AfdianVerifyResult(
            valid: false, reason: '服务返回异常：HTTP ${resp.statusCode}');
      }
      return AfdianVerifyResult(
        valid: data['valid'] == true,
        planTitle: data['planTitle']?.toString() ?? '',
        amount: data['amount']?.toString() ?? '',
        reason: data['reason']?.toString(),
      );
    } catch (e) {
      _logger.w('Afdian', '订单校验异常: $e');
      return AfdianVerifyResult(valid: false, reason: '网络错误：$e');
    }
  }
}
