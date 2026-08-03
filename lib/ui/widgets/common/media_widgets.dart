import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_identity.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/persistent_image_provider.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../utils/media_helpers.dart';
import 'media_metadata_badges.dart';

/// 判断一个图片地址是否为本地文件（而非网络 URL）。
///
/// 服务器自定义图标允许是本地图片，落盘后以绝对路径 / `file://` 形式存储；
/// Emby 海报、网络图标库等则是 http(s)。为避免把相对网络地址误判为本地文件，
/// 只在以下形态才认定为本地：`file://`、Windows 盘符路径(`C:\` / `C:/`)、
/// 或绝对 Unix 路径(`/...`，即 image_picker/file_picker 返回的绝对路径)。
bool isLocalImagePath(String url) {
  final u = url.trim();
  if (u.isEmpty) return false;
  final lower = u.toLowerCase();
  if (lower.startsWith('file://')) return true;
  // Windows 盘符：C:\... 或 C:/...
  if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(u)) return true;
  // 绝对 Unix 路径（排除以 // 开头的协议相对网络地址）
  if (u.startsWith('/') && !u.startsWith('//')) return true;
  // Windows UNC 路径 \\server\share
  if (u.startsWith(r'\\')) return true;
  return false;
}

class MediaImage extends StatelessWidget {
  final String? imageUrl;
  final List<String>? imageUrls;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final Widget? placeholder;
  final Widget? errorWidget;
  final String? heroTag;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool gaplessPlayback;
  final Alignment alignment;

  /// 用中立浏览器 UA 请求（而非 App 网络协议 UA）。
  /// 服务器图标等第三方 CDN 资源需要，否则可能被拒导致图标损坏。
  final bool useDefaultUserAgent;

  /// 图片请求专用认证头（例如飞牛影视 Authorization/Authx/Cookie）。
  final Map<String, String>? httpHeaders;

  /// 图片解码完成后回调其真实宽高比（width/height）。
  /// 给"按原图比例自适应尺寸"的卡片用，避免裁剪/留白。
  final ValueChanged<double>? onAspectRatio;

  const MediaImage({
    super.key,
    required this.imageUrl,
    this.imageUrls,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.placeholder,
    this.errorWidget,
    this.heroTag,
    this.cacheWidth,
    this.cacheHeight,
    this.gaplessPlayback = true,
    this.alignment = Alignment.center,
    this.useDefaultUserAgent = false,
    this.httpHeaders,
    this.onAspectRatio,
  });

  @override
  Widget build(BuildContext context) {
    final candidates = {
      if (imageUrl != null && imageUrl!.isNotEmpty) imageUrl!,
      ...?imageUrls?.where((url) => url.isNotEmpty),
    }.toList();

    final primary = candidates.isEmpty ? null : candidates.first;

    Widget image;
    if (primary != null && isLocalImagePath(primary)) {
      // 本地图片（服务器自定义图标等）：走 Image.file，网络图片管线不认本地路径。
      image = _buildLocalImage(context, primary);
    } else {
      image = candidates.isEmpty
          ? _buildPlaceholder(context)
          : _FallbackNetworkImage(
              imageUrls: candidates,
              width: width,
              height: height,
              fit: fit,
              alignment: alignment,
              cacheWidth: cacheWidth,
              cacheHeight: cacheHeight,
              gaplessPlayback: gaplessPlayback,
              useDefaultUserAgent: useDefaultUserAgent,
              httpHeaders: httpHeaders,
              onAspectRatio: onAspectRatio,
              placeholderBuilder: () =>
                  placeholder ?? _buildPlaceholder(context),
              errorBuilder: () => errorWidget ?? _buildError(context),
            );
    }

    if (borderRadius != null) {
      image = ClipRRect(
        borderRadius: borderRadius!,
        child: image,
      );
    }

    if (heroTag != null) {
      image = Hero(
        tag: heroTag!,
        child: image,
      );
    }

    return image;
  }

  Widget _buildLocalImage(BuildContext context, String pathOrUri) {
    final path = pathOrUri.startsWith('file://')
        ? Uri.parse(pathOrUri).toFilePath()
        : pathOrUri;
    return Image.file(
      File(path),
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      gaplessPlayback: gaplessPlayback,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      errorBuilder: (_, __, ___) => errorWidget ?? _buildError(context),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(
        child: Icon(Icons.image_outlined, size: 32, color: Colors.grey),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.errorContainer,
      child: const Center(
        child: Icon(Icons.broken_image_outlined, size: 32, color: Colors.grey),
      ),
    );
  }
}

/// 服务器图标取不到时的兜底：默认 Emby 图标。
/// 用作各服务器卡片 MediaImage 的 errorWidget——touchicon 404（如关了 web 的纯 API 服）
/// 也好歹显示个正常图标，而不是碎图占位。父容器已定尺寸，contain 自适应填充。
class EmbyDefaultIcon extends StatelessWidget {
  const EmbyDefaultIcon({super.key});

