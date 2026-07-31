import '../../core/api/api_interfaces.dart';

/// 图片尺寸统一策略
enum ImageSizeUnifyStrategy {
  /// 不统一，每个项目使用自己的纵横比
  disable,

  /// 智能统一：根据列表中大多数项目的纵横比决定
  /// 如果 80% 以上是横图 (>1.0) -> 统一为视频尺寸 16:9
  /// 如果 80% 以上是竖图 (<=1.0) -> 统一为海报尺寸 2:3
  /// 否则 -> 不统一
  majority,

  /// 强制使用视频尺寸 16:9
  forceVideo,

  /// 强制使用海报尺寸 2:3
  forcePoster,
}

/// 图片尺寸偏好
class ImageSizePreference {
  /// 宽度
  final double width;

  /// 高度
  final double height;

  /// 纵横比
  double get aspectRatio => width / height;

  const ImageSizePreference({
    required this.width,
    required this.height,
  });

  /// 海报尺寸 2:3 (竖向)
  static const poster = ImageSizePreference(width: 120, height: 180);

  /// 视频尺寸 16:9 (横向)
  static const video = ImageSizePreference(width: 160, height: 90);

  /// 方形
  static const square = ImageSizePreference(width: 120, height: 120);
}

/// 图片尺寸辅助工具
class ImageSizeHelper {
  ImageSizeHelper._();

  /// 根据媒体项目类型推断偏好的纵横比
  /// 返回 null 表示使用默认（2:3 海报）
  static double? inferAspectRatioFromType(String type) {
    switch (type) {
      case 'Movie':
      case 'Series':
      case 'Season':
      case 'Person':
      case 'Actor':
        return 2 / 3; // 海报比例

      case 'Episode':
      case 'Video':
      case 'MusicVideo':
      case 'Trailer':
        return 16 / 9; // 视频比例

      case 'CollectionFolder':
      case 'UserView':
      case 'Folder':
        return 1.0; // 方形

      default:
        return null; // 使用默认
    }
  }

  /// 分析列表中的图片纵横比分布，返回统一的尺寸偏好
  ///
  /// [items] 媒体项目列表
  /// [strategy] 统一策略
  ///
  /// 返回统一的尺寸偏好，如果返回 null 表示不统一
  static ImageSizePreference? analyzeAndUnify(
    List<MediaItem> items,
    ImageSizeUnifyStrategy strategy,
  ) {
    if (items.isEmpty) return null;

    switch (strategy) {
      case ImageSizeUnifyStrategy.disable:
        return null;

      case ImageSizeUnifyStrategy.forceVideo:
        return ImageSizePreference.video;

      case ImageSizeUnifyStrategy.forcePoster:
        return ImageSizePreference.poster;

      case ImageSizeUnifyStrategy.majority:
        return _analyzeMajority(items);
    }
  }

  /// 智能分析大多数项目的纵横比
  static ImageSizePreference? _analyzeMajority(List<MediaItem> items) {
    if (items.isEmpty) return null;

    // 收集所有项目推断的纵横比
    final aspectRatios = items
        .map((item) => inferAspectRatioFromType(item.type))
        .where((ratio) => ratio != null)
        .map((ratio) => ratio!)
        .toList();

    if (aspectRatios.isEmpty) return null;

    // 统计横向图片（纵横比 > 1.0）的百分比
    final horizontalCount = aspectRatios.where((ratio) => ratio > 1.0).length;
    final percentage = horizontalCount / aspectRatios.length;

    // 如果 80% 以上是横向图片，统一为视频尺寸
    if (percentage > 0.8) {
      return ImageSizePreference.video;
    }

    // 如果 20% 以下是横向图片（即 80% 以上是竖向），统一为海报尺寸
    if (percentage < 0.2) {
      return ImageSizePreference.poster;
    }

    // 混合情况，不统一
    return null;
  }

  /// 为继续观看区域分析尺寸
  /// 继续观看通常包含混合类型，优先使用视频尺寸（因为大多是剧集）
  static ImageSizePreference analyzeForResumeSection(List<MediaItem> items) {
    return analyzeAndUnify(items, ImageSizeUnifyStrategy.majority)
        ?? ImageSizePreference.video;
  }

  /// 为最新内容区域分析尺寸
  /// 最新内容通常是海报类型
  static ImageSizePreference analyzeForLatestSection(List<MediaItem> items) {
    return analyzeAndUnify(items, ImageSizeUnifyStrategy.majority)
        ?? ImageSizePreference.poster;
  }
}
