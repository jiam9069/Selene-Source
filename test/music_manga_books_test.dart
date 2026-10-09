import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:selene/models/book_models.dart';
import 'package:selene/models/manga_models.dart';
import 'package:selene/models/music_models.dart';
import 'package:selene/screens/books_screen.dart';
import 'package:selene/screens/manga_screen.dart';
import 'package:selene/screens/music_screen.dart';
import 'package:selene/services/books_service.dart';
import 'package:selene/services/manga_service.dart';
import 'package:selene/services/music_service.dart';
import 'package:selene/services/theme_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 音乐 / 漫画 / 电子书三大模块的测试
///
/// 分三层：
/// 1. 纯解析：夹具全部对应 MoonTVPlus v226.1.0 后端的真实响应结构
///    （music v2 / manga Suwayomi / books OPDS+Legado），不发网络、不挂 Widget；
/// 2. 服务探测：伪造 HTTP 层验证入口可见性探测（isAvailable）的判定边界；
/// 3. 页面 smoke：挂真实页面，验证加载 / 搜索 / 过滤的主链路。
///
/// 三个服务都有进程级静态缓存，每个用例前必须 reset，否则会互相污染。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------- HTTP 伪造

  HttpClientResponse jsonResponse(Object body, {int status = 200}) {
    final bytes = utf8.encode(json.encode(body));
    return _FakeJsonResponse(status, bytes);
  }

  void installRoutes(Object? Function(Uri) router) {
    HttpOverrides.global = _RouterOverrides((url) async {
      final result = router(url);
      if (result is HttpClientResponse) return result;
      return jsonResponse(result ?? <String, dynamic>{});
    });
    addTearDown(() => HttpOverrides.global = null);
  }

  setUpAll(() {
    SharedPreferences.setMockInitialValues({
      'server_url': 'http://fake',
      'cookies': 'auth=%7B%22username%22%3A%22owner%22%7D',
      'username': 'owner',
    });
  });

  setUp(() {
    // 三个服务的静态缓存跨用例共享，必须逐个清掉
    MusicService.resetAvailabilityCache();
    MangaService.resetSourcesCache();
    BooksService.resetSourcesCache();
  });

  Map<String, dynamic> decode(String raw) =>
      json.decode(raw) as Map<String, dynamic>;

  // ================================================================ 纯解析

  group('MusicSong 解析', () {
    test('解析真实形状的搜索响应（含空结果防御）', () {
      const body = '''
{"success":true,"data":{"list":[
 {"songId":"kw_223224586","source":"kw","songmid":"223224586","name":"晴天",
  "artist":"周杰伦","album":"叶惠美","cover":"https://img.example/1.jpg",
  "durationText":"04:29","durationSec":269},
 {"songId":"","source":"kw","name":"没ID的脏数据"},
 null],
 "type":"song","page":1,"limit":30,"hasMore":true}}
''';
      final songs = MusicSong.listFromSearchResponse(decode(body));
      expect(songs.length, 1);
      expect(songs[0].songId, 'kw_223224586');
      expect(songs[0].name, '晴天');
      expect(songs[0].artist, '周杰伦');
      expect(songs[0].durationText, '04:29');
      expect(songs[0].displayTitle, '晴天 - 周杰伦');
    });

    test('结构完全不对时返回空列表而不抛异常', () {
      expect(MusicSong.listFromSearchResponse(null), isEmpty);
      expect(MusicSong.listFromSearchResponse(<String, dynamic>{}), isEmpty);
      expect(MusicSong.listFromSearchResponse('not a map'), isEmpty);
      expect(
        MusicSong.listFromSearchResponse({'data': {'list': 'not a list'}}),
        isEmpty,
      );
    });
  });

  group('MusicPlayInfo 解析', () {
    test('解析 play 响应：流地址 + LRC 歌词 + 翻译', () {
      const body = '''
{"success":true,"data":{
 "song":{"songId":"kw_1","source":"kw","name":"晴天","artist":"周杰伦"},
 "play":{"url":"/api/music/v2/stream?songId=kw_1&source=kw&quality=320k",
   "directUrl":"https://m.example/a.mp3","quality":"320k","requestedQuality":"320k"},
 "lyric":{"lyric":"[00:12.00]故事的小黄花\\n[01:30.50]从出生那年就飘着",
   "tlyric":"[00:12.00]translation a"},
 "meta":{"attempts":[],"includeUrl":true}}}
''';
      final playInfo = MusicPlayInfo.fromPlayResponse(decode(body));
      expect(playInfo, isNotNull);
      expect(playInfo!.streamUrl, startsWith('/api/music/v2/stream?'));
      expect(playInfo.quality, '320k');
      expect(playInfo.lyricLines.length, 2);
      expect(playInfo.lyricLines[0].timeMs, 12000);
      expect(playInfo.lyricLines[0].text, '故事的小黄花');
      // 01:30.50 → 90000 + 500 = 90500ms
      expect(playInfo.lyricLines[1].timeMs, 90500);
      expect(playInfo.translations[12000], 'translation a');
    });

    test('play 缺 url / 失败时返回 null', () {
      expect(
        MusicPlayInfo.fromPlayResponse({'success': false}),
        isNull,
      );
      expect(
        MusicPlayInfo.fromPlayResponse({
          'data': {'song': {}, 'lyric': {}},
        }),
        isNull,
      );
    });

    test('LRC 多时间标签一行展开为多行，纯文本歌词回退为空', () {
      final lines = MusicPlayInfo.parseLrc('[00:12.00][01:30.00]同一句');
      expect(lines.length, 2);
      expect(lines.every((line) => line.text == '同一句'), isTrue);
      expect(MusicPlayInfo.parseLrc('纯文本没有时间标签'), isEmpty);
      expect(MusicPlayInfo.parseLrc(''), isEmpty);
    });
  });

  group('MusicHistoryRecord 解析', () {
    test('解析最近播放响应', () {
      const body = '''
{"success":true,"data":{"records":[
 {"song":{"songId":"kw_1","source":"kw","name":"晴天","artist":"周杰伦"},
  "playProgressSec":10,"lastPlayedAt":1760000000000,"playCount":2,
  "lastQuality":"320k","createdAt":1760000000000}]}}
''';
      final records = MusicHistoryRecord.listFromResponse(decode(body));
      expect(records.length, 1);
      expect(records[0].song.name, '晴天');
      expect(records[0].playCount, 2);
    });
  });

  group('MusicSourceId', () {
    test('白名单内的音源正常解析，未知回退酷我', () {
      expect(MusicSourceId.parse('wy'), MusicSourceId.wy);
      expect(MusicSourceId.parse('mg'), MusicSourceId.mg);
      expect(MusicSourceId.parse('不存在'), MusicSourceId.kw);
      expect(MusicSourceId.parse(null), MusicSourceId.kw);
    });
  });

  group('Manga 解析', () {
    test('源列表：displayName 优先，缺 name 时回退 id', () {
      const body = '''
{"sources":[{"id":"2000","name":"local_source","lang":"zh","displayName":"本地源"},
 {"id":"2001","displayName":"无name"}]}
''';
      final sources = MangaSource.listFromResponse(decode(body));
      expect(sources.length, 2);
      expect(sources[0].displayName, '本地源');
      expect(sources[1].displayName, '无name');
    });

    test('搜索结果：过滤缺 id 的脏数据', () {
      const body = '''
{"results":[
 {"id":"manga/one-piece","sourceId":"2000","sourceName":"本地源","title":"海贼王",
  "cover":"/api/manga/image?path=%2Fcover","author":"尾田荣一郎","status":"进行中"},
 {"id":"","sourceId":"2000","title":"没ID"}],
 "failedSources":[]}
''';
      final items = MangaItem.listFromSearchResponse(decode(body));
      expect(items.length, 1);
      expect(items[0].title, '海贼王');
      expect(items[0].author, '尾田荣一郎');
    });

    test('详情：章节列表与元数据一起解析', () {
      const body = '''
{"id":"manga/one-piece","sourceId":"2000","sourceName":"本地源","title":"海贼王",
 "cover":"","chapters":[
 {"id":"123","mangaId":"manga/one-piece","name":"第1话","chapterNumber":1},
 {"id":"","name":"脏章节"},
 {"id":"124","mangaId":"manga/one-piece","name":"第2话"}]}
''';
      final detail = MangaDetail.fromJson(decode(body));
      expect(detail.title, '海贼王');
      expect(detail.chapters.length, 2);
      expect(detail.chapters[0].name, '第1话');
      expect(detail.chapters[1].id, '124');
    });

    test('页列表：相对代理路径原样保留', () {
      const body = '''
{"pages":["/api/manga/image?path=%2Fapi%2Fv1%2Fchapter%2F1.webp",
 "/api/manga/image?path=%2Fapi%2Fv1%2Fchapter%2F2.webp"]}
''';
      final pages = MangaPages.fromResponse(decode(body));
      expect(pages.paths.length, 2);
      expect(pages.paths.first, startsWith('/api/manga/image?path='));
    });
  });

  group('Books 解析', () {
    const sourcesBody = '''
{"sources":[
 {"id":"opds-main","name":"OPDS 主库","type":"opds","url":"https://opds.example"},
 {"id":"legado-1","name":"笔趣阁","type":"legado","url":"https://legado.example"},
 {"id":"legado-2","name":"起点","type":"legado","url":"https://qidian.example"}]}
''';

    test('源列表：onlyLegado 只保留 Legado 源', () {
      final all = BookSource.listFromResponse(decode(sourcesBody));
      expect(all.length, 3);
      final legado =
          BookSource.listFromResponse(decode(sourcesBody), onlyLegado: true);
      expect(legado.length, 2);
      expect(legado.every((source) => source.isLegado), isTrue);
    });

    test('搜索结果过滤缺字段的条目', () {
      const body = '''
{"results":[
 {"id":"b1","sourceId":"legado-1","sourceName":"笔趣阁","title":"三体",
  "author":"刘慈欣","summary":"地球往事","detailHref":"https://legado.example/1",
  "acquisitionLinks":[]},
 {"id":"b2","sourceId":"opds-main","title":"没有作者"},
 {"sourceId":"legado-1","title":"没有 id"}],
 "failedSources":[]}
''';
      final items = BookListItem.listFromSearchResponse(decode(body));
      expect(items.length, 2);
      expect(items[0].title, '三体');
      expect(items[0].detailHref, isNotEmpty);
    });

    test('章节目录与正文解析，正文剔除残留标签', () {
      const chaptersBody = '''
{"chapters":[
 {"id":"c1","title":"第一章 疯狂年代","href":"https://legado.example/1/1","order":0},
 {"id":"","title":"脏数据","href":""}]}
''';
      final chapters = BookChapterList.fromResponse(decode(chaptersBody));
      expect(chapters.chapters.length, 1);
      expect(chapters.chapters[0].title, '第一章 疯狂年代');

      const contentBody = '''
{"id":"x","title":"第一章","href":"https://legado.example/1/1",
 "content":"第一段<br>第二段<img src=\\"https://img\\">　第三段",
 "previousHref":"","nextHref":"https://legado.example/1/2"}
''';
      final content = BookChapterContent.fromResponse(decode(contentBody));
      expect(content, isNotNull);
      expect(content!.nextHref, isNotEmpty);
      // <img> 被剔除后不产生分段（前后文字仍是一段）；
      // 全角空格（段首缩进）必须保留，不能当成 ASCII 空白 trim 掉
      expect(content.paragraphs, ['第一段', '第二段　第三段']);
    });
  });

  // ================================================================ 服务探测

  group('入口可见性探测', () {
    test('音乐：热搜接口成功即可用', () async {
      installRoutes((url) {
        if (url.path.contains('/api/music/v2/discovery/hot-search')) {
          return {'success': true, 'data': {'list': ['周杰伦']}};
        }
        return {'success': false};
      });
      expect(await MusicService.isAvailable(), isTrue);
    });

    test('音乐：上游 LxMusic 服务失联（5xx）时不可用', () async {
      installRoutes((url) async {
        return jsonResponse(
          {'success': false, 'error': {'code': 'INTERNAL_ERROR'}},
          status: 500,
        );
      });
      expect(await MusicService.isAvailable(), isFalse);
    });

    test('漫画：有源可用，没源（后端未配 Suwayomi）不可用', () async {
      installRoutes((url) {
        if (url.path.contains('/api/manga/sources')) {
          return {'sources': [{'id': '2000', 'name': '本地源'}]};
        }
        return {};
      });
      expect(await MangaService.isAvailable(), isTrue);

      MangaService.resetSourcesCache();
      installRoutes((url) => {'sources': []});
      expect(await MangaService.isAvailable(), isFalse);
    });

    test('电子书：任何书源都算可用（含纯 OPDS）', () async {
      installRoutes((url) {
        if (url.path.contains('/api/books/sources')) {
          return {
            'sources': [
              {'id': 'opds-main', 'name': 'OPDS', 'type': 'opds'},
            ],
          };
        }
        return {};
      });
      expect(await BooksService.isAvailable(), isTrue);
      expect(await BooksService.hasLegadoSources(), isFalse);
    });
  });

  // ================================================================ 页面 smoke

  String visibleText(WidgetTester tester) {
    final buffer = StringBuffer();
    for (final element in find.byType(RichText).evaluate()) {
      buffer.writeln((element.widget as RichText).text.toPlainText());
    }
    for (final element in find.byType(Text).evaluate()) {
      final data = (element.widget as Text).data;
      if (data != null) buffer.writeln(data);
    }
    return buffer.toString();
  }

  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeService>.value(
        value: ThemeService(),
        child: MaterialApp(home: screen),
      ),
    );
    // 等 initState 的首个请求回来
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('音乐页：最近播放兜底展示', (tester) async {
    installRoutes((url) {
      if (url.path.contains('/api/music/v2/history')) {
        return {
          'success': true,
          'data': {
            'records': [
              {
                'song': {
                  'songId': 'kw_1',
                  'source': 'kw',
                  'name': '晴天',
                  'artist': '周杰伦',
                },
                'playProgressSec': 10,
                'lastPlayedAt': 1,
                'playCount': 1,
              },
            ],
          },
        };
      }
      return {'success': true, 'data': {}};
    });

    await pumpScreen(tester, const MusicScreen());

    final text = visibleText(tester);
    expect(text, contains('最近播放'));
    expect(text, contains('晴天'));
    expect(text, contains('周杰伦'));
  });

  testWidgets('漫画页：源 chips 与空态提示', (tester) async {
    installRoutes((url) {
      if (url.path.contains('/api/manga/sources')) {
        return {
          'sources': [
            {'id': '2000', 'name': '本地源'},
            {'id': '2001', 'displayName': '备用源'},
          ],
        };
      }
      return {};
    });

    await pumpScreen(tester, const MangaScreen());

    final text = visibleText(tester);
    expect(text, contains('全部'));
    expect(text, contains('本地源'));
    expect(text, contains('备用源'));
    expect(text, contains('搜一部漫画开始阅读'));
  });

  testWidgets('电子书页：只放行 Legado 结果，OPDS 结果被过滤', (tester) async {
    // 记录章节目录请求带的定位参数（href / bookId 二选一）
    final chapterRequestParams = <Map<String, String>>[];

    installRoutes((url) {
      if (url.path.contains('/api/books/sources')) {
        return {
          'sources': [
            {'id': 'opds-main', 'name': 'OPDS 主库', 'type': 'opds'},
            {'id': 'legado-1', 'name': '笔趣阁', 'type': 'legado'},
          ],
        };
      }
      if (url.path.contains('/api/books/search')) {
        return {
          'results': [
            {
              'id': 'b1',
              'sourceId': 'legado-1',
              'sourceName': '笔趣阁',
              'title': '三体',
              'author': '刘慈欣',
              'detailHref': 'https://legado.example/book/1',
            },
            {
              'id': 'b2',
              'sourceId': 'opds-main',
              'sourceName': 'OPDS 主库',
              'title': '三体（epub）',
            },
          ],
          'failedSources': [],
        };
      }
      if (url.path.contains('/api/books/read/chapters')) {
        chapterRequestParams.add(Map<String, String>.from(
          url.queryParameters.map((k, v) => MapEntry(k, v)),
        ));
        return {
          'chapters': [
            {
              'id': 'c1',
              'title': '第一章 疯狂年代',
              'href': 'https://legado.example/book/1/1',
              'order': 0,
            },
          ],
        };
      }
      if (url.path.contains('/api/books/read/chapter')) {
        return {
          'id': 'x',
          'title': '第一章 疯狂年代',
          'href': 'https://legado.example/book/1/1',
          'content': '疯狂年代的第一段。\n\n疯狂年代的第二段。',
        };
      }
      return {};
    });

    await pumpScreen(tester, const BooksScreen());

    expect(visibleText(tester), contains('已接入 1 个 Legado 书源'));

    // 输入并搜索
    await tester.enterText(find.byType(TextField).first, '三体');
    await tester.tap(find.text('搜索'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final text = visibleText(tester);
    expect(text, contains('三体'));
    expect(text, contains('刘慈欣'));
    // OPDS 来源的搜索结果不能出现在列表里（读不了，避免死链）
    expect(text.contains('三体（epub）'), isFalse);

    // 点书进阅读器：自动加载目录并打开第一章
    // （点作者文本而不是书名——书名会先匹配到搜索框里的 EditableText）
    await tester.tap(find.text('刘慈欣'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final readerText = visibleText(tester);
    expect(readerText, contains('第一章 疯狂年代'));
    expect(readerText, contains('疯狂年代的第一段。'));

    // 章节目录必须用搜索结果自带的 detailHref（直连地址）定位，
    // 而不是 bookId（依赖书源规则里的 id 模板，很多源没有）
    expect(chapterRequestParams, isNotEmpty);
    expect(chapterRequestParams.first.containsKey('href'), isTrue,
        reason: '应带 href 定位，实际参数: ${chapterRequestParams.first}');
    expect(chapterRequestParams.first['href'], 'https://legado.example/book/1');
    expect(chapterRequestParams.first.containsKey('bookId'), isFalse);
  });
}

// ---------------------------------------------------------------------------
// HTTP 伪造层：与 ai_chat_stream_test 同一套思路的精简版
// ---------------------------------------------------------------------------

class _FakeHeaders implements HttpHeaders {
  final Map<String, List<String>> _h = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _h[name.toLowerCase()] = ['$value'];
  }

  @override
  void forEach(void Function(String name, List<String> values) f) {
    _h.forEach(f);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeJsonResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeJsonResponse(this.statusCode, this.bytes) {
    _headers.set('content-type', 'application/json');
  }

  final List<int> bytes;

  @override
  final int statusCode;
  final _headers = _FakeHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  int get contentLength => bytes.length;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase =>
      statusCode >= 200 && statusCode < 300 ? 'OK' : 'Error';

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable([bytes]).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.uri, this._respond);

  @override
  final Uri uri;
  final Future<HttpClientResponse> Function() _respond;
  final _headers = _FakeHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final _ in stream) {}
  }

  @override
  Future<HttpClientResponse> close() => _respond();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._router);

  final Future<HttpClientResponse> Function(Uri) _router;

  @override
  bool autoUncompress = true;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeRequest(url, () => _router(url));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _RouterOverrides extends HttpOverrides {
  _RouterOverrides(this._router);

  final Future<HttpClientResponse> Function(Uri) _router;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(_router);
}
