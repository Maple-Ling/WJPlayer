# WJPlayer（无界影视）

[![Android ARM64](https://github.com/Maple-Ling/WJPlayer/actions/workflows/android.yml/badge.svg)](https://github.com/Maple-Ling/WJPlayer/actions/workflows/android.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
![Version: 1.0.0](https://img.shields.io/badge/version-1.0.0-blue)

**WJPlayer** 是“无界影视”的代码品牌，一个仅面向 **64 位 ARM Android 手机**的 Flutter 媒体客户端/播放器，兼容 **Emby** 与 **飞牛 fnOS** 双协议，支持跨服务器聚合检索与无缝切换。

##页面截图


![Screenshot-1](https://i.postimg.cc/NFp0xyjX/Screenshot-2026-08-07-17-17-35-07-b38d774aa1bb7770ed6f2d83069c95e3.jpg)
![Screenshot-2](https://i.postimg.cc/QNbVDzJN/Screenshot-2026-08-07-17-17-39-77-b38d774aa1bb7770ed6f2d83069c95e3.jpg)
![Screenshot-3](https://i.postimg.cc/c1m6WzBH/Screenshot-2026-08-07-17-17-50-51-b38d774aa1bb7770ed6f2d83069c95e3.jpg)
![Screenshot-4](https://i.postimg.cc/hvpG0JtM/Screenshot-2026-08-07-17-17-57-32-b38d774aa1bb7770ed6f2d83069c95e3.jpg)
![Screenshot-5](https://i.postimg.cc/6qYQh7pc/Screenshot-2026-08-07-17-18-04-05-b38d774aa1bb7770ed6f2d83069c95e3.jpg)
![Screenshot-6](https://i.postimg.cc/6qYQh7pH/Screenshot-2026-08-07-17-18-24-56-b38d774aa1bb7770ed6f2d83069c95e3.jpg)


## 功能特性

- **双协议支持**：Emby（含隐藏库过滤、媒体源/版本选择）与飞牛 fnOS（顶层剧集/分集、多线路）
- **跨服务器聚合**：详情页/播放器聚合按钮检索所有服务器的同媒体资源，点击即播（保持同集同进度）
- **智能检索**：标题主干规范化 + 多候选兜底，兼容「带后缀/副标题/无集号命名」的服务器差异
- **播放内核**：ExoPlayer / MPV / MPV 原生，按资源自动优选（HDR/DV 自动切 MPV，DTS 自动切内核），内核切换保留字幕/音轨选择
- **音轨策略**：按内核自动选轨（ExoPlayer 兼容优先可解码，MPV 音质优先），详情页/播放器菜单同步
- **弹幕**：多平台来源（B 站 / 腾讯 / 爱奇艺 / 优酷 / 弹弹Play），滚动/顶部/底部/逆向全类型渲染，轨道冻结 + 分区防重叠闪烁
- **观看历史**：跨服务器续播、继续观看、观看记录回传
- **影视聚合**：Discover 多源（TMDB/豆瓣/IMDb）浏览、排行榜、推荐
- **播放体验**：手势亮度/音量/进度（基于系统真实值）、全屏无死角点击、长按倍速、双击快进/暂停、睡眠定时、Anime4K 超分

## 平台边界

本仓库只支持：

- Android 手机
- ABI：`arm64-v8a`
- 最低系统：Android 7.0（API 24）
- Application ID：`com.mapleling.wjplayer`
- 桌面启动器显示名：**无界影视**

本仓库不包含、不构建：Android TV、`armeabi-v7a`、x86/x86_64、Windows、Linux、macOS、iOS、Web、Tauri 或边缘服务。

## 构建

项目使用 Flutter `3.44.2`、Java `17`、Android compileSdk `36`。推荐直接使用 GitHub Actions：

1. 打开 **Actions → Android ARM64**。
2. 选择 **Run workflow**。
3. 构建成功后下载 `WJPlayer-Android-arm64-v8a` Artifact。

标准 x64 Linux 构建机也可执行：

```sh
flutter pub get
flutter build apk \
  --release \
  --target-platform android-arm64
```

Gradle 中固定了 `arm64-v8a` ABI 过滤；CI 还会解包 APK 验证，出现任何其他 ABI 即构建失败。

### 可选 GitHub Actions Secrets

| Secret | 用途 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | 发布签名文件的 Base64 |
| `ANDROID_KEYSTORE_PASSWORD` | KeyStore 密码 |
| `ANDROID_KEY_ALIAS` | Key Alias |
| `ANDROID_KEY_PASSWORD` | Key 密码 |
| `DANDANPLAY_APP_ID` | 弹弹play API ID |
| `DANDANPLAY_APP_SECRET` | 弹弹play API Secret |
| `TMDB_API_KEY` | TMDB API Key |

未配置发布签名时，Gradle 会回退到 debug 签名，仅适合测试安装，不能作为长期覆盖升级签名。

## 发布

推送 `v*` Tag（如 `v1.0.0`）会在构建通过后创建 GitHub Release，并上传：

- ARM64 APK
- SHA-256 校验文件

应用内「检查更新」读取 GitHub 最新 Release；正式版（非 Pre-release）发布后，已安装版本即可检测并升级。

## 隐私

本二创版本默认不连接上游 Sentry，不发送第三方遥测。崩溃信息仅保存在本地日志和 Android 系统退出诊断中。

## 内容声明

WJPlayer 仅是媒体服务器客户端/播放器，不提供、不存储、不托管和不分发影视资源。用户应仅连接其合法拥有或获授权使用的媒体服务。

## 来源与许可

本项目基于 [`zzzwannasleep/LinPlayer`](https://github.com/zzzwannasleep/LinPlayer) 的 Tag `v1.0.0-build557-pre` 二次开发：

- 上游提交：`134becf8793926f828d2c1bd417f3c0b9068abcd`
- 主要修改：Android 手机端裁剪、ARM64-only、品牌迁移、图标替换、独立 CI/CD、遥测隔离、Emby+飞牛双协议、跨服务器聚合播放、多平台弹幕、播放内核与音轨策略等

项目继续遵循 [GNU Affero General Public License v3.0](LICENSE)。详细来源记录见 [NOTICE.md](NOTICE.md)。
