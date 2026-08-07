import 'package:dio/dio.dart';

import '../network/proxy_http_client.dart';

/// 为文件浏览型源后端创建一个走当前代理 + TLS 白名单的 Dio。
///
/// 网盘接口常以非 2xx 携带 JSON 错误体（如 401 也返回 `{code, message}`），
/// 因此放宽 [validateStatus]，由各后端读响应体自行判断成功/失败。
Dio buildSourceDio({
  String? baseUrl,
  Map<String, dynamic>? headers,
  Duration connectTimeout = const Duration(seconds: 15),
  Duration receiveTimeout = const Duration(seconds: 30),
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl ?? '',
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      headers: headers,
      validateStatus: (status) => status != null && status < 500,
      responseType: ResponseType.json,
      // 关闭 HttpClient 层自动跟随：Dart SDK 对跨源重定向（如 CDN 域名
      // 307 → 内网穿透 ddns:随机端口）会按 RFC 6454 丢弃 Authorization /
      // Cookie 等敏感头，导致穿透链路鉴权失败（直连无重定向所以正常）。
      // 改由下方拦截器手动跟随并显式保留全部请求头。
      followRedirects: false,
    ),
  );
  _attachManualRedirect(dio);
  applyProxyToDio(dio);
  return dio;
}

/// 手动跟随 3xx 重定向：显式保留全部请求头（含 authx/Authorization/Cookie），
/// 307/308 保留方法+body，301/302/303 转 GET（标准行为）。递归跟随天然
/// 支持多跳（CDN → ddns 单跳即止），`redirectHop` 上限防重定向死循环。
void _attachManualRedirect(Dio dio) {
  dio.interceptors.add(InterceptorsWrapper(
    onResponse: (response, handler) async {
      final status = response.statusCode ?? 0;
      if (status < 300 || status >= 400) {
        handler.next(response);
        return;
      }
      final location = response.headers.value('location');
      if (location == null || location.isEmpty) {
        handler.next(response);
        return;
      }
      final hop = (response.requestOptions.extra['redirectHop'] as int?) ?? 0;
      if (hop >= 5) {
        handler.next(response);
        return;
      }
      final req = response.requestOptions;
      final isBodyPreserved = status == 307 || status == 308;
      try {
        final next = await dio.requestUri(
          Uri.parse(location),
          data: isBodyPreserved ? req.data : null,
          options: Options(
            method: isBodyPreserved ? req.method : 'GET',
            // 完整保留原始请求头（Dart 自动跟随会丢 Authorization/Cookie）。
            headers: Map<String, dynamic>.from(req.headers),
            responseType: req.responseType,
            validateStatus: req.validateStatus,
            extra: {...req.extra, 'redirectHop': hop + 1},
          ),
        );
        handler.resolve(next);
      } catch (_) {
        // 重定向目标请求失败：把原始 3xx 交还上层处理（Dio 视为最终响应）。
        handler.next(response);
      }
    },
  ));
}

/// 规整 baseUrl：去尾斜杠、补协议（缺省 https）。
String normalizeBaseUrl(String raw) {
  var url = raw.trim();
  if (url.isEmpty) return url;
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    url = 'https://$url';
  }
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}
