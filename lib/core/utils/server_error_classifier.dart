/// 服务器错误统一分类器（Emby/飞牛/聚合源共用）。
///
/// 目标：把分散在登录/搜索/播放/连接检测里的原始异常（DioException 原文、
/// 飞牛业务码、HandshakeException 等）统一归类成**可读、可归因**的中文文案，
/// 并明确区分两类"不兼容"：
/// - 「服务器不支持此客户端」：服务端拒绝/不支持本播放器（协议拦截、UA/客户端
///   名校验、版本过旧等）——问题在服务器侧对该客户端的策略。
/// - 「服务器不兼容（非标准 Emby）」：服务端不是标准 Emby 或协议不完整
///   （Jellyfin 部分版本、飞牛、精简服务端等），缺少播放器依赖的端点/字段。
///
/// 永远不回显原始错误串（可能含播放地址/api_key 等敏感信息）。
library;

import 'package:dio/dio.dart';

/// 错误归因类别。
enum ServerErrorKind {
  /// 无法连接：DNS 解析失败 / 网络不可达 / 连接被拒 / 超时。
  cannotConnect,

  /// TLS/SNI 握手被中断（证书不受信任 / 线路被重置）。
  tlsHandshakeFailed,

  /// 认证失败：用户名/密码错误、Token 失效。
  authFailed,

  /// 访问被拒绝（无权限，但连接与认证本身通过）。
  forbidden,

  /// 服务器不支持此客户端（服务端明确拒绝本客户端 / 客户端版本不受支持）。
  serverRejectsClient,

  /// 服务器不兼容（非标准 Emby/Jellyfin 精简版/飞牛等，缺端点或字段）。
  serverIncompatible,

  /// 资源不存在（URL 路径错误 / 条目已删除）。
  notFound,

  /// 服务器繁忙或内部错误（5xx / 网关）。
  serverError,

  /// 无法识别的其他错误。
  unknown,
}

/// 分类结果：归因类别 + 面向用户的中文文案。
class ServerErrorInfo {
  final ServerErrorKind kind;
  final String message;

  const ServerErrorInfo(this.kind, this.message);
}

