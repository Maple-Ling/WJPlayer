import 'plugin_extension_point.dart';
import 'plugin_permission.dart';

/// manifest.json 解析失败时抛出。
class PluginManifestError implements Exception {
  final String message;
  PluginManifestError(this.message);
  @override
  String toString() => 'PluginManifestError: $message';
}

/// manifest 中 `extends` 的一条静态扩展声明。
class ManifestExtensionDecl {
  final PluginExtensionType type;
  final Map<String, dynamic> data;
  ManifestExtensionDecl(this.type, this.data);
}

/// 插件清单 —— 对应 manifest.json。
///
/// 必填字段：id, version, name。
/// 规范字段：author, description, permissions[], extends{}。
class PluginManifest {
  /// 反向域名唯一 id，例如 `com.example.telegram-notify`。
  final String id;

  /// 语义化版本，例如 `1.0.0`。
  final String version;

  final String name;
  final String author;
  final String description;

  /// 入口 JS 文件名（相对插件目录），默认 `main.js`。
  final String main;

  /// 运行时形态：`js`（默认，QuickJS 执行 main.js）/ `data`（声明式）/ `addon`（远程服务）。
  /// data/addon 无 main.js，供 iOS App Store 合规使用。
  final String runtime;

  /// 申请的权限 id 列表。
  final List<String> permissions;

  /// 静态声明的扩展点。
  final List<ManifestExtensionDecl> extensions;

  /// 可选：图标文件名（相对插件目录的 assets）。
  final String? icon;

  /// 可选：主页 / 仓库地址。
  final String? homepage;

  /// 可选：要求的最低应用版本。
  final String? minAppVersion;

  /// 原始 JSON（用于备份/展示）。
  final Map<String, dynamic> raw;

  PluginManifest({
    required this.id,
    required this.version,
    required this.name,
    required this.author,
    required this.description,
    required this.main,
    this.runtime = 'js',
    required this.permissions,
    required this.extensions,
    this.icon,
    this.homepage,
    this.minAppVersion,
    required this.raw,
  });

  /// 反向域名格式校验：至少包含一个点，仅允许字母数字、点、连字符、下划线。
  static final RegExp _idPattern = RegExp(r'^[a-zA-Z0-9_-]+(\.[a-zA-Z0-9_-]+)+$');

  /// 语义化版本校验（宽松：major.minor.patch，允许预发布后缀）。
  static final RegExp _versionPattern =
      RegExp(r'^\d+\.\d+\.\d+([-+].+)?$');

  /// 从已解析的 JSON Map 构造，并做严格校验。
  factory PluginManifest.fromJson(Map<String, dynamic> json) {
    String requireString(String field) {
      final v = json[field];
      if (v is! String || v.trim().isEmpty) {
        throw PluginManifestError('缺少或非法字段: $field');
      }
      return v.trim();
    }

    final id = requireString('id');
    if (!_idPattern.hasMatch(id)) {
      throw PluginManifestError('id 必须为反向域名格式（如 com.example.foo），当前: $id');
    }

    final version = requireString('version');
    if (!_versionPattern.hasMatch(version)) {
      throw PluginManifestError('version 必须为语义化版本（如 1.0.0），当前: $version');
    }

    final name = requireString('name');
    final author = (json['author'] as String?)?.trim() ?? '未知作者';
    final description = (json['description'] as String?)?.trim() ?? '';
    final main = (json['main'] as String?)?.trim();
    final runtime = (json['runtime'] as String?)?.trim();
    if (runtime != null && !const {'js', 'data', 'addon'}.contains(runtime)) {
      throw PluginManifestError('未知 runtime: $runtime（应为 js/data/addon）');
    }

    // 权限：必须是字符串数组，且只能是已知权限。
    final permsRaw = json['permissions'];
    final permissions = <String>[];
    if (permsRaw != null) {
      if (permsRaw is! List) {
        throw PluginManifestError('permissions 必须是数组');
      }
      for (final p in permsRaw) {
        if (p is! String) {
          throw PluginManifestError('permissions 数组元素必须是字符串');
        }
        if (!PluginPermissions.isKnown(p)) {
          throw PluginManifestError('未知权限: $p');
        }
        if (!permissions.contains(p)) permissions.add(p);
      }
    }

    // extends：可选，{ extensionType: [descriptor, ...] } 或 { type: descriptor }
    final extensions = <ManifestExtensionDecl>[];
    final extendsRaw = json['extends'];
    if (extendsRaw != null) {
      if (extendsRaw is! Map) {
        throw PluginManifestError('extends 必须是对象');
      }
      extendsRaw.forEach((key, value) {
        final type = PluginExtensionType.fromId(key.toString());
        if (type == null) {
          throw PluginManifestError('未知扩展点类型: $key');
        }
        final items = value is List ? value : [value];
        for (final item in items) {
          if (item is! Map) {
            throw PluginManifestError('扩展点 $key 的描述必须是对象');
          }
          extensions.add(
            ManifestExtensionDecl(type, Map<String, dynamic>.from(item)),
          );
        }
      });
    }

    return PluginManifest(
      id: id,
      version: version,
      name: name,
      author: author,
      description: description,
      main: (main == null || main.isEmpty) ? 'main.js' : main,
      runtime: (runtime == null || runtime.isEmpty) ? 'js' : runtime,
      permissions: permissions,
      extensions: extensions,
      icon: (json['icon'] as String?)?.trim(),
      homepage: (json['homepage'] as String?)?.trim(),
      minAppVersion: (json['minAppVersion'] as String?)?.trim(),
      raw: Map<String, dynamic>.from(json),
    );
  }

  /// 将权限解析为可读对象列表（未知的会被忽略）。
  List<PluginPermission> get resolvedPermissions => permissions
      .map(PluginPermissions.byId)
      .whereType<PluginPermission>()
      .toList();
}
