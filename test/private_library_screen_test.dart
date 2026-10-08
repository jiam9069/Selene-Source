/// 私人影库页面渲染测试
///
/// 用真实形状的后端响应驱动真实的 [PrivateLibraryScreen]（伪造 HTTP 层），
/// 验证页面能真正构建出来并渲染出源 / 分类 / 条目，而不只是通过静态分析。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:selene/screens/private_library_screen.dart';
import 'package:selene/services/theme_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// 伪造 HTTP 层
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

class _JsonResponse extends Stream<List<int>> implements HttpClientResponse {
  _JsonResponse(this.statusCode, String body) : _bytes = utf8.encode(body) {
    _headers.set('content-type', 'application/json');
  }

  final List<int> _bytes;
  @override
  final int statusCode;
  final _headers = _FakeHeaders();

  @override
  HttpHeaders get headers => _headers;
  @override
  int get contentLength => -1;
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  bool get persistentConnection => false;
  @override
  String get reasonPhrase => 'OK';

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable([_bytes]).listen(
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
  bool followRedirects = true;
  @override
  bool persistentConnection = true;
  @override
  int contentLength = -1;
  @override
  String get method => 'GET';

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.drain<void>();
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

class _FakeOverrides extends HttpOverrides {
  _FakeOverrides(this._router);

  final Future<HttpClientResponse> Function(Uri) _router;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(_router);
}

// ---------------------------------------------------------------------------
// 真实形状的响应载荷（取自 MoonTVPlus 实际返回）
// ---------------------------------------------------------------------------

const _sources = {
  'sources': [
    {'key': 'net', 'name': 'Hohai公益Emby'},
    {'key': 'net2', 'name': 'ETFLIX Emby'},
  ],
};

const _views = {
  'success': true,
  'views': [
    {'id': '287756', 'name': '1️⃣最新剧集', 'type': 'tvshows'},
    {'id': '294558', 'name': '6️⃣电影', 'type': 'movies'},
  ],
};

const _list = {
  'success': true,
  'list': [
    {
      'id': '467492',
      'title': '《电诈 摇滚 吴哥窟》',
      'poster': 'https://example.com/1.jpg',
      'year': '2026',
      'rating': 0,
      'mediaType': 'movie',
    },
    {
      'id': '463379',
      'title': '【我推的孩子】',
      'poster': 'https://example.com/2.jpg',
      'year': '2023',
      'rating': 8.5,
      'mediaType': 'tv',
    },
  ],
};

/// 收集界面上所有可见文本
String _visibleText(WidgetTester tester) {
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

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({
      'server_url': 'http://fake',
      'cookies': 'auth=x',
      'local_search': false,
      'is_local_mode': false,
    });
  });

  /// 挂载页面；[sources] 为 null 时模拟后端未配置 Emby
  Future<void> mount(
    WidgetTester tester, {
    Map<String, dynamic>? sources,
  }) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    HttpOverrides.global = _FakeOverrides((url) async {
      final path = url.path;
      if (path.contains('/api/emby/sources')) {
        return _JsonResponse(200, json.encode(sources ?? _sources));
      }
      if (path.contains('/api/emby/views')) {
        return _JsonResponse(200, json.encode(_views));
      }
      if (path.contains('/api/emby/list')) {
        return _JsonResponse(200, json.encode(_list));
      }
      // server-config 等其它请求
      return _JsonResponse(
        200,
        json.encode({
          'SiteName': 'MoonTVPlus',
          'Version': '226.1.0',
          'AIEnabled': true,
        }),
      );
    });
    addTearDown(() => HttpOverrides.global = null);

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeService>.value(
        value: ThemeService(),
        child: const MaterialApp(home: PrivateLibraryScreen()),
      ),
    );
    // 等待 源 → 分类 → 列表 三级请求依次完成
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('渲染标题、多源选择器、分类与条目', (tester) async {
    await mount(tester);

    final text = _visibleText(tester);
    expect(text, contains('私人影库'), reason: '页面标题缺失：\n$text');
    expect(text, contains('观看自我收藏的高清视频吧'),
        reason: '副标题应与官方 Web UI 一致：\n$text');

    // 两个源 → 必须出现源选择器
    expect(text, contains('Hohai公益Emby'), reason: '多源时应显示源选择：\n$text');
    expect(text, contains('ETFLIX Emby'), reason: '多源时应显示源选择：\n$text');

    // 分类（视图）标签
    expect(text, contains('1️⃣最新剧集'), reason: '分类标签缺失：\n$text');

    // 条目
    expect(text, contains('《电诈 摇滚 吴哥窟》'), reason: '条目未渲染：\n$text');
    expect(text, contains('【我推的孩子】'), reason: '条目未渲染：\n$text');

    // 类型徽标：mediaType 应转成中文
    expect(text, contains('电影'), reason: '缺少电影徽标：\n$text');
    expect(text, contains('剧集'), reason: '缺少剧集徽标：\n$text');

    // rating=0 视为无评分，不应显示为 0.0；rating=8.5 应显示
    expect(text, contains('8.5'), reason: '有效评分应显示：\n$text');

    expect(tester.takeException(), isNull);
  });

  testWidgets('后端未配置私人影库时显示友好的空状态', (tester) async {
    await mount(tester, sources: {'sources': []});

    final text = _visibleText(tester);
    expect(text, contains('尚未配置私人影库'),
        reason: '未配置时应给出明确说明而不是空白页：\n$text');
    expect(tester.takeException(), isNull);
  });
}
