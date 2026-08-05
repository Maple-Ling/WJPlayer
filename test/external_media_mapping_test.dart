import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/api/discover/external_media_models.dart';

/// 外部媒体详情字段映射回归。
///
/// 目的：防止“接口真实返回了字段，但模型/解析丢字段”的回归。
/// 用真实抓取样本的字段形态，覆盖豆瓣、IMDb、TMDB 三套来源。
void main() {
  group('ExternalMediaDetail.fromJson', () {
    test('豆瓣详情保留演员、导演、时长与推荐', () {
      final detail = ExternalMediaDetail.fromJson({
        'tmdbId': 0,
        'mediaType': 'movie',
        'title': '肖申克的救赎',
        'originalTitle': 'The Shawshank Redemption',
        'overview': 'intro',
        'posterUrl': 'https://img3.doubanio.com/poster.jpg',
        'rating': 9.7,
        'year': '1994',
        'runtime': 142,
        'genres': ['剧情', '犯罪'],
        'people': [
          {
            'id': '1054521',
            'name': '蒂姆·罗宾斯',
            'source': 'douban',
            'originalName': 'Tim Robbins',
            'character': '饰 安迪·杜佛兰',
            'profileUrl': 'https://img9.doubanio.com/celebrity/p17525.jpg',
          },
        ],
        'images': ['https://img1.doubanio.com/photo1.jpg'],
        'recommendations': [
          {
            'id': '1292720',
            'title': '阿甘正传',
            'source': 'douban',
            'mediaType': 'movie',
            'doubanId': '1292720',
          },
        ],
        'doubanId': '1292052',
      });

      expect(detail.title, '肖申克的救赎');
      expect(detail.runtime, 142);
      expect(detail.people, hasLength(1));
      expect(detail.people.first.name, '蒂姆·罗宾斯');
      expect(detail.people.first.profileUrl, isNotNull);
      expect(detail.people.first.source.name, 'douban');
      expect(detail.recommendations, hasLength(1));
      expect(detail.recommendations.first.title, '阿甘正传');
      expect(detail.doubanId, '1292052');
    });

    test('IMDb 详情保留演员照片与时长', () {
      final detail = ExternalMediaDetail.fromJson({
        'tmdbId': 0,
        'mediaType': 'movie',
        'title': 'The Shawshank Redemption',
        'posterUrl': 'https://m.media-amazon.com/poster.jpg',
        'rating': 9.3,
        'year': '1994',
        'runtime': 142,
        'genres': ['Drama'],
        'people': [
          {
            'id': 'nm0000209',
            'name': 'Tim Robbins',
            'source': 'imdb',
            'character': 'Andy Dufresne',
            'profileUrl':
                'https://m.media-amazon.com/images/M/TimRobbins._V1_.jpg',
          },
        ],
        'imdbId': 'tt0111161',
      });

      expect(detail.people, hasLength(1));
      expect(detail.people.first.id, 'nm0000209');
      expect(detail.people.first.profileUrl, isNotNull);
      expect(detail.people.first.source.name, 'imdb');
      expect(detail.runtime, 142);
      expect(detail.imdbId, 'tt0111161');
    });

    test('TMDB 详情保留演员与工作室', () {
      final detail = ExternalMediaDetail.fromJson({
        'tmdbId': 278,
        'mediaType': 'movie',
        'title': '肖申克的救赎',
        'rating': 8.7,
        'people': [
          {
            'id': '504',
            'name': 'Tim Robbins',
            'source': 'tmdb',
            'profileUrl': 'https://image.tmdb.org/t/p/w500/profile.jpg',
          },
        ],
        'companies': [
          {'id': 97, 'name': 'Castle Rock Entertainment'},
        ],
      });

      expect(detail.tmdbId, 278);
      expect(detail.people.first.source.name, 'tmdb');
      expect(detail.companies, hasLength(1));
      expect(detail.companies.first.name, 'Castle Rock Entertainment');
    });
  });

  group('ExternalPerson', () {
    test('缺失来源按豆瓣兼容旧缓存', () {
      final person = ExternalPerson.fromJson({
        'id': '1054521',
        'name': '蒂姆·罗宾斯',
      });
      expect(person.source.name, 'douban');
      expect(person.id, '1054521');
    });

    test('IMDb 人物 ID 不会被转成整数', () {
      final person = ExternalPerson.fromJson({
        'id': 'nm0000209',
        'name': 'Tim Robbins',
        'source': 'imdb',
      });
      expect(person.id, 'nm0000209');
    });
  });
}
