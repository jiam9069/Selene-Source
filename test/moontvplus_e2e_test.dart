/// MoonTVPlus 适配的端到端验证（默认跳过）
///
/// 该测试会真实访问一个运行中的 MoonTVPlus 后端，因此不纳入 CI。
/// 在能访问后端的机器上手动开启：
///
/// ```bash
/// MOONTVPLUS_E2E=1 \
/// MOONTVPLUS_BASE_URL=http://127.0.0.1:30000 \
/// MOONTVPLUS_COOKIE='auth=...' \
/// flutter test test/moontvplus_e2e_test.dart
/// ```
///
/// Cookie 可通过登录接口获取：
///
/// ```bash
/// curl -si -X POST "$BASE/api/login" -H 'Content-Type: application/json' \
///   -d '{"username":"...","password":"..."}' | grep -i '^set-cookie:' \
///   | sed 's/^[Ss]et-[Cc]ookie: //' | cut -d';' -f1
/// ```
///
/// 验证内容：后端类型识别、Emby 源搜索结果 → 详情 → 可播放地址，
/// 网络直播源与流解析，以及 AI 问片的流式响应。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:selene/models/ai_message.dart';
import 'package:selene/services/ai_service.dart';
import 'package:selene/services/api_service.dart';
import 'package:selene/services/backend_service.dart';
import 'package:selene/services/emby_service.dart';
import 'package:selene/services/web_live_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final enabled = Platform.environment['MOONTVPLUS_E2E'] == '1';
  final baseUrl = Platform.environment['MOONTVPLUS_BASE_URL'] ??
      'http://127.0.0.1:30000';
  final cookie = Platform.environment['MOONTVPLUS_COOKIE'] ?? '';

  // 未显式开启时整组跳过（CI 中不会执行）
  final skipReason = enabled
      ? (cookie.isEmpty ? '需要设置 MOONTVPLUS_COOKIE' : null)
      : '端到端测试需显式开启：MOONTVPLUS_E2E=1';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // TestWidgetsFlutterBinding 默认会拦截所有 HTTP 请求（一律返回 400），
    // 本测试要访问真实后端，因此必须解除该覆盖。
    HttpOverrides.global = null;
    // 用真实地址与 Cookie 初始化本地存储，让两个 Service 走真实网络
    SharedPreferences.setMockInitialValues({
      'server_url': baseUrl,
      'cookies': cookie,
      'local_search': false,
      'is_local_mode': false,
    });
  });

  test('后端被识别为 MoonTVPlus', () async {
    final config = await BackendService.getServerConfig(forceRefresh: true);

    expect(config, isNotNull, reason: '无法获取 /api/server-config');
    expect(config!.isMoonTVPlus, isTrue,
        reason: '版本 ${config.version} 未被识别为 MoonTVPlus');
    print('站点=${config.siteName} 版本=${config.version} '
        'AI=${config.aiEnabled} 存储=${config.storageType}');
  }, skip: skipReason);

  test('搜索源列表可用于本地搜索', () async {
    final resources = await ApiService.getSearchResources();

    expect(resources, isNotEmpty);
    // MoonTVPlus 会混入源脚本条目，这些必须被判为不可本地搜索
    final usable = resources.where((r) => r.isSearchable).toList();
    expect(usable, isNotEmpty);
    print('搜索源 ${resources.length} 个，可用于本地搜索 ${usable.length} 个');
  }, skip: skipReason);

  test('Emby 源：搜索结果 episodes 为空，但详情能拿到可播放地址', () async {
    // 1. 直接调 /api/search 找出一个 Emby 结果（这里的超时放宽，
    //    仅用于发现测试目标；被测代码路径是第 2 步的 fetchSourceDetail）
    final searchResponse = await http.get(
      Uri.parse('$baseUrl/api/search?q=${Uri.encodeComponent('流浪')}'),
      headers: {'Cookie': cookie, 'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 180));

    expect(searchResponse.statusCode, 200);
    final results =
        (json.decode(searchResponse.body)['results'] as List<dynamic>)
            .cast<Map<String, dynamic>>();

    final embyResults =
        results.where((r) => ApiService.isEmbySource(r['source'] ?? '')).toList();
    if (embyResults.isEmpty) {
      print('该后端没有启用 Emby 源，跳过此用例');
      return;
    }

    final sample = embyResults.first;
    final source = sample['source'] as String;
    final id = sample['id'].toString();
    final sourceName = sample['source_name'] as String?;
    print('命中 Emby 结果：source=$source id=$id title=${sample['title']}');

    // 前提：搜索结果的 episodes 为空（这正是需要回源拉详情的原因）
    expect(sample['episodes'], isEmpty,
        reason: 'Emby 搜索结果应当没有剧集，若上游改变此行为，适配逻辑需要复核');

    // 2. 被测代码路径：详情必须能转换出可播放地址
    final detail = await ApiService.fetchSourceDetail(
      source,
      id,
      sourceName: sourceName,
    );

    expect(detail, isNotEmpty, reason: 'Emby 详情解析失败');
    final item = detail.first;
    expect(item.episodes, isNotEmpty, reason: 'Emby 详情没有解析出任何播放地址');
    expect(item.source, source);
    expect(item.id, id);
    expect(item.episodes.first, startsWith('http'),
        reason: '播放地址必须是绝对地址，实际为 ${item.episodes.first}');
    print('解析到 ${item.episodes.length} 集，首集：${item.episodes.first}');
    if (item.episodesTitles.isNotEmpty) {
      print('首集标题：${item.episodesTitles.first}');
    }
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 5)));

  test('私人影库：源 → 分类 → 列表 → 可播放地址', () async {
    final sources = await EmbyService.fetchSources();
    if (sources.isEmpty) {
      print('该后端没有配置私人影库，跳过此用例');
      return;
    }
    print('私人影库源 ${sources.length} 个：'
        '${sources.map((s) => s.name).join('、')}');

    // 1. 分类
    final source = sources.first;
    final views = await EmbyService.fetchViews(source.key);
    expect(views, isNotEmpty, reason: '「${source.name}」没有返回任何分类');
    print('分类 ${views.length} 个：${views.map((v) => v.name).join('、')}');

    // 2. 列表
    final view = views.first;
    final items = await EmbyService.fetchList(
      sourceKey: source.key,
      viewId: view.id,
      page: 1,
    );
    expect(items, isNotEmpty, reason: '分类「${view.name}」第 1 页为空');
    print('「${view.name}」第 1 页 ${items.length} 条，'
        '首条：${items.first.title}（${items.first.mediaType}）');

    // 海报必须是绝对地址，否则界面上所有封面都会是空白
    final withPoster =
        items.firstWhere((i) => i.poster.isNotEmpty, orElse: () => items.first);
    if (withPoster.poster.isNotEmpty) {
      expect(withPoster.poster, startsWith('http'),
          reason: '海报地址没有被补全为绝对地址：${withPoster.poster}');
    }

    // 3. 播放地址：复用既有详情链路（源标识 emby_<key>）
    final target = items.first;
    final detail = await ApiService.fetchSourceDetail(
      'emby_${source.key}',
      target.id,
      sourceName: source.name,
    );
    expect(detail, isNotEmpty, reason: '私人影库详情解析失败（id=${target.id}）');
    expect(detail.first.episodes, isNotEmpty,
        reason: '私人影库详情没有解析出任何播放地址');
    expect(detail.first.episodes.first, startsWith('http'),
        reason: '播放地址必须是绝对地址');
    print('播放地址：${detail.first.episodes.first}');

    // 4. 分页约定：第 1 页 20 条意味着还有下一页
    expect(EmbyService.isLastPage(items.length), items.length < EmbyService.pageSize,
        reason: '末页判定与「每页 ${EmbyService.pageSize} 条」的约定不一致');
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 5)));

  test('网络直播：源列表可获取且流地址可解析', () async {
    final sources = await WebLiveService.getSources(forceRefresh: true);
    if (sources.isEmpty) {
      print('该后端没有启用网络直播，跳过此用例');
      return;
    }

    print('网络直播源 ${sources.length} 个：'
        '${sources.take(5).map((s) => s.name).join('、')}');

    // 逐个尝试，直到有一个房间真的在直播
    String? resolvedUrl;
    final headers = await WebLiveService.playbackHeaders();
    expect(headers['Cookie'], isNotEmpty,
        reason: '网络直播代理需要登录 Cookie，否则播放会 401');

    for (final source in sources) {
      final stream = await WebLiveService.resolveStream(
        source.platform,
        source.roomId,
        forceRefresh: true,
      );
      if (stream != null && stream.url.startsWith('http')) {
        resolvedUrl = stream.url;
        print('解析成功：${source.name} → ${stream.url}');
        break;
      }
    }

    if (resolvedUrl == null) {
      print('当前没有正在直播的房间（属正常情况），跳过流地址断言');
      return;
    }

    // 确认真实可播放：带上 Cookie 请求该代理地址。
    // 直播流是无限长的，不能读完整个 body，只校验响应头后就断开。
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(resolvedUrl));
      request.headers.addAll(headers);
      final response =
          await client.send(request).timeout(const Duration(seconds: 20));
      print('流地址响应：HTTP ${response.statusCode}');
      expect(response.statusCode, anyOf(200, 206));
      await response.stream.listen(null).cancel();
    } finally {
      client.close();
    }
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 5)));

  test('AI 问片：流式响应能拿到文本', () async {
    if (!await AiService.isAvailable()) {
      print('该后端未开启 AI 问片，跳过此用例');
      return;
    }

    final buffer = StringBuffer();
    var sawDone = false;

    await for (final event in AiService.streamChat(message: '你好')) {
      if (event.text != null) buffer.write(event.text);
      if (event.done) {
        sawDone = true;
        break;
      }
    }

    expect(sawDone, isTrue, reason: '流没有正常结束（未收到 [DONE]）');
    expect(buffer.toString().trim(), isNotEmpty, reason: 'AI 没有返回任何文本');
    print('AI 回复（前 80 字）：'
        '${buffer.toString().replaceAll('\n', ' ').trim().substring(0, 80)}');
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 5)));

  test('AI 对话历史结构被后端接受', () async {
    if (!await AiService.isAvailable()) {
      print('该后端未开启 AI 问片，跳过此用例');
      return;
    }

    final history = <AiChatMessage>[
      AiChatMessage(role: AiChatRole.user, content: '我想看科幻片'),
      AiChatMessage(role: AiChatRole.assistant, content: '好的，你喜欢哪一类？'),
    ];

    final buffer = StringBuffer();
    await for (final event
        in AiService.streamChat(message: '要太空题材的', history: history)) {
      if (event.text != null) buffer.write(event.text);
      if (event.done) break;
    }

    expect(buffer.toString().trim(), isNotEmpty,
        reason: '带历史的请求没有返回内容（history 字段可能不被接受）');
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 5)));
}
