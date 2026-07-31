import '../../providers/app_preferences.dart';

/// 同步后端代理配置（可选）。
///
/// 部署 `oauth-proxy/`（Cloudflare Pages）后，把它的地址填到 [kSyncProxyBaseUrl]，
/// 客户端将通过代理完成所有需要 client_secret 的令牌交换/刷新——secret 只存在
/// 代理的环境变量里，不再出现在客户端二进制中。
///
/// 留空（默认）则回退到客户端内置（混淆）凭据的直连模式，无需部署即可使用。
///
/// 注意：client_id / app_id 属于「公开标识符」，留在客户端是安全的；
/// 真正必须保护的是 secret，代理只负责注入它。
const String kSyncProxyBaseUrl = 'https://291277.xyz/api';

/// 可选共享密钥，需与代理环境变量 LINPLAYER_PROXY_KEY 一致。留空则不发送。
const String kSyncProxyKey = 'm4cfEohhuz4u142d3w';

bool get kUseSyncProxy => kSyncProxyBaseUrl.isNotEmpty;

/// 代理请求要附带的头（共享密钥）。
Map<String, String> syncProxyHeaders() =>
    kSyncProxyKey.isEmpty ? const {} : {'X-WJPlayer-Key': kSyncProxyKey};

// ============ Bangumi API 国内加速反代 ============
//
// 官方 api.bgm.tv / lain.bgm.tv 在国内经常慢或不通。anibt 提供了完整的 API + 图片
// 反代（bgmapi 透传 /v0、/calendar、/search 及 Authorization；返回 JSON 里的封面
// URL 已改写成图片反代 bgmimg，因此只切 API 基址即可，图片自动跟随）。
// OAuth 授权仍走官方 bgm.tv（授权码经用户浏览器 + CF oauth-proxy 换取），不受影响。

const String kBangumiApiOfficial = 'https://api.bgm.tv';
const String kBangumiApiMirror = 'https://bgmapi.anibt.net';
const String kBangumiOAuthOfficial = 'https://bgm.tv';

/// 开关持久化键（与 bangumiMirrorProvider 共用）。
const String kBangumiMirrorPrefKey = 'wjplayer_bangumi_mirror';

/// 反代开关是否打开（默认开）。prefs 未初始化时兜底为开。
bool get _bangumiUseMirror {
  try {
    return AppPreferencesStore.instance.getBool(kBangumiMirrorPrefKey) ?? true;
  } catch (_) {
    return true;
  }
}

/// 当前生效的 Bangumi API 基址：开=反代（默认），关=官方。
/// 从 SharedPreferences 同步读取，服务层每次请求都取最新值。
String get bangumiApiBase =>
    _bangumiUseMirror ? kBangumiApiMirror : kBangumiApiOfficial;

/// OAuth 授权页基址：开=反代（浏览器登录也免梯子），关=官方 bgm.tv。
/// 仅用于授权页 URL（浏览器打开、不含 client_secret）；code 换 token 仍走 CF
/// oauth-proxy 注入 secret，不会把 secret 发给第三方反代。
String get bangumiAuthorizeBase =>
    _bangumiUseMirror ? kBangumiApiMirror : kBangumiOAuthOfficial;
