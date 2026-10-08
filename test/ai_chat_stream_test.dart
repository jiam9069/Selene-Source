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
/// 4. 影片源直出：回复带片名时自动发起 /api/search/ws，结果渲染为可点卡片
///    （上限 12 张，点击进播放器）；提取不到片名给手动入口，零结果/失败给
///    「换词重搜」出路。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:selene/models/ai_message.dart';
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
    if (_ctrl.isClosed) return;
    // 注意：不要 await close()。单订阅 StreamController 的 close() future
    // 会等到唯一的订阅者消费完 done 才完成；如果这个响应从未被监听
    // （例如用例没触发影片源搜索，setUp 里预建的那个实例），
    // await close() 会永久挂起。fire-and-forget 关闭即可。
    unawaited(_ctrl.close());
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

/// 记录所有 POST /api/ai/chat 的请求体（按时间顺序），供「history 回喂」断言
final List<String> chatRequestBodies = [];

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.uri, this._respond);

  @override
  final Uri uri;
  final Future<HttpClientResponse> Function() _respond;
  final _headers = _FakeHeaders();
  final List<int> _body = [];

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
    await for (final chunk in stream) {
      _body.addAll(chunk);
    }
    if (uri.path.contains('/api/ai/chat')) {
      chatRequestBodies.add(utf8.decode(_body, allowMalformed: true));
    }
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
  late _ControlledResponse searchResponse;

  /// 记录每次 /api/search/ws 的查询词（按时间顺序），供「影片源直出」断言
  final List<String> searchRequestQueries = [];

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
      // 影片源直出：SSESearchService 走 /api/search/ws 拉增量结果
      if (url.path.contains('/api/search/ws')) {
        searchResponse = _ControlledResponse();
        searchResponse.headers
            .set('content-type', 'text/event-stream; charset=utf-8');
        searchRequestQueries.add(url.queryParameters['q'] ?? '');
        return searchResponse;
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
    searchResponse = _ControlledResponse();
    searchRequestQueries.clear();
    chatRequestBodies.clear();
    // PlayerScreen 依赖 media_kit（本机没有 libmpv），测试里换成只记参数的接缝
    AiChatScreen.sourceResultNavigatorOverride = null;
  });

  tearDown(() async {
    await aiResponse.finish();
    await searchResponse.finish();
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

    // 回复含《星际穿越》会自动发起影片源搜索（15s 超时定时器），
    // 补一个 complete 走正常收线路径撤掉定时器，再卸载页面
    searchResponse.emit(
      'data: {"type":"complete","totalResults":0,"completedSources":0}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
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

  testWidgets('工具链展示关键参数：进行中显示搜索词，完成后固化在气泡里',
      (tester) async {
    await mount(tester);
    await send(tester, '推荐和流浪地球类似的科幻片');

    // start 事件携带 args：进行中要在界面上看到「正在联网搜索」+ 搜索词
    aiResponse.emit(
      'data: {"type":"tool","name":"web_search","status":"start",'
      '"args":{"query":"流浪地球"}}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));

    final during = _visibleText(tester);
    expect(
      during,
      contains('正在联网搜索'),
      reason: '工具执行中应显示具体动作，实际界面文本：\n$during',
    );
    expect(
      during,
      contains('流浪地球'),
      reason: 'start 事件的 args 关键参数应实时展示，实际界面文本：\n$during',
    );

    aiResponse.emit(
      'data: {"type":"tool","name":"web_search","status":"done",'
      '"result":"找到 3 部","ok":true}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit('data: {"text":"推荐《流浪地球》"}\n\n');
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit('data: [DONE]\n\n');
    await aiResponse.finish();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final after = _visibleText(tester);
    expect(
      after,
      contains('已联网搜索'),
      reason: '完成后工具链应固化在气泡里，实际界面文本：\n$after',
    );
    expect(
      after,
      contains('流浪地球'),
      reason: '翻看历史时要能看到这条回答查过什么，实际界面文本：\n$after',
    );

    // 回复含《流浪地球》会自动发起影片源搜索，补 complete 撤掉 15s 定时器再卸载
    searchResponse.emit(
      'data: {"type":"complete","totalResults":0,"completedSources":0}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('工具失败显示红 ✕，且不再被当成进行中', (tester) async {
    await mount(tester);
    await send(tester, '查一下流浪地球的评分');

    aiResponse.emit(
      'data: {"type":"tool","name":"douban_lookup","status":"failed",'
      '"ok":false}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));

    // 失败即结束：进度行不能继续显示「正在查询豆瓣」
    final duringFailed = _visibleText(tester);
    expect(
      duringFailed,
      isNot(contains('正在查询豆瓣')),
      reason: 'failed 事件后不能还当成进行中，实际界面文本：\n$duringFailed',
    );

    aiResponse.emit('data: {"text":"抱歉，查询超时了"}\n\n');
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit('data: [DONE]\n\n');
    await aiResponse.finish();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final after = _visibleText(tester);
    expect(after, contains('✕'), reason: '失败步骤要有红 ✕ 标记：\n$after');
    expect(
      after,
      contains('已查询豆瓣'),
      reason: '失败也走完成态文案（红 ✕ 表达失败），实际界面文本：\n$after',
    );
  });

  testWidgets('回复结束后的工具链与压缩摘要随 history 回喂给服务端',
      (tester) async {
    await mount(tester);
    await send(tester, '上一部高分科幻片');

    aiResponse.emit(
      'data: {"type":"tool","name":"douban_lookup","status":"start",'
      '"args":{"query":"流浪地球"}}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit(
      'data: {"type":"tool","name":"douban_lookup","status":"done",'
      '"result":"《流浪地球》9.6 分","ok":true}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit(
      'data: {"type":"context_compressed","summary":"已压缩 6 条较早消息"}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit('data: {"text":"推荐《流浪地球》"}\n\n');
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit('data: [DONE]\n\n');
    await aiResponse.finish();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(
      chatRequestBodies,
      hasLength(1),
      reason: '第一轮应只发出一次请求',
    );

    // 第二轮请求的 history 必须带上第一轮的工具结果与压缩摘要，
    // 服务端据此重建转录，模型才能复用数据、不重复调用工具
    await send(tester, '再来一部类似的');
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      chatRequestBodies,
      hasLength(2),
      reason: '第二轮应发出第二次请求',
    );
    final body =
        json.decode(chatRequestBodies[1]) as Map<String, dynamic>;
    final history = (body['history'] as List).cast<Map<String, dynamic>>();

    final assistantTurn = history.firstWhere(
      (h) => h['role'] == 'assistant',
      orElse: () => <String, dynamic>{},
    );
    expect(assistantTurn, isNotEmpty, reason: 'history 应含助手回合：$history');

    final toolCalls = (assistantTurn['toolCalls'] as List?)?.cast<Map>();
    expect(toolCalls, isNotNull, reason: '助手回合应回传 toolCalls');
    expect(toolCalls!.single['name'], 'douban_lookup');
    expect(toolCalls.single['args'], {'query': '流浪地球'});
    expect(toolCalls.single['key'], '流浪地球');
    expect(toolCalls.single['result'], contains('流浪地球'));
    expect(toolCalls.single['ok'], isTrue);

    final summaries =
        (assistantTurn['compressedSummaries'] as List?)?.cast<String>();
    expect(summaries, isNotNull, reason: '助手回合应回传 compressedSummaries');
    expect(summaries!.single, startsWith('【较早对话已压缩】'));
    expect(summaries.single, contains('已压缩 6 条较早消息'));

    // 收尾：正常关闭第二轮流式，避免秒表计时器残留在 tearDown 后
    aiResponse.emit('data: [DONE]\n\n');
    await aiResponse.finish();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 第一轮回复含《流浪地球》会自动发起影片源搜索（15s 超时定时器），
    // 补一个 complete 撤掉定时器，再卸载页面
    searchResponse.emit(
      'data: {"type":"complete","totalResults":0,"completedSources":0}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  // ---------------------------------------------------------------------
  // 影片源直出（方案 A）：回复结束后自动搜 /api/search/ws，卡片点击进播放器
  // ---------------------------------------------------------------------

  group('extractPlayableSourceQuery 片名提取', () {
    test('标题类工具的 query 参数优先于书名号', () {
      expect(
        extractPlayableSourceQuery(
          reply: '我查到了《流浪地球》的资料。',
          toolChain: [
            AiToolCall(
              name: 'douban_lookup',
              args: {'query': '流浪地球'},
              status: 'done',
              ok: true,
            ),
          ],
        ),
        '流浪地球',
      );
      expect(
        extractPlayableSourceQuery(
          reply: '资料如下。',
          toolChain: [
            AiToolCall(
              name: 'tmdb_lookup',
              args: {'query': '沙丘2'},
              status: 'done',
              ok: true,
            ),
          ],
        ),
        '沙丘2',
      );
    });

    test('回复里的《片名》《》与「片名」可兜底提取', () {
      expect(
        extractPlayableSourceQuery(
          reply: '推荐《星际穿越》，硬核太空题材的标杆。',
          toolChain: const [],
        ),
        '星际穿越',
      );
      expect(
        extractPlayableSourceQuery(
          reply: '「奥本海默」这部也很不错。',
          toolChain: const [],
        ),
        '奥本海默',
      );
    });

    test('web_search 词过长时不算片名，避免把长句当查询词', () {
      // 短搜索词可以当片名兜底
      expect(
        extractPlayableSourceQuery(
          reply: '结果如下。',
          toolChain: [
            AiToolCall(
              name: 'web_search',
              args: {'query': '流浪地球 豆瓣评分'},
              status: 'done',
              ok: true,
            ),
          ],
        ),
        '流浪地球 豆瓣评分',
      );
      // 超过 20 字的长搜索词不能当片名
      expect(
        extractPlayableSourceQuery(
          reply: '结果如下。',
          toolChain: [
            AiToolCall(
              name: 'web_search',
              args: {
                'query': '2024 年值得一看的高分科幻电影推荐列表有哪些',
              },
              status: 'done',
              ok: true,
            ),
          ],
        ),
        isNull,
      );
    });

    test('提取不到片名时返回 null（走手动搜索入口）', () {
      expect(
        extractPlayableSourceQuery(
          reply: '这个问题我没法直接定位到具体影片。',
          toolChain: const [],
        ),
        isNull,
      );
      // 只有工具名但没有 query 参数，也不应误提取
      expect(
        extractPlayableSourceQuery(
          reply: '查询完成。',
          toolChain: [
            AiToolCall(
              name: 'douban_lookup',
              args: {'category': '科幻'},
              status: 'done',
              ok: true,
            ),
          ],
        ),
        isNull,
      );
    });
  });

  testWidgets('回复带片名时自动搜影片源，卡片点击直接进播放器', (tester) async {
    await mount(tester);
    await send(tester, '有《流浪地球》的资源吗');

    aiResponse.emit('data: {"text":"《流浪地球》可直接观看。"}\n\n');
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit('data: [DONE]\n\n');
    await aiResponse.finish();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(
      searchRequestQueries,
      ['流浪地球'],
      reason: '应按提取的片名自动发起 /api/search/ws 搜索',
    );

    // 搜索进行中：要有明确的进行态提示
    final running = _visibleText(tester);
    expect(
      running,
      contains('正在搜索影片源'),
      reason: '搜索中要有进行态提示，实际界面文本：\n$running',
    );

    // 服务端回一条源结果 + 完成
    searchResponse.emit(
      'data: {"type":"source_result","source":"okzy","sourceName":"OK资源网",'
      '"results":[{"id":"123","title":"流浪地球","poster":"","episodes":[],'
      '"episodes_titles":[],"source":"okzy","source_name":"OK资源网",'
      '"year":"2019"}]}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 100));
    searchResponse.emit(
      'data: {"type":"complete","totalResults":1,"completedSources":1}\n\n',
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final cards = _visibleText(tester);
    expect(
      cards,
      contains('可播放源 · 流浪地球'),
      reason: '卡片区应带搜索词标题，实际界面文本：\n$cards',
    );
    expect(
      cards,
      contains('2019 · OK资源网'),
      reason: '卡片要带年份与源名，实际界面文本：\n$cards',
    );
    expect(
      cards,
      isNot(contains('正在搜索影片源')),
      reason: 'complete 后不能还挂着搜索中，实际界面文本：\n$cards',
    );

    // 点卡片 → 直接进播放器（用接缝断言跳转参数，避开 media_kit）
    final opened = <Map<String, Object?>>[];
    AiChatScreen.sourceResultNavigatorOverride =
        (context, result, stitle, stype) => opened.add(<String, Object?>{
              'source': result.source,
              'id': result.id,
              'year': result.year,
              'title': result.title,
              'stitle': stitle,
              'stype': stype,
            });
    await tester.tap(find.byIcon(Icons.play_circle_fill).first);
    await tester.pump();

    expect(opened, hasLength(1), reason: '点卡片应触发一次播放器跳转');
    expect(opened.single['source'], 'okzy', reason: '应带源标识：$opened');
    expect(opened.single['id'], '123', reason: '应带条目 id：$opened');
    expect(opened.single['title'], '流浪地球', reason: '应带片名：$opened');
    expect(opened.single['year'], '2019', reason: '应带年份：$opened');
    expect(
      opened.single['stitle'],
      '流浪地球',
      reason: '副标题用搜索词，与搜索页一致：$opened',
    );
    expect(
      opened.single['stype'],
      'movie',
      reason: '单集按电影走播放参数：$opened',
    );

    // 卸载问片页，取消一切遗留定时器
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('提取不到片名时给手动入口；零结果时给「换词重搜」出路',
      (tester) async {
    await mount(tester);
    await send(tester, '有什么好看的悬疑片');

    aiResponse.emit('data: {"text":"这个话题我没法直接定位片名。"}\n\n');
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit('data: [DONE]\n\n');
    await aiResponse.finish();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 提取不到片名 → 不自动搜，只给手动入口
    expect(
      searchRequestQueries,
      isEmpty,
      reason: '提取不到片名不应自动发起搜索',
    );
    final manual = _visibleText(tester);
    expect(
      manual,
      contains('搜影片源'),
      reason: '应提供手动搜影片源入口，实际界面文本：\n$manual',
    );

    // 点入口 → 拿上一条用户消息作为搜索词
    await tester.tap(find.text('搜影片源'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      searchRequestQueries,
      ['有什么好看的悬疑片'],
      reason: '手动入口应拿原问题去搜',
    );

    // 服务端回 complete 但一条没有 → 零结果态 + 换词出路
    searchResponse.emit(
      'data: {"type":"complete","totalResults":0,"completedSources":2}\n\n',
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final zero = _visibleText(tester);
    expect(
      zero,
      contains('暂时没搜到可播放源'),
      reason: '零结果要明确说明，实际界面文本：\n$zero',
    );
    expect(
      zero,
      contains('换词重搜'),
      reason: '零结果要给换词出路，实际界面文本：\n$zero',
    );

    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('服务端回无法解析的事件时标记搜索失败并给重试出路', (tester) async {
    await mount(tester);
    await send(tester, '查查播放源');

    aiResponse.emit('data: {"text":"《沙丘》资源正在确认。"}\n\n');
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit('data: [DONE]\n\n');
    await aiResponse.finish();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(searchRequestQueries, ['沙丘']);

    // 服务端下发未知事件类型 → 解析失败 → errorStream → 失败态
    searchResponse.emit('data: {"type":"bogus_event"}\n\n');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final failed = _visibleText(tester);
    expect(
      failed,
      contains('影片源搜索未成功'),
      reason: '搜索失败要有明确状态，实际界面文本：\n$failed',
    );
    expect(
      failed,
      contains('换词重搜'),
      reason: '失败态要给重试出路，实际界面文本：\n$failed',
    );

    // 补一个 complete 收掉 15s 超时定时器（解析失败不会自动断流），再卸载
    searchResponse.emit(
      'data: {"type":"complete","totalResults":0,"completedSources":0}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('卡片最多 12 张：拿满即收线并提示已展示前 12 个结果', (tester) async {
    await mount(tester);
    await send(tester, '把《三体》的源都列出来');

    aiResponse.emit('data: {"text":"正在收集《三体》的可播放源。"}\n\n');
    await tester.pump(const Duration(milliseconds: 50));
    aiResponse.emit('data: [DONE]\n\n');
    await aiResponse.finish();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(searchRequestQueries, ['三体']);

    // 一次回 13 条 → 只应展示 12 张卡片并提前收线
    final results = [
      for (var i = 1; i <= 13; i++)
        '{"id":"$i","title":"三体","poster":"","episodes":[],'
            '"episodes_titles":[],"source":"src","source_name":"测试源",'
            '"year":"2023"}',
    ].join(',');
    searchResponse.emit(
      'data: {"type":"source_result","source":"src","sourceName":"测试源",'
      '"results":[$results]}\n\n',
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(
      find.byIcon(Icons.play_circle_fill),
      findsNWidgets(12),
      reason: '卡片上限应为 12 张',
    );
    final text = _visibleText(tester);
    expect(
      text,
      contains('已展示前 12 个结果'),
      reason: '满额时要说明只展示了前 12 个，实际界面文本：\n$text',
    );
    expect(
      text,
      isNot(contains('正在搜索影片源')),
      reason: '拿满应提前收线，不再挂着搜索中，实际界面文本：\n$text',
    );

    // 补一个 complete 收掉 15s 超时定时器，再卸载
    searchResponse.emit(
      'data: {"type":"complete","totalResults":13,"completedSources":1}\n\n',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