/// 将任意服务器相关异常分类为可读文案。
///
/// [context] 描述当前操作（如"登录"、"搜索"、"添加服务器"），用于文案拼接。
ServerErrorInfo classifyServerError(Object? raw, {String context = ''}) {
  final prefix = context.isEmpty ? '' : '$context';

  // ---- DioException（网络/HTTP 层） ----
  if (raw is DioException) {
    final status = raw.response?.statusCode;
    final type = raw.type;
    final msg = (raw.message ?? '').toLowerCase();
    final inner = raw.error;

    // 超时：连接/接收/发送。
    if (type == DioExceptionType.connectionTimeout ||
        type == DioExceptionType.receiveTimeout ||
        type == DioExceptionType.sendTimeout) {
      return ServerErrorInfo(
        ServerErrorKind.cannotConnect,
        '$prefix服务器无法连接（连接超时）。请检查服务器地址、端口与当前网络；'
            '若服务器在海外，建议开启代理或换优选线路。',
      );
    }

    // TLS 握手失败：证书或 SNI 问题。
    final isTls = inner is Exception &&
            inner.toString().toLowerCase().contains('handshake') ||
        msg.contains('handshake') ||
        msg.contains('certificate') ||
        msg.contains('ssl');
    if (type == DioExceptionType.connectionError || type == DioExceptionType.unknown) {
      if (isTls) {
        return ServerErrorInfo(
          ServerErrorKind.tlsHandshakeFailed,
          '${prefix}TLS 握手失败（服务器证书过期/不受信任，或线路被中断）。'
              '可尝试：① 开启该服务器的「允许不安全 TLS」② 换线路/优选域名',
        );
      }
      if (msg.contains('connection refused')) {
        return ServerErrorInfo(
          ServerErrorKind.cannotConnect,
          '$prefix服务器拒绝连接。请确认服务器地址和端口正确（Emby 默认 8096，'
              '反代默认 443），且未开启防火墙拦截。',
        );
      }
      if (msg.contains('failed host lookup') ||
          msg.contains('no address associated with hostname') ||
          msg.contains('name or service not known') ||
          msg.contains('errno = 7')) {
        return ServerErrorInfo(
          ServerErrorKind.cannotConnect,
          '$prefix无法解析服务器地址：域名可能拼写错误，或当前网络无法解析该域名。',
        );
      }
      if (msg.contains('connection terminated') ||
          msg.contains('connection closed') ||
          msg.contains('connection reset')) {
        return ServerErrorInfo(
          ServerErrorKind.cannotConnect,
          '$prefix无法连接到服务器（连接被中断）：服务器可能过载、被限流或线路被'
              '重置。建议换线路/播放源或开启代理后重试。',
        );
      }
    }

    // HTTP 状态码归因。
    if (status != null) {
      switch (status) {
        case 400:
          return ServerErrorInfo(
            ServerErrorKind.serverIncompatible,
            '$prefix服务器返回 400：通常是服务器不是标准 Emby（或路径写错，'
                '如 /emby/emby 重复）。请核对服务器完整地址与路径。',
          );
        case 401:
          return ServerErrorInfo(
            ServerErrorKind.authFailed,
            '$prefix认证失败：用户名或密码错误，或 Token 已过期。请重新登录。',
          );
        case 403:
          final body = raw.response?.data?.toString() ?? '';
          if (body.contains('client') ||
              body.contains('device') ||
              body.contains('unsupported') ||
              body.contains('not support') ||
              body.contains('版本') ||
              body.contains('客户端')) {
            return ServerErrorInfo(
              ServerErrorKind.serverRejectsClient,
              '$prefix服务器不支持此客户端：服务端拒绝了本播放器（客户端标识/版本'
                  '不受支持，或需在服务端开启「允许第三方客户端」）。请到服务器设置'
                  '里检查客户端兼容选项。',
            );
          }
          return ServerErrorInfo(
            ServerErrorKind.forbidden,
            '$prefix访问被拒绝（403）：当前账号无权限访问该资源，或服务器 WAF/'
                '反代拦截了请求。',
          );
        case 404:
          return ServerErrorInfo(
            ServerErrorKind.notFound,
            '$prefix服务器接口不存在（404）：请检查服务器 URL 和路径是否正确'
                '（Emby 需带 /emby 路径，纯反代域名路径可能不同）。',
          );
        case 408:
        case 429:
          return ServerErrorInfo(
            ServerErrorKind.cannotConnect,
            '$prefix服务器繁忙（$status）：请求被限流，请稍后重试或换线路。',
          );
        case 502:
        case 503:
        case 504:
          return ServerErrorInfo(
            ServerErrorKind.serverError,
            '$prefix服务器网关错误（$status）：上游服务器不可用或反代线路故障，'
                '请稍后重试，或检查反代配置的 target。',
          );
      }
      if (status >= 500) {
        return ServerErrorInfo(
          ServerErrorKind.serverError,
          '$prefix服务器内部错误（HTTP $status）：请稍后重试；若持续出现，'
              '可能需联系服务器管理员。',
        );
      }
    }

    // 无状态码的 Dio 异常（连接错误等）。
    return ServerErrorInfo(
      ServerErrorKind.cannotConnect,
      '$prefix无法连接到服务器（${_dioTypeLabel(type)}）。请检查网络后重试。',
    );
  }

  // ----? HandshakeException / 其他异常 ----
  final s = (raw?.toString() ?? '').toLowerCase();
  if (s.contains('handshake') || s.contains('tls') || s.contains('ssl') ||
      s.contains('certificate')) {
    return ServerErrorInfo(
      ServerErrorKind.tlsHandshakeFailed,
      '${prefix}TLS 握手失败：服务器证书不受信任或线路被重置。可尝试开启'
          '「允许不安全 TLS」或更换线路。',
    );
  }
  if (s.contains('failed host lookup') ||
      s.contains('no address associated') ||
      s.contains('name or service not known')) {
    return ServerErrorInfo(
      ServerErrorKind.cannotConnect,
      '$prefix无法解析服务器地址，请检查域名或网络（可能需要代理）。',
    );
  }
  if (s.contains('connection refused')) {
    return ServerErrorInfo(
      ServerErrorKind.cannotConnect,
      '$prefix服务器拒绝连接：端口/地址可能错误，或服务器未运行/防火墙拦截。',
    );
  }
  if (s.contains('timeout') || s.contains('timed out')) {
    return ServerErrorInfo(
      ServerErrorKind.cannotConnect,
      '$prefix连接/响应超时：服务器过慢或网络不通，请换线路或增加超时时间。',
    );
  }
  if (s.contains('401') || s.contains('unauthorized')) {
    return ServerErrorInfo(
      ServerErrorKind.authFailed,
      '$prefix认证失败：请重新登录服务器。',
    );
  }
  if (s.contains('403') || s.contains('forbidden')) {
    return ServerErrorInfo(
      ServerErrorKind.forbidden,
      '$prefix访问被拒绝（403）：账号无权限或服务器 WAF 拦截。',
    );
  }
  if (s.contains('404') || s.contains('not found')) {
    return ServerErrorInfo(
      ServerErrorKind.notFound,
      '$prefix服务器接口不存在（404）：请检查服务器地址/路径，或服务器非标准 Emby。',
    );
  }
  // 飞牛/自建服务的业务错误码。
  if (s.contains('code=-5') || s.contains('permission error')) {
    return ServerErrorInfo(
      ServerErrorKind.forbidden,
      '$prefix服务器返回无权限（code=-5 Permission Error）：账号无权访问该'
        '资源，或登录凭据已失效。请重新登录/授权后重试。',
    );
  }
  if (s.contains('code=5000') || s.contains('invalid sign')) {
    return ServerErrorInfo(
      ServerErrorKind.serverIncompatible,
      '$prefix服务器签名校验失败（invalid sign）：该服务端对请求签名有额外要求'
        '（或反代修改了请求头/时间戳）。请确认服务器为受支持的 Emby 服务端，'
        '或检查反代是否透传原始请求。',
    );
  }
  if (s.contains('5000')) {
    return ServerErrorInfo(
      ServerErrorKind.serverIncompatible,
      '$prefix服务器返回未知业务错误码（code=5000）：服务器兼容性异常，'
        '请确认服务端为受支持版本。',
    );
  }
  if (s.contains(' 500') || s.contains(' 502') || s.contains(' 503') ||
      s.contains(' 504') || s.contains('internal server')) {
    return ServerErrorInfo(
      ServerErrorKind.serverError,
      '$prefix服务器繁忙或内部错误，请稍后重试。',
    );
  }

  return ServerErrorInfo(
    ServerErrorKind.unknown,
    '$prefix服务器返回异常。若反复出现，请导出日志反馈（含服务器类型/版本）。',
  );
}

String _dioTypeLabel(DioExceptionType type) {
  switch (type) {
    case DioExceptionType.connectionTimeout:
      return '连接超时';
    case DioExceptionType.sendTimeout:
      return '发送超时';
    case DioExceptionType.receiveTimeout:
      return '接收超时';
    case DioExceptionType.badCertificate:
      return '证书错误';
    case DioExceptionType.connectionError:
      return '连接错误';
    case DioExceptionType.badResponse:
      return '响应错误';
    case DioExceptionType.cancel:
      return '已取消';
    default:
      return '未知错误';
  }
}