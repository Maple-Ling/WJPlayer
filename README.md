# WJPlayer（无界影视）

[![Android ARM64](https://github.com/Maple-Ling/WJPlayer/actions/workflows/android.yml/badge.svg)](https://github.com/Maple-Ling/WJPlayer/actions/workflows/android.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

**WJPlayer** 是“无界影视”的代码品牌，是一个仅面向 **64 位 ARM Android 手机**的 Flutter Emby 第三方客户端。

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

推送 `v*` Tag 会在构建通过后创建 GitHub Release，并上传：

- ARM64 APK
- SHA-256 校验文件

## 隐私

此二创版本默认不连接上游 Sentry，不发送第三方遥测。崩溃信息仅保存在本地日志和 Android 系统退出诊断中。

## 内容声明

WJPlayer 仅是媒体服务器客户端/播放器，不提供、不存储、不托管和不分发影视资源。用户应仅连接其合法拥有或获授权使用的媒体服务。

## 来源与许可

本项目基于 [`zzzwannasleep/LinPlayer`](https://github.com/zzzwannasleep/LinPlayer) 的 Tag `v1.0.0-build557-pre` 二次开发：

- 上游提交：`134becf8793926f828d2c1bd417f3c0b9068abcd`
- 修改日期：2026-07-31
- 主要修改：Android 手机端裁剪、ARM64-only、品牌迁移、图标替换、独立 CI/CD、遥测隔离

项目继续遵循 [GNU Affero General Public License v3.0](LICENSE)。详细来源记录见 [NOTICE.md](NOTICE.md)。
