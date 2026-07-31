import 'dart:convert';

import 'plugin_context_bridge.dart';

/// data / addon 两种声明式 runtime 共用的小工具：模板插值、JSON 点路径取值、
/// 经宿主 ctx 桥（含 HTTPS + 白名单 + 防重定向）发起 HTTP。
///
/// 关键：HTTP 一律走 [PluginContextBridge.dispatch]('http', ...)，因此声明式插件与
/// JS 插件共享**完全相同**的权限门控和安全校验，不另开出网通道。

/// 点路径取值：`data.limit_bytes`、`items.0.id`。取不到返回 null。
dynamic jsonPath(dynamic obj, String path) {
  dynamic cur = obj;
  for (final seg in path.split('.')) {
    if (cur is Map) {
      cur = cur[seg];
    } else if (cur is List) {
      final i = int.tryParse(seg);
      cur = (i != null && i >= 0 && i < cur.length) ? cur[i] : null;
    } else {
      return null;
    }
    if (cur == null) return null;
  }
  return cur;
}

/// 模板插值：把 `{a.b.c}` 替换为 `vars` 里对应点路径的值（缺失→空串）。
String renderTemplate(String tpl, Map<String, dynamic> vars) {
  return tpl.replaceAllMapped(RegExp(r'\{([a-zA-Z0-9_.]+)\}'), (m) {
    final v = jsonPath(vars, m.group(1)!);
    return v == null ? '' : '$v';
  });
}

/// 递归对 JSON 结构里的字符串做模板插值（用于请求的 json 体 / headers / query）。
dynamic deepRender(dynamic node, Map<String, dynamic> vars) {
  if (node is String) return renderTemplate(node, vars);
  if (node is Map) {
    return node.map((k, v) => MapEntry('$k', deepRender(v, vars)));
  }
  if (node is List) return node.map((e) => deepRender(e, vars)).toList();
  return node;
}

/// 按声明式 `request` 发起 HTTP，返回 `{status, headers, body}` 或 null（失败）。
///
/// request: `{ method, url, headers?, query?, json? }`，各字段已就 [vars] 插值。
Future<Map<String, dynamic>?> declRequest(
    PluginContextBridge bridge, Map request, Map<String, dynamic> vars) async {
  final method = '${request['method'] ?? 'GET'}'.toLowerCase();
  final url = renderTemplate('${request['url'] ?? ''}', vars);
  if (url.isEmpty) return null;

  final opts = <String, dynamic>{};
  if (request['headers'] is Map) {
    opts['headers'] = deepRender(request['headers'], vars);
  }
  if (request['query'] is Map) {
    opts['query'] = deepRender(request['query'], vars);
  }

  final List<dynamic> args;
  if (method == 'post') {
    final body = request.containsKey('json') ? deepRender(request['json'], vars) : null;
    args = [url, body, opts];
  } else {
    args = [url, opts];
  }

  final raw = await bridge.dispatch('http', method, jsonEncode(args));
  final decoded = jsonDecode(raw);
  if (decoded is Map && decoded['ok'] == true && decoded['value'] is Map) {
    return Map<String, dynamic>.from(decoded['value'] as Map);
  }
  // {ok:false} 的错误（权限/白名单/网络）bridge 已记日志，这里安静失败。
  return null;
}

num? _toNum(dynamic v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim());
  return null;
}

/// 声明式指标取值（仍是"配置"，非公式解析器）：
///  - 字符串 → 模板插值（如 `"{limit}"`）；
///  - 对象   → 取一个数再做变换：
///      取数：`var`(变量名) / `subtract:[a,b]` / `add:[a,b]` / `path`(对最后响应体点路径)
///      变换：`divide` / `multiply` / `round`(小数位) / `prefix` / `suffix`
///
/// [vars] 含 cfg./media./serverUrl 及各 step 捕获的变量；[lastBody] 是最后一次请求的响应体。
String resolveValue(dynamic spec, Map<String, dynamic> vars, dynamic lastBody) {
  if (spec is String) return renderTemplate(spec, vars);
  if (spec is! Map) return '';

  num? picked;
  if (spec.containsKey('var')) {
    picked = _toNum(vars['${spec['var']}']);
  } else if (spec['subtract'] is List && (spec['subtract'] as List).length == 2) {
    final a = _toNum(vars['${spec['subtract'][0]}']);
    final b = _toNum(vars['${spec['subtract'][1]}']);
    if (a != null && b != null) picked = a - b;
  } else if (spec['add'] is List && (spec['add'] as List).length == 2) {
    final a = _toNum(vars['${spec['add'][0]}']);
    final b = _toNum(vars['${spec['add'][1]}']);
    if (a != null && b != null) picked = a + b;
  } else if (spec.containsKey('path')) {
    picked = _toNum(jsonPath(lastBody, '${spec['path']}'));
  }
  if (picked == null) return '—';

  num value = picked;
  final divide = spec['divide'];
  if (divide is num && divide != 0) value = value / divide;
  final multiply = spec['multiply'];
  if (multiply is num) value = value * multiply;

  final round = spec['round'];
  var s = round is int ? value.toStringAsFixed(round) : '$value';
  if (spec['prefix'] != null) s = '${spec['prefix']}$s';
  if (spec['suffix'] != null) s = '$s${spec['suffix']}';
  return s;
}

/// 便捷：拿当前 Emby 服务器 url（需 emby.read；无则空串）。data 的 `{serverUrl}`
/// 与 addon 的 `?serverUrl=` 都用它。
Future<String> currentServerUrl(PluginContextBridge bridge) async {
  try {
    final raw = await bridge.dispatch('emby', 'getServerInfo', '[]');
    final decoded = jsonDecode(raw);
    if (decoded is Map && decoded['ok'] == true && decoded['value'] is Map) {
      final v = decoded['value'] as Map;
      return '${v['url'] ?? v['baseUrl'] ?? ''}';
    }
  } catch (_) {}
  return '';
}
