# Source and Modification Notice

WJPlayer is a modified version of the open-source LinPlayer project.

## Upstream

- Project: LinPlayer
- Repository: https://github.com/zzzwannasleep/LinPlayer
- Git reference: `refs/tags/v1.0.0-build557-pre`
- Commit: `134becf8793926f828d2c1bd417f3c0b9068abcd`
- License: GNU Affero General Public License v3.0

## This derivative

- Repository: https://github.com/Maple-Ling/WJPlayer
- Modification date: 2026-07-31
- Maintainer: Maple-Ling

Prominent changes include:

1. Renamed the code brand to WJPlayer and the Android launcher name to “无界影视”.
2. Changed the Dart package to `wjplayer` and Android application ID to `com.mapleling.wjplayer`.
3. Removed Android TV, desktop, Apple, Web/Tauri and edge-service build targets.
4. Restricted Android native packaging and CI artifacts to `arm64-v8a` only.
5. Replaced application artwork and Android launcher icons.
6. Replaced upstream build/release workflows with an Android ARM64-only workflow.
7. Disabled the upstream Sentry telemetry endpoint by default.
8. Improved the Feiniu/fnOS media integration using API behavior documented and implemented by `jimboo7339/fntv_danmu_all` (GPL-3.0): https://github.com/jimboo7339/fntv_danmu_all

The complete corresponding source is distributed under AGPL-3.0. See `LICENSE`.