  static const String asset = 'assets/images/emby_default.png';

  @override
  Widget build(BuildContext context) {
    return Image.asset(asset, fit: BoxFit.contain);
  }
}

class _FallbackNetworkImage extends StatefulWidget {
  final List<String> imageUrls;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool gaplessPlayback;
  final bool useDefaultUserAgent;
  final Map<String, String>? httpHeaders;
  final ValueChanged<double>? onAspectRatio;
  final Widget Function() placeholderBuilder;
  final Widget Function() errorBuilder;

  const _FallbackNetworkImage({
    required this.imageUrls,
    required this.width,
    required this.height,
    required this.fit,
    required this.alignment,
    required this.cacheWidth,
    required this.cacheHeight,
    required this.gaplessPlayback,
    required this.useDefaultUserAgent,
    this.httpHeaders,
    this.onAspectRatio,
    required this.placeholderBuilder,
    required this.errorBuilder,
  });

  @override
  State<_FallbackNetworkImage> createState() => _FallbackNetworkImageState();
}

class _FallbackNetworkImageState extends State<_FallbackNetworkImage> {
  static const int _maxRetryRounds = 2;
  static const Duration _retryDelay = Duration(milliseconds: 900);

  /// 会话级「取不到」负缓存：某个服务器图标/中立 CDN 资源这次彻底拉失败了，
  /// 本次运行内就不再反复重连——remount 时直接出兜底图，不再闪一遍占位+重试。
  /// 连不上一次基本就一直连不上，没必要每次切页都重来。只对 useDefaultUserAgent
  /// 资源（服务器图标等按需加载的图，非首页海报）生效，避免冷启动误伤海报重试。
  static final Set<String> _deadUrls = <String>{};

  bool get _negativeCache => widget.useDefaultUserAgent;

  /// 解码目标的最大边长上限。即使容器/屏幕很大，也把单张图片解码尺寸
  /// 钳制在此范围内，避免单张全分辨率位图（背景图可达 4K）吃满内存缓存。
  /// 1280 长边 ≈ 1280×720×4 ≈ 3.7MB，足够桌面/TV 清晰显示。
  static const int _maxDecodeDim = 1280;

  int _currentIndex = 0;
  int _retryRound = 0;
  int _requestEpoch = 0;
  bool _retryScheduled = false;

  @override
  void didUpdateWidget(covariant _FallbackNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameUrls(oldWidget.imageUrls, widget.imageUrls) ||
        _currentIndex >= widget.imageUrls.length) {
      _resetFallbackState();
    }
  }

  /// 计算解码（downsample）目标尺寸。
  ///
  /// 关键内存优化：之前 [cacheWidth]/[cacheHeight] 根本没传给 ExtendedImage，
  /// 所有图片都按原始分辨率解码进内存——首页几张背景图就能撑爆缓存。
  /// 现在统一推导一个解码目标：调用方显式给了就用；否则按容器/约束尺寸
  /// × devicePixelRatio 推导，并钳制到 [_maxDecodeDim]，再交给
  /// [ExtendedResizeImage] 让解码器直接以小尺寸出图。
  ({int? width, int? height}) _resolveDecodeSize(
    BoxConstraints constraints,
    double dpr,
  ) {
    int? cap(int? v) => v == null
        ? null
        : (v < 1 ? 1 : (v > _maxDecodeDim ? _maxDecodeDim : v));

    if (widget.cacheWidth != null || widget.cacheHeight != null) {
      return (width: cap(widget.cacheWidth), height: cap(widget.cacheHeight));
    }

    double? w = widget.width;
    if (w == null || !w.isFinite || w <= 0) w = constraints.maxWidth;
    double? h = widget.height;
    if (h == null || !h.isFinite || h <= 0) h = constraints.maxHeight;

    final int? dw = (w.isFinite && w > 0) ? (w * dpr).round() : null;
    final int? dh = (h.isFinite && h > 0) ? (h * dpr).round() : null;
    return (width: cap(dw), height: cap(dh));
  }

