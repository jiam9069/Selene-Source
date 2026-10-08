/// AI 问片流式渲染回归测试
///
/// 背景：用户反馈「AI 问片提示已完成，但没看到任何信息」。实测后端 SSE 正常
/// （正文从第 1 个事件就开始下发），问题出在客户端渲染层，本测试锁定三件事：
///
/// 1. 真实工具名（`douban_lookup` 等）必须映射成有意义的中文提示，
///    而不是所有工具都落到 default 变成没有信息量的「已完成」。
/// 2. 流式期间必须有可见的进度反馈（当前步骤 + 已等待秒数），
///    否则模型思考的那几十秒界面看起来和卡死一样。
/// 3. 正文必须真的被渲染出来，且结束后不能误报「未收到回复」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:selene/screens/ai_chat_screen.dart';
import 'package:selene/services/theme_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// 伪造 HTTP 层：让 AiService 的 package:http 请求走我们可控的响应流
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

/// 由测试代码手工推送数据的响应体，用于精确控制「流式」节奏
class _ControlledResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final StreamController<List<int>> _ctrl = StreamController<List<int>>();

  @override
  final int statusCode = 200;
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

  /// 推送一段 SSE 文本
  void emit(String text) {
    if (!_ctrl.isClosed) _ctrl.add(utf8.encode(text));
  }

  Future<void> finish() async {
    if (!_ctrl.isClosed) await _ctrl.close();
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _ctrl.stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 一次性响应（用于 /api/server-config 这类小 JSON）
class _JsonResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _JsonResponse(String body)
      : _bytes = utf8.encode(body) {
    _headers.set('content-type', 'application/json');
  }

  final List<int> _bytes;
  @override
  final int statusCode = 200;
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
  String get method => 'POST';

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
// 测试
// ---------------------------------------------------------------------------

/// 收集当前界面上所有 RichText/Text 的纯文本，用于断言「用户到底看到了什么」
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
  late _ControlledResponse aiResponse;

  /// 挂载真实的 AiChatScreen，并把 /api/ai/chat 指向可控响应流
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    HttpOverrides.global = _FakeOverrides((url) async {
      if (url.path.contains('/api/ai/chat')) {
        aiResponse = _ControlledResponse();
        aiResponse.headers
            .set('content-type', 'text/event-stream; charset=utf-8');
        return aiResponse;
      }
      // server-config 等其余请求：声明这是开启了 AI 的 MoonTVPlus
      return _JsonResponse(json.encode({
        'SiteName': 'MoonTVPlus',
        'Version': '226.1.0',
        'AIEnabled': true,
      }));
    });
    addTearDown(() => HttpOverrides.global = null);

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeService>.value(
        value: ThemeService(),
        child: const MaterialApp(home: AiChatScreen()),
      ),
    );
    // 等待可用性检查完成
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// 输入并发送一条消息
  Future<void> send(WidgetTester tester, String message) async {
    final field = find.byType(TextField);
    expect(field, findsWidgets, reason: 'AI 问片页面没有输入框');
    await tester.enterText(field.first, message);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded).first);
    await tester.pump();
  }

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({
      'server_url': 'http://fake',
      'cookies': 'auth=x',
      'local_search': false,
      'is_local_mode': false,
    });
  });

  setUp(() {
    // 每个用例开始前重置为「等待创建」状态
    aiResponse = _ControlledResponse();
  });

  tearDown(() async {
    await aiResponse.finish();
  });

  testWidgets('真实工具名映射成有意义的中文，而不是无信息量的「已完成」',
      (tester) async {
    await mount(tester);
    await send(tester, '推荐几部高分科幻片');

    // 后端真实下发的工具名是 douban_lookup，旧代码会显示「正在处理…」
    aiResponse.emit(
      'data: {"type":"tool","name":"douban_lookup","status":"start",'
      '"args":{"category":"科幻"}}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));

    final duringTool = _visibleText(tester);
    expect(
      duringTool,
      contains('正在查询豆瓣'),
      reason: '工具执行中必须显示具体在做什么，实际界面文本：\n$duringTool',
    );

    // 工具完成：旧代码会在这里显示孤零零的「已完成」
    aiResponse.emit(
      'data: {"type":"tool","name":"douban_lookup","status":"done",'
      '"result":"豆瓣数据获取失败或参数不完整。","ok":false}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));

    final afterTool = _visibleText(tester);
    expect(
      afterTool,
      contains('已查询豆瓣'),
      reason: '工具完成后应记录具体步骤，实际界面文本：\n$afterTool',
    );

    await aiResponse.finish();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('流式期间有进度反馈：当前步骤 + 已等待秒数', (tester) async {
    await mount(tester);
    await send(tester, '推荐几部高分科幻片');

    // 一个工具在跑，同时时间流逝
    aiResponse.emit(
      'data: {"type":"tool","name":"web_search","status":"start"}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    final text = _visibleText(tester);
    expect(
      text,
      contains('正在联网搜索'),
      reason: '流式期间必须显示当前步骤，实际界面文本：\n$text',
    );
    expect(
      text,
      contains('已等待'),
      reason: '必须有等待时长，否则界面看起来像卡死，实际界面文本：\n$text',
    );

    await aiResponse.finish();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('正文必须被渲染出来，且结束后不误报「未收到回复」', (tester) async {
    await mount(tester);
    await send(tester, '推荐几部高分科幻片');

    // 模拟真实事件序列：先正文，再工具，再正文，最后 [DONE]
    aiResponse.emit('data: {"text":"我先看看"}\n\n');
    aiResponse.emit(
      'data: {"type":"tool","name":"douban_lookup","status":"start"}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit(
      'data: {"type":"tool","name":"douban_lookup","status":"done",'
      '"result":"ok","ok":true}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit('data: {"text":"推荐《星际穿越》，"}\n\n');
    aiResponse.emit('data: {"text":"硬核太空题材的标杆。"}\n\n');
    await tester.pump(const Duration(milliseconds: 200));
    aiResponse.emit('data: [DONE]\n\n');
    await aiResponse.finish();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final text = _visibleText(tester);
    expect(
      text,
      contains('星际穿越'),
      reason: '流式正文必须渲染到界面上，实际界面文本：\n$text',
    );
    expect(
      text,
      contains('硬核太空题材的标杆。'),
      reason: '最后一段正文不能被丢掉，实际界面文本：\n$text',
    );
    expect(
      text,
      isNot(contains('未收到回复')),
      reason: '已经收到正文，不应误报未收到回复，实际界面文本：\n$text',
    );
    expect(
      text,
      isNot(contains('没有返回文字回答')),
      reason: '已经收到正文，不应误报模型无输出，实际界面文本：\n$text',
    );
  });

  testWidgets('调用了工具但模型没输出正文时，给出可排查的提示而不是空气泡',
      (tester) async {
    await mount(tester);
    await send(tester, '推荐几部高分科幻片');

    aiResponse.emit(
      'data: {"type":"tool","name":"douban_lookup","status":"start"}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit(
      'data: {"type":"tool","name":"douban_lookup","status":"done",'
      '"result":"ok","ok":true}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit('data: [DONE]\n\n');
    await aiResponse.finish();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final text = _visibleText(tester);
    expect(
      text,
      contains('1 次工具调用'),
      reason: '只有工具调用没有正文时，提示应说明发生了什么，实际界面文本：\n$text',
    );
  });
}
