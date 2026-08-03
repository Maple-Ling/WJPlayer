import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/network/proxy_http_client.dart';

/// 插件市场（仓库 registry.json）中的一个可安装插件条目。
class StorePlugin {
  final String id;
  final String name;
  final String description;
  final String author;
  final List<String> targets;
  final List<String> tags;
  final String? version;
  final String? packageUrl;

  const StorePlugin({
    required this.id,
    required this.name,
    required this.description,
    required this.author,
    required this.targets,
    required this.tags,
    required this.version,
    required this.packageUrl,
  });

  /// 是否适配给定平台（'pc' / 'mobile' / 'tv'）。targets 为空视为通用。
  bool supports(String target) => targets.isEmpty || targets.contains(target);

  factory StorePlugin.fromJson(Map<String, dynamic> json) {
    // 选择可安装版本：优先 stable 渠道，否则取版本列表首个。
    final versions = (json['versions'] as List?) ?? const [];
    Map<String, dynamic>? pick;
    for (final v in versions.whereType<Map>()) {
      final mv = v.cast<String, dynamic>();
      if (mv['channel'] == 'stable') {
        pick = mv;
        break;
      }
      pick ??= mv;
    }
    final author = json['author'];
    return StorePlugin(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? json['id'] ?? '未命名插件'}',
      description: '${json['description'] ?? ''}',
      author: author is Map ? '${author['name'] ?? ''}' : '${author ?? ''}',
      targets: ((json['targets'] as List?) ?? const [])
          .map((e) => '$e')
          .toList(growable: false),
      tags: ((json['tags'] as List?) ?? const [])
          .map((e) => '$e')
          .toList(growable: false),
      version: pick?['version']?.toString(),
      packageUrl: pick?['packageUrl']?.toString(),
    );
  }
}

/// 插件市场客户端：从仓库 registry.json 拉取索引、下载 .ipk 安装包。
///
/// 苹果移动端无法用文件选择器导入 .ipk（系统对未知扩展名无 UTType，
/// UIDocumentPicker 直接拒绝选择），故改走网络安装：列出仓库插件一键装，
/// 或粘贴 packageUrl 直装。三端共用，也顺带优化桌面/TV 的安装体验。
class PluginStore {
  // ponytail: 仓库地址硬编码；出现多仓库/自建源需求时再做成可配置项。
  static const String registryUrl =
      'https://raw.githubusercontent.com/zzzwannasleep/LinPlayerPluginsRepository/main/registry.json';

  /// 拉取并解析仓库索引。
  static Future<List<StorePlugin>> fetchRegistry() async {
    final body = await _getString(registryUrl);
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('registry.json 顶层不是对象');
    }
    final plugins = (json['plugins'] as List?) ?? const [];
    return plugins
        .whereType<Map>()
        .map((e) => StorePlugin.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  /// 下载安装包字节（.ipk）。
  static Future<List<int>> downloadPackage(String url) async {
    final client = createStrictProxiedHttpClient();
    try {
      final resp = await _send(client, url);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _getString(String url) async {
    final client = createStrictProxiedHttpClient();
    try {
      final resp = await _send(client, url);
      return await resp.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  static Future<HttpClientResponse> _send(HttpClient client, String url) async {
    client.connectionTimeout = const Duration(seconds: 15);
    final uri = Uri.parse(url);
    final req = await client.getUrl(uri);
    // UA 由 createStrictProxiedHttpClient 统一设为 kAppUserAgent。
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw HttpException('请求失败（HTTP ${resp.statusCode}）', uri: uri);
    }
    return resp;
  }
}
