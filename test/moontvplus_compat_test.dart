import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:selene/models/ai_message.dart';
import 'package:selene/models/live_channel.dart';
import 'package:selene/models/search_resource.dart';
import 'package:selene/models/search_result.dart';
import 'package:selene/models/server_config.dart';
import 'package:selene/models/web_live_source.dart';
import 'package:selene/services/api_service.dart';

/// MoonTVPlus 适配相关的回归测试
///
/// 夹具（fixture）均为在真实 MoonTVPlus v226.1.0 实例上抓取的响应片段，
/// 用于锁定适配层的解析行为，避免上游接口变化时静默失效。
void main() {
  group('ServerConfig 后端识别', () {
    // 真实响应：GET /api/server-config（MoonTVPlus v226.1.0）
    const moonTvPlusConfig = '''
{"SiteName":"MoonTVPlus","StorageType":"kvrocks","Version":"226.1.0",
 "TVModeEnabled":true,"WatchRoom":{"enabled":false,"serverType":"internal"},
 "EnableOfflineDownload":false,"EnableRegistration":false,
 "LoginRequireTurnstile":false,"EnableOIDCLogin":false,"EnableTelegramLogin":false,
 "DanmakuAutoLoadDefault":true,"AIEnabled":true,"AIEnableHomepageEntry":true,
 "AIEnableVideoCardEntry":true,"AIEnablePlayPageEntry":true}
''';

    // 原版 MoonTV v100 的响应只有三个字段
    const moonTvV100Config = '''
{"SiteName":"MoonTV","StorageType":"kvrocks","Version":"100.1.3"}
''';

    test('从真实响应识别出 MoonTVPlus 并读出 AI 开关', () {
      final config = ServerConfig.fromJson(
        json.decode(moonTvPlusConfig) as Map<String, dynamic>,
      );

      expect(config.isMoonTVPlus, isTrue);
      expect(config.version, '226.1.0');
      expect(config.storageType, 'kvrocks');
      expect(config.aiEnabled, isTrue);
      expect(config.aiEnableHomepageEntry, isTrue);
      expect(config.aiFeatureVisible, isTrue);
      expect(config.tvModeEnabled, isTrue);
    });

    test('原版 MoonTV v100 不会被误判为 MoonTVPlus，且 AI 关闭', () {
      final config = ServerConfig.fromJson(
        json.decode(moonTvV100Config) as Map<String, dynamic>,
      );

      expect(config.isMoonTVPlus, isFalse);
      expect(config.version, '100.1.3');
      expect(config.aiEnabled, isFalse);
      // 原版没有能力字段，不应因缺字段而抛异常
      expect(config.aiFeatureVisible, isFalse);
    });

    test('缺少能力字段时按主版本号兜底识别', () {
      final config = ServerConfig.fromJson({
        'SiteName': '自建站点',
        'Version': '226.0.1',
      });

      expect(config.isMoonTVPlus, isTrue);
      expect(config.aiEnabled, isFalse);
    });
  });

  group('SearchResource 本地搜索可用性', () {
    test('普通采集源可用于本地搜索', () {
      final resource = SearchResource.fromJson({
        'key': 'dbzy.tv',
        'name': '🎬豆瓣资源',
        'api': 'https://caiji.dbzy5.com/api.php/provide/vod',
        'detail': 'https://dbzy.tv',
        'from': 'config',
        'disabled': false,
      });

      expect(resource.isSearchable, isTrue);
    });

    test('被禁用的源不参与本地搜索', () {
      final resource = SearchResource.fromJson({
        'key': 'fanmingming',
        'name': '明月直播',
        'api': 'https://example.com/api.php/provide/vod',
        'disabled': true,
      });

      expect(resource.isSearchable, isFalse);
    });

    test('MoonTVPlus 的源脚本条目（无 api 字段）会被跳过', () {
      // /api/search/resources 会在采集源之后追加脚本源：
      // {key, name, script: true}，没有 api 字段。
      // 这类源只能由服务端解析，本地搜索拿不到地址，必须跳过。
      final resource = SearchResource.fromJson({
        'key': 'my-script',
        'name': '我的脚本源',
        'script': true,
      });

      expect(resource.api, isEmpty);
      expect(resource.isSearchable, isFalse);
    });
  });

  group('SearchResult 解析 MoonTVPlus 新增字段', () {
    // 真实响应：GET /api/search/ws 中普通采集源的一条结果
    test('普通采集源结果带 proxyMode=false', () {
      final result = SearchResult.fromJson({
        'id': '82995',
        'title': '流浪汉与天鹅',
        'poster': 'https://img.dytt-tupian.com/upload/vod/20260629-1/f5fce483.jpg',
        'episodes': ['https://vip.dytt-network.com/20260629/36229_3dc5dded/index.m3u8'],
        'episodes_titles': ['HD国语'],
        'source': 'dyttzyapi.com',
        'source_name': '🎬电影天堂',
        'year': '1985',
        'type_name': '剧情片',
        'douban_id': 5672871,
        'proxyMode': false,
      });

      expect(result.proxyMode, isFalse);
      expect(result.episodes, hasLength(1));
      expect(result.toJson()['proxyMode'], isFalse);
    });

    test('开启代理模式的源会被识别', () {
      final result = SearchResult.fromJson({
        'id': '1',
        'title': '示例',
        'episodes': <String>[],
        'source': 'some-source',
        'proxyMode': true,
      });

      expect(result.proxyMode, isTrue);
    });

    test('proxyMode 缺失或为 null 时按 false 处理', () {
      expect(SearchResult.fromJson({'id': '1'}).proxyMode, isFalse);
      expect(
        SearchResult.fromJson({'id': '1', 'proxyMode': null}).proxyMode,
        isFalse,
      );
    });

    // 真实响应：/api/search/ws 中 Emby 源的一条结果（episodes 恒为空）
    test('Emby 搜索结果 episodes 为空 —— 这正是需要回源拉详情的原因', () {
      final result = SearchResult.fromJson({
        'id': '601858',
        'title': '小姐与流浪汉',
        'source': 'emby_net',
        'source_name': 'Hohai公益Emby',
        'episodes': <String>[],
        'episodes_titles': <String>[],
        'year': '1955',
        'type_name': '电影',
        'poster': 'https://emby-npo.hohai.eu.org/emby/Items/601858/Images/Primary',
        'douban_id': 0,
      });

      expect(result.episodes, isEmpty);
      expect(ApiService.isEmbySource(result.source), isTrue);
    });
  });

  group('Emby 源标识解析', () {
    test('单源与多源的源标识都能识别', () {
      expect(ApiService.isEmbySource('emby'), isTrue);
      expect(ApiService.isEmbySource('emby_net'), isTrue);
      expect(ApiService.isEmbySource('emby_net2'), isTrue);
      expect(ApiService.isEmbySource('dyttzyapi.com'), isFalse);
      expect(ApiService.isEmbySource('embed'), isFalse);
    });

    test('embyKey 解析', () {
      expect(ApiService.embyKeyFromSource('emby_net'), 'net');
      expect(ApiService.embyKeyFromSource('emby_net2'), 'net2');
      // 单源时服务端不需要 embyKey
      expect(ApiService.embyKeyFromSource('emby'), isNull);
      expect(ApiService.embyKeyFromSource('dyttzyapi.com'), isNull);
    });
  });

  group('WebLiveSource 网络直播', () {
    test('解析真实网络直播源并生成可回解的 key', () {
      final source = WebLiveSource.fromJson({
        'key': 'web_1791370692058',
        'name': '虎牙英雄联盟赛事',
        'platform': 'huya',
        'roomId': '660000',
        'from': 'custom',
        'disabled': false,
      });

      expect(source.platformLabel, '虎牙');
      expect(source.liveSourceKey, 'weblive|huya|660000');

      // 合并进直播源列表后还能把平台和房间号取回来
      expect(WebLiveSource.isWebLiveKey(source.liveSourceKey), isTrue);
      expect(WebLiveSource.platformFromKey(source.liveSourceKey), 'huya');
      expect(WebLiveSource.roomIdFromKey(source.liveSourceKey), '660000');
    });

    test('普通 M3U 直播源的 key 不会被误判', () {
      expect(WebLiveSource.isWebLiveKey('zbds'), isFalse);
      expect(WebLiveSource.platformFromKey('zbds'), isNull);
      expect(WebLiveSource.roomIdFromKey('moonlive'), isNull);
    });

    test('平台显示名', () {
      expect(WebLiveSource.buildLiveSourceKey('bilibili', '21686237'),
          'weblive|bilibili|21686237');
      expect(
        WebLiveSource.fromJson({'platform': 'bilibili'}).platformLabel,
        'B站',
      );
      expect(WebLiveSource.fromJson({'platform': 'douyin'}).platformLabel,
          '抖音');
    });
  });

  group('LiveChannel 携带播放请求头', () {
    test('网络直播频道带 Cookie，普通频道为空', () {
      final webLive = LiveChannel(
        id: 'weblive|huya|660000',
        tvgId: '',
        name: '虎牙英雄联盟赛事',
        logo: '',
        group: '虎牙英雄联盟赛事',
        url: 'http://host/api/web-live/proxy/proxy.flv?url=x',
        headers: const {'Cookie': 'auth=abc'},
      );

      expect(webLive.headers['Cookie'], 'auth=abc');

      // copyWith 需要保留 headers，否则切换频道会丢掉鉴权
      final copied = webLive.copyWith(name: '改名');
      expect(copied.headers['Cookie'], 'auth=abc');
      expect(copied.name, '改名');

      final plain = LiveChannel(
        id: 'zbds-0',
        tvgId: 'CCTV1',
        name: 'CCTV-1',
        logo: '',
        group: '央视',
        url: 'http://example.com/a.m3u8',
      );
      expect(plain.headers, isEmpty);
    });
  });

  group('AiStreamEvent SSE 载荷解析', () {
    test('解析增量文本（真实响应片段）', () {
      final event = AiStreamEvent.fromPayload('{"text":"！我是 **"}');
      expect(event, isNotNull);
      expect(event!.text, '！我是 **');
      expect(event.done, isFalse);
    });

    test('解析 [DONE]', () {
      final event = AiStreamEvent.fromPayload('[DONE]');
      expect(event?.done, isTrue);
      expect(event?.text, isNull);
    });

    test('解析工具调用事件（真实响应片段）', () {
      final start = AiStreamEvent.fromPayload(
        '{"type":"tool","name":"search_videos","status":"start"}',
      );
      expect(start?.isTool, isTrue);
      expect(start?.toolName, 'search_videos');
      expect(start?.isToolRunning, isTrue);

      final done = AiStreamEvent.fromPayload(
        '{"type":"tool","name":"search_videos","status":"done"}',
      );
      expect(done?.isTool, isTrue);
      expect(done?.isToolRunning, isFalse);
    });

    test('空行、心跳与非 JSON 都要被安全忽略', () {
      expect(AiStreamEvent.fromPayload(''), isNull);
      expect(AiStreamEvent.fromPayload('   '), isNull);
      expect(AiStreamEvent.fromPayload(': keep-alive'), isNull);
      expect(AiStreamEvent.fromPayload('not json'), isNull);
      expect(AiStreamEvent.fromPayload('[1,2,3]'), isNull);
    });

    test('流内错误会当作提示文本展示', () {
      final event = AiStreamEvent.fromPayload('{"error":"AI功能未启用"}');
      expect(event?.text, 'AI功能未启用');
    });

    test('解析工具调用事件的参数与结果（新版工具式模式）', () {
      final start = AiStreamEvent.fromPayload(
        '{"type":"tool","name":"web_search","status":"start",'
        '"args":{"query":"流浪地球"}}',
      );
      expect(start?.isTool, isTrue);
      expect(start?.toolArgs, {'query': '流浪地球'});
      expect(start?.isToolRunning, isTrue, reason: 'start 是进行中');
      expect(start?.toolResult, isNull);

      final done = AiStreamEvent.fromPayload(
        '{"type":"tool","name":"web_search","status":"done",'
        '"result":"找到 3 部","ok":true}',
      );
      expect(done?.toolResult, '找到 3 部');
      expect(done?.toolOk, isTrue);
      expect(done?.isToolRunning, isFalse);

      // 失败事件：不能当成进行中（旧逻辑 status != 'done' 会永远转圈）
      final failed = AiStreamEvent.fromPayload(
        '{"type":"tool","name":"douban_lookup","status":"failed","ok":false}',
      );
      expect(failed?.isTool, isTrue);
      expect(failed?.isToolRunning, isFalse, reason: 'failed 是已结束');
      expect(failed?.toolOk, isFalse);

      // 兼容 done + ok:false（服务端也可能用这种方式表达失败）
      final notOk = AiStreamEvent.fromPayload(
        '{"type":"tool","name":"douban_lookup","status":"done","ok":false}',
      );
      expect(notOk?.isToolRunning, isFalse);
      expect(notOk?.toolOk, isFalse);
    });

    test('解析上下文压缩事件，空摘要忽略', () {
      final event = AiStreamEvent.fromPayload(
        '{"type":"context_compressed","summary":"已压缩 6 条较早消息"}',
      );
      expect(event?.compressedSummary, '已压缩 6 条较早消息');
      expect(event?.text, isNull);
      expect(event?.isTool, isFalse);
      expect(event?.done, isFalse);

      expect(
        AiStreamEvent.fromPayload(
          '{"type":"context_compressed","summary":"  "}',
        ),
        isNull,
        reason: '空白摘要没有信息量，直接忽略',
      );
    });
  });

  group('AiChatMessage 历史结构', () {
    test('role 映射与后端一致', () {
      final user = AiChatMessage(role: AiChatRole.user, content: '你好');
      final assistant = AiChatMessage(role: AiChatRole.assistant, content: '在');

      expect(user.isUser, isTrue);
      expect(user.toHistoryJson(), {'role': 'user', 'content': '你好'});
      expect(assistant.toHistoryJson(), {'role': 'assistant', 'content': '在'});
    });

    test('助手内容是增量追加的可变字段', () {
      final message = AiChatMessage(role: AiChatRole.assistant, content: '');
      message.content += '你好';
      message.content += '，世界';

      expect(message.content, '你好，世界');
    });

    test('toolCalls 与 compressedSummaries 随 history 回喂', () {
      final message =
          AiChatMessage(role: AiChatRole.assistant, content: '推荐《流浪地球》');
      message.toolCalls.add(AiToolCall(
        name: 'douban_lookup',
        args: const {'query': '流浪地球'},
        key: '流浪地球',
        status: 'done',
        result: '《流浪地球》评分 9.6',
        ok: true,
      ));
      message.compressedSummaries.add('【较早对话已压缩】\n摘要正文');

      final historyJson = message.toHistoryJson();
      expect(historyJson['role'], 'assistant');
      expect(historyJson['content'], '推荐《流浪地球》');
      expect(historyJson['toolCalls'], [
        {
          'name': 'douban_lookup',
          'args': {'query': '流浪地球'},
          'key': '流浪地球',
          'result': '《流浪地球》评分 9.6',
          'ok': true,
        },
      ]);
      expect(historyJson['compressedSummaries'], ['【较早对话已压缩】\n摘要正文']);
    });

    test('空链条不产生多余字段（旧模式服务端只认 role/content）', () {
      final message = AiChatMessage(role: AiChatRole.assistant, content: '在');
      expect(message.toolCalls, isEmpty);
      expect(message.compressedSummaries, isEmpty);
      expect(
        message.toHistoryJson().keys.toList(),
        ['role', 'content'],
        reason: '没有工具调用时不得携带 toolCalls/compressedSummaries',
      );

      // null 字段（如无 key 的工具）不写入，避免回喂无意义的空值
      final bare = AiToolCall(name: 'get_current_time', status: 'done', ok: true);
      expect(
        bare.toHistoryJson(),
        {'name': 'get_current_time', 'ok': true},
      );
    });
  });
}
