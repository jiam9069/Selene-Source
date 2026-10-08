import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:selene/models/emby_models.dart';
import 'package:selene/services/emby_service.dart';

/// 私人影库（MoonTVPlus Emby）模块的纯解析 / 分页单元测试
///
/// 夹具均取自真实 MoonTVPlus 实例的 `/api/emby/*` 响应片段，
/// 用于锁定「后端字段类型不统一」时的解析行为。
///
/// 本文件不发起任何网络请求，也不挂载 Widget。
void main() {
  // 真实响应：GET {base}/api/emby/sources
  const sourcesJson = '''
{"sources":[{"key":"net","name":"Hohai公益Emby"},
 {"key":"net2","name":"ETFLIX Emby"},
 {"key":"net3","name":"Funland+"}]}
''';

  // 真实响应：GET {base}/api/emby/views?source=net
  const viewsJson = '''
{"success":true,"views":[
 {"id":"287756","name":"1️⃣最新剧集","type":"tvshows"},
 {"id":"333993","name":"2️⃣国产剧","type":"tvshows"},
 {"id":"336495","name":"3️⃣日韩剧","type":"tvshows"},
 {"id":"334351","name":"4️⃣欧美剧","type":"tvshows"},
 {"id":"337740","name":"5️⃣综合类","type":"tvshows"},
 {"id":"294558","name":"6️⃣电影","type":"movies"}]}
''';

  // 真实响应片段：GET {base}/api/emby/list?source=net&viewId=287756&page=1
  const listItemMovieJson = '''
{"id":"467492","title":"《电诈 摇滚 吴哥窟》",
 "poster":"https://emby-npo.hohai.eu.org/emby/Items/467492/Images/Primary?api_key=xxx",
 "year":"2026","rating":0,"mediaType":"movie"}
''';

  const listItemTvJson = '''
{"id":"463379","title":"【我推的孩子】",
 "poster":"https://emby-npo.hohai.eu.org/emby/Items/463379/Images/Primary?api_key=xxx",
 "year":"2023","rating":0,"mediaType":"tv"}
''';

  Map<String, dynamic> decode(String raw) =>
      json.decode(raw) as Map<String, dynamic>;

  group('EmbySource.fromJson', () {
    test('解析真实 /api/emby/sources 响应', () {
      final sources = EmbySource.listFromResponse(decode(sourcesJson));

      expect(sources.length, 3);
      expect(sources[0].key, 'net');
      expect(sources[0].name, 'Hohai公益Emby');
      expect(sources[1].key, 'net2');
      expect(sources[1].name, 'ETFLIX Emby');
      expect(sources[2].key, 'net3');
      expect(sources[2].name, 'Funland+');
    });

    test('未配置 Emby 时返回空列表', () {
      expect(EmbySource.listFromResponse(decode('{"sources":[]}')), isEmpty);
    });

    test('字段缺失 / 类型异常时不抛异常', () {
      final source = EmbySource.fromJson(const {});
      expect(source.key, '');
      expect(source.name, '');
      // name 缺失时退回 key，避免选择器出现空白项
      expect(source.displayName, '');

      final withKeyOnly = EmbySource.fromJson(const {'key': 'net'});
      expect(withKeyOnly.displayName, 'net');

      expect(
        EmbySource.listFromResponse(const {'sources': 'not-a-list'}),
        isEmpty,
      );
      expect(
        EmbySource.listFromResponse(const {
          'sources': [null, 42, {'name': '没有 key'}]
        }),
        isEmpty,
      );
      expect(EmbySource.listFromResponse(null), isEmpty);
    });
  });

  group('EmbyView.fromJson', () {
    test('解析真实 /api/emby/views 响应', () {
      final views = EmbyView.listFromResponse(decode(viewsJson));

      expect(views.length, 6);
      expect(views.first.id, '287756');
      expect(views.first.name, '1️⃣最新剧集');
      expect(views.first.type, 'tvshows');
      expect(views.last.id, '294558');
      expect(views.last.name, '6️⃣电影');
      expect(views.last.type, 'movies');
      expect(views.last.isMovieView, isTrue);
      expect(views.first.isMovieView, isFalse);
      // 空列表时不应混入无 id 的条目
      expect(views.every((v) => v.id.isNotEmpty), isTrue);
    });

    test('字段缺失 / 为 null 时不抛异常', () {
      final view = EmbyView.fromJson(const {});
      expect(view.id, '');
      expect(view.name, '');
      expect(view.type, '');
      expect(view.displayName, '未命名分类');

      // 无 id 的分类会被丢弃（无法用于请求列表）
      expect(EmbyView.listFromResponse(const {'views': [null, {}]}), isEmpty);
      expect(EmbyView.listFromResponse(const {}), isEmpty);
      expect(EmbyView.listFromResponse(null), isEmpty);
    });
  });

  group('EmbyItem.fromJson', () {
    test('解析真实电影条目', () {
      final item = EmbyItem.fromJson(decode(listItemMovieJson));

      expect(item.id, '467492');
      expect(item.title, '《电诈 摇滚 吴哥窟》');
      expect(
        item.poster,
        'https://emby-npo.hohai.eu.org/emby/Items/467492/Images/Primary?api_key=xxx',
      );
      expect(item.year, '2026');
      expect(item.rating, 0.0);
      expect(item.mediaType, 'movie');
      expect(item.isMovie, isTrue);
      expect(item.isTv, isFalse);
      expect(item.typeLabel, '电影');
      expect(item.displayYear, '2026');
      // 评分为 0 视为无评分
      expect(item.hasRating, isFalse);
      expect(item.ratingText, '');
    });

    test('解析真实剧集条目', () {
      final item = EmbyItem.fromJson(decode(listItemTvJson));

      expect(item.id, '463379');
      expect(item.title, '【我推的孩子】');
      expect(item.year, '2023');
      expect(item.mediaType, 'tv');
      expect(item.isTv, isTrue);
      expect(item.isMovie, isFalse);
      expect(item.typeLabel, '剧集');
    });

    test('rating 为 int 或 double 都能解析', () {
      expect(EmbyItem.fromJson(const {'rating': 0}).rating, 0.0);
      expect(EmbyItem.fromJson(const {'rating': 8}).rating, 8.0);
      expect(EmbyItem.fromJson(const {'rating': 8.7}).rating, 8.7);
      expect(EmbyItem.fromJson(const {'rating': 8}).hasRating, isTrue);
      expect(EmbyItem.fromJson(const {'rating': 8}).ratingText, '8.0');
      expect(EmbyItem.fromJson(const {'rating': 8.75}).ratingText, '8.8');
      // 数字字符串也能兜住
      expect(EmbyItem.fromJson(const {'rating': '9.1'}).rating, 9.1);
      // 无法解析 / 类型异常一律回落到 0
      expect(EmbyItem.fromJson(const {'rating': 'abc'}).rating, 0.0);
      expect(EmbyItem.fromJson(const {'rating': null}).rating, 0.0);
    });

    test('year 为 int 或 String 都转换为 String', () {
      expect(EmbyItem.fromJson(const {'year': 2026}).year, '2026');
      expect(EmbyItem.fromJson(const {'year': 2026.0}).year, '2026');
      expect(EmbyItem.fromJson(const {'year': '2024'}).year, '2024');
      expect(EmbyItem.fromJson(const {'year': null}).year, '');
      expect(EmbyItem.fromJson(const {'year': 2026}).displayYear, '2026');
      expect(EmbyItem.fromJson(const {}).displayYear, '未知年份');
    });

    test('缺失 / null 字段不抛异常', () {
      final item = EmbyItem.fromJson(const {});

      expect(item.id, '');
      expect(item.title, '');
      expect(item.poster, '');
      expect(item.year, '');
      expect(item.rating, 0.0);
      // mediaType 缺失时按电影处理（用于角标展示）
      expect(item.mediaType, 'movie');
      expect(item.typeLabel, '电影');
    });

    test('listFromResponse 容忍脏数据', () {
      expect(EmbyItem.listFromResponse(const {}), isEmpty);
      expect(EmbyItem.listFromResponse(null), isEmpty);
      expect(EmbyItem.listFromResponse(const {'list': 'nope'}), isEmpty);

      final items = EmbyItem.listFromResponse(const {
        'success': true,
        'list': [
          {'id': '1', 'title': '正常条目', 'year': 2024, 'rating': 7.5},
          null,
          'oops',
          {'title': '没有 id'},
        ],
      });
      expect(items.length, 2);
      expect(items[0].id, '1');
      expect(items[0].year, '2024');
      expect(items[0].rating, 7.5);
      expect(items[1].id, '');
    });

    test('copyWith 用于补全绝对海报地址', () {
      final item = EmbyItem.fromJson(decode(listItemMovieJson));
      final patched = item.copyWith(poster: 'https://example.com/a.jpg');

      expect(patched.poster, 'https://example.com/a.jpg');
      expect(patched.id, item.id);
      expect(patched.title, item.title);
      expect(patched.year, item.year);
      expect(patched.mediaType, item.mediaType);
    });
  });

  group('末页判定', () {
    test('每页固定 20 条', () {
      expect(EmbyPagination.pageSize, 20);
      expect(EmbyService.pageSize, 20);
    });

    test('不足 20 条即为末页（含空列表）', () {
      expect(EmbyPagination.isLastPage(0), isTrue);
      expect(EmbyPagination.isLastPage(1), isTrue);
      expect(EmbyPagination.isLastPage(19), isTrue);
      expect(EmbyPagination.isLastPage(20), isFalse);
      expect(EmbyPagination.isLastPage(21), isFalse);

      expect(EmbyPagination.hasMoreAfter(19), isFalse);
      expect(EmbyPagination.hasMoreAfter(20), isTrue);
    });

    test('EmbyService.isLastPage 与分页约定一致', () {
      expect(EmbyService.isLastPage(0), isTrue);
      expect(EmbyService.isLastPage(19), isTrue);
      expect(EmbyService.isLastPage(20), isFalse);
    });
  });
}