  @override
  Widget build(BuildContext context) {
    // 已知拉不到的图：直接出兜底，不再发起网络请求、不闪占位。
    if (_negativeCache && widget.imageUrls.every(_deadUrls.contains)) {
      return widget.errorBuilder();
    }
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final decode = _resolveDecodeSize(constraints, dpr);
        final base = PersistentNetworkImageProvider(
          widget.imageUrls[_currentIndex],
          cache: true,
          // 海报/剧照永久保留；仅手动清缓存、卸载或清除 App 数据删除。
          cacheMaxAge: const Duration(days: 36500),
          retries: 5,
          timeRetry: const Duration(milliseconds: 350),
          requestKey: '$_requestEpoch:$_retryRound:$_currentIndex',
          // 中立资源（服务器图标等）用浏览器 UA，覆盖共享 HttpClient 的 App UA，
          // 避免被第三方 CDN 拒绝导致图标损坏。
          headers: {
            ...?widget.httpHeaders,
            if (widget.imageUrls[_currentIndex]
                .toLowerCase()
                .contains('doubanio.com')) ...{
              'Referer': 'https://movie.douban.com/',
              'User-Agent': kDefaultBrowserUserAgent,
            } else if (widget.useDefaultUserAgent)
              'User-Agent': kDefaultBrowserUserAgent,
          },
        );
        // 以推导出的小尺寸解码并缓存。maxBytes/compressionRatio 必须显式置 null，
        // 否则 ExtendedResizeImage 默认 maxBytes=50KB 会无视 width/height 把图压成
        // 50KB 的糊图。policy.fit 保持纵横比、避免 cover 显示时变形。
        final ImageProvider<Object> provider;
        if (decode.width != null || decode.height != null) {
          provider = ExtendedResizeImage(
            base,
            width: decode.width,
            height: decode.height,
            maxBytes: null,
            compressionRatio: null,
            policy: ResizeImagePolicy.fit,
          );
        } else {
          provider = base;
        }
        return _buildExtendedImage(provider);
      },
    );
  }

  Widget _buildExtendedImage(ImageProvider provider) {
    return ExtendedImage(
      image: provider,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      gaplessPlayback: widget.gaplessPlayback,
      enableMemoryCache: true,
      clearMemoryCacheIfFailed: false,
      enableLoadState: true,
      loadStateChanged: (state) {
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            if (state.extendedImageInfo != null ||
                state.wasSynchronouslyLoaded) {
              _reportAspect(state.extendedImageInfo);
              return state.completedWidget;
            }
            return widget.placeholderBuilder();
          case LoadState.completed:
            if (_negativeCache)
              _deadUrls.remove(widget.imageUrls[_currentIndex]);
            _reportAspect(state.extendedImageInfo);
            return state.completedWidget;
          case LoadState.failed:
            if (_scheduleRetryIfPossible()) {
              return state.extendedImageInfo != null
                  ? state.completedWidget
                  : widget.placeholderBuilder();
            }
            // 重试全用尽仍失败：本次运行记为「取不到」，之后 remount 直接出兜底。
            if (_negativeCache) _deadUrls.addAll(widget.imageUrls);
            return widget.errorBuilder();
        }
      },
    );
  }

  double? _reportedAspect;

  /// 图片解码完成后把真实宽高比回报给上层（只报一次，且在帧后避免 build 中 setState）。
  void _reportAspect(ImageInfo? info) {
    final cb = widget.onAspectRatio;
    if (cb == null || info == null) return;
    final img = info.image;
    if (img.height == 0) return;
    final ratio = img.width / img.height;
    if (_reportedAspect == ratio) return;
    _reportedAspect = ratio;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) cb(ratio);
    });
  }

  void _resetFallbackState() {
    _currentIndex = 0;
    _retryRound = 0;
    _requestEpoch = 0;
    _retryScheduled = false;
  }

  bool _scheduleRetryIfPossible() {
    if (_retryScheduled || !mounted) {
      return _retryScheduled;
    }

    if (_currentIndex < widget.imageUrls.length - 1) {
      _retryScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _currentIndex += 1;
          _retryScheduled = false;
        });
      });
      return true;
    }

    if (_retryRound >= _maxRetryRounds) {
      return false;
    }

    _retryScheduled = true;
    Future<void>.delayed(_retryDelay, () {
      if (!mounted) return;
      setState(() {
        _retryRound += 1;
        _currentIndex = 0;
        _requestEpoch += 1;
        _retryScheduled = false;
      });
    });
    return true;
  }

  bool _sameUrls(List<String> previous, List<String> next) {
    if (identical(previous, next)) return true;
    if (previous.length != next.length) return false;
    for (var i = 0; i < previous.length; i++) {
      if (previous[i] != next[i]) return false;
    }
    return true;
  }
}

