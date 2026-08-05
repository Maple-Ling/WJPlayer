/// 源类型。
///
/// [emby] 是现有 Emby/Jellyfin 后端的标记（向后兼容：旧数据缺字段时默认它）。
/// [feiniu] 为飞牛影视（NAS）。
///
/// 单独成文件，避免 [ServerConfig]（server_providers.dart）与
/// media_source_backend.dart 之间的循环 import。
enum SourceKind { emby, feiniu }

SourceKind sourceKindFromName(String? name) {
  switch (name) {
    case 'feiniu':
      return SourceKind.feiniu;
    case 'emby':
    default:
      return SourceKind.emby;
  }
}