Future<void> warmPersistentImageCache(
  BuildContext context,
  Iterable<String> imageUrls, {
  Duration cacheMaxAge = const Duration(days: 30),
}) async {
  final deduped = <String>{};
  for (final imageUrl in imageUrls) {
    if (imageUrl.isEmpty || !deduped.add(imageUrl)) {
      continue;
    }
    try {
      await precacheImage(
        PersistentNetworkImageProvider(
          imageUrl,
          cache: true,
          cacheMaxAge: cacheMaxAge,
        ),
        context,
      );
    } catch (_) {
      // Ignore cache warmup errors and continue with other candidates.
    }
  }
}

class MediaPoster extends ConsumerWidget {
  final MediaItem item;
  final double width;
  final double height;
  final VoidCallback? onTap;
  final String? heroTag;

  const MediaPoster({
    super.key,
    required this.item,
    required this.width,
    required this.height,
    this.onTap,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveMediaItemImageUrls(api, item, maxWidth: 320);
    final useFill = !width.isFinite || !height.isFinite;
    final borderRadius = BorderRadius.circular(16);

    Widget imageWidget = SizedBox(
      width: width.isFinite ? width : null,
      height: height.isFinite ? height : null,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: SizedBox.expand(
            child: Transform.scale(
              scale: 1.05,
              child: MediaImage(
                imageUrl: imageUrls.isNotEmpty ? imageUrls.first : null,
                imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                width: double.infinity,
                height: double.infinity,
                cacheWidth: width.isFinite ? (width * 2).toInt() : 640,
                cacheHeight: height.isFinite ? (height * 2).toInt() : 960,
                fit: BoxFit.cover, // 使用 cover 填满容器，统一显示大小
                heroTag: heroTag,
              ),
            ),
          ),
        ),
      ),
    );

    if (useFill) {
      imageWidget = AspectRatio(
        aspectRatio: 2 / 3,
        child: imageWidget,
      );
    }

    final List<Widget> infoWidgets = [];
    if (item.productionYear != null) {
      infoWidgets.add(
        Text(
          '${item.productionYear}',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).textTheme.bodySmall?.color,
          ),
        ),
      );
    }
    if (item.communityRating != null) {
      if (infoWidgets.isNotEmpty) {
        infoWidgets.add(const SizedBox(width: 6));
      }
      infoWidgets.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star, size: 12, color: Colors.amber),
            const SizedBox(width: 2),
            Text(
              item.communityRating!.toStringAsFixed(1),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.amber,
              ),
            ),
          ],
        ),
      );
    }

    final isSeries = item.type == 'Series' || item.type == 'Season';
    // 角标显示"未看集数"（像 Emby）：优先用服务端 UnplayedItemCount，看完一集即 -1；
    // 服务端没返回时退回总集数。全看完为 0 → 不显示数字（改由已看勾选标记体现）。
    final episodeCount = item.userData?.unplayedItemCount ??
        item.recursiveItemCount ??
        item.childCount;

    return InkWell(
      onTap: onTap,
      borderRadius: borderRadius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: useFill ? MainAxisSize.max : MainAxisSize.min,
        children: [
          useFill
              ? Expanded(
                  child: Stack(
                    children: [
                      imageWidget,
                      Positioned(
                        top: 8,
                        left: 8,
                        child: SelectedRatingBadge(item: item),
                      ),
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: MediaFormatBadges(sources: item.mediaSources),
                      ),
                      if (item.isWatched)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      if (isSeries && episodeCount != null && episodeCount > 0)
                        Positioned(
                          top: 8,
                          right: item.isWatched ? 32 : 8,
                          child: CountBadge(count: episodeCount),
                        ),
                    ],
                  ),
                )
              : Stack(
                  children: [
                    imageWidget,
                    Positioned(
                      top: 8,
                      left: 8,
                      child: SelectedRatingBadge(item: item),
                    ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: MediaFormatBadges(sources: item.mediaSources),
                    ),
                    if (item.isWatched)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    if (isSeries && episodeCount != null && episodeCount > 0)
                      Positioned(
                        top: 8,
                        right: item.isWatched ? 32 : 8,
                        child: CountBadge(count: episodeCount),
                      ),
                  ],
                ),
          const SizedBox(height: 6),
          SizedBox(
            width: width.isFinite ? width : double.infinity,
            child: Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
          if (infoWidgets.isNotEmpty) ...[
            const SizedBox(height: 2),
            SizedBox(
              width: width.isFinite ? width : double.infinity,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: infoWidgets,
              ),
            ),
          ],
          if (item.seriesName != null)
            SizedBox(
              width: width.isFinite ? width : double.infinity,
              child: Text(
                '${item.seriesName} | S${item.parentIndexNumber}E${item.indexNumber}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 骨架占位。对外 API 不变，内部改用带 shimmer 扫光的 [ShimmerBox]，
/// 让所有已用 Skeleton 的页面自动获得呼吸感加载动效。
class Skeleton extends StatelessWidget {
  final double width;
  final double height;
  final BorderRadius? borderRadius;

  const Skeleton({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return ShimmerBox(
      width: width,
      height: height,
      borderRadius: borderRadius ?? BorderRadius.circular(12),
    );
  }
}

class HorizontalList extends StatelessWidget {
  final List<Widget> children;
  final double spacing;
  final EdgeInsets padding;
  final double? height;

  const HorizontalList({
    super.key,
    required this.children,
    this.spacing = 12,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: children.length,
        separatorBuilder: (_, __) => SizedBox(width: spacing),
        itemBuilder: (_, index) => RepaintBoundary(
          child: children[index],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onMoreTap;

  const SectionHeader({
    super.key,
    required this.title,
    this.onMoreTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (onMoreTap != null)
            GestureDetector(
              onTap: onMoreTap,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '查看更多',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 单个版本（MediaSource）的媒体信息卡片：与桌面 `_MediaInfoPanel` 同字段——名称 /
/// 视频 / 容器·大小·码率 + **全部**音频轨、**全部**字幕轨（用 readableLabel 统一标签）。
/// 移动端详情页共用，修复此前只显示首条音轨/字幕、且缺容器·大小·码率的「信息太少」。
class MediaSourceInfoCard extends StatelessWidget {
  final MediaSource source;
  const MediaSourceInfoCard({super.key, required this.source});

  static String _formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '未知';
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  static String? _formatBitrate(int? bps) {
    if (bps == null || bps <= 0) return null;
    return bps >= 1000000
        ? '${(bps / 1000000).toStringAsFixed(1)} Mbps'
        : '${(bps / 1000).toStringAsFixed(0)} Kbps';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final video = source.primaryVideoStream;
    final audios = source.mediaStreams.where((s) => s.isAudio).toList();
    final subs = source.mediaStreams.where((s) => s.isSubtitle).toList();

    String videoLabel = '';
    if (video != null) {
      final segs = <String>[
        if (video.resolution.isNotEmpty) video.resolution,
        if (video.videoFormatLabel.isNotEmpty) video.videoFormatLabel,
      ];
      videoLabel = segs.isNotEmpty
          ? segs.join(' / ')
          : (video.displayTitle ?? video.codec ?? '');
    }

    // 容器 · 大小 · 码率 合成一行次要信息（与桌面 _MediaInfoPanel 同来源）。
    final meta = <String>[
      if ((source.container ?? '').isNotEmpty) source.container!.toUpperCase(),
      _formatSize(source.size),
      if (_formatBitrate(video?.bitRate) != null)
        _formatBitrate(video!.bitRate)!,
    ].join(' · ');

    Widget iconRow(IconData icon, Color color, String text) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
            ],
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((source.name ?? '').isNotEmpty) ...[
              Text(source.name!,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 2),
            ],
            if (video != null)
              iconRow(Icons.videocam, scheme.primary, videoLabel),
            if (meta.isNotEmpty)
              iconRow(Icons.info_outline, scheme.outline, meta),
            for (final a in audios)
              iconRow(Icons.audiotrack, scheme.secondary,
                  a.readableLabel(siblings: audios)),
            for (final s in subs)
              iconRow(Icons.subtitles, scheme.tertiary,
                  s.readableLabel(siblings: subs)),
          ],
        ),
      ),
    );
  }
}

class RatingBadge extends StatelessWidget {
  final double? rating;
  final double size;

  const RatingBadge({
    super.key,
    this.rating,
    this.size = 14,
  });

  @override
  Widget build(BuildContext context) {
    if (rating == null) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star, size: size, color: Colors.amber),
        const SizedBox(width: 2),
        Text(
          rating!.toStringAsFixed(1),
          style: TextStyle(
            fontSize: size - 1,
            fontWeight: FontWeight.w600,
            color: Colors.amber.shade700,
          ),
        ),
      ],
    );
  }
}

class TagBadge extends StatelessWidget {
  final String text;
  final Color? backgroundColor;
  final Color? textColor;

  const TagBadge({
    super.key,
    required this.text,
    this.backgroundColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor ??
            Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: textColor ?? Theme.of(context).textTheme.bodySmall?.color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
