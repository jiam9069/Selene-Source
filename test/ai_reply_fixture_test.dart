/// 真实模型回复回放测试（P1 多片名按钮 / P2 搜索词闸门）
///
/// 断言用的是**真实实例抓下来的原始回复**（fixture 由 `/api/ai/chat` 的 SSE
/// 事件精简而来，只把超长结果截断，工具链与回复正文逐字保留，抓取脚本与原始
/// 存档见工作区 `实测记录-20261008.md` 与 `实测附件-ai问片/`）。
///
/// 两个 fixture 各锁定一次真实失败：
/// 1. `ai_reply_ranked_list.json`——推荐片单回复。主推的 5 部写在**加粗编号行**
///    里（不是书名号），而模型按剧情描述试查豆瓣时拿到的全是空对象 `{}`。
///    旧实现只看第一个片名/工具词，用户看到 1 组卡片、其余全是死文本。
/// 2. `ai_reply_plot_description.json`——用户描述剧情让 AI 猜片名。模型连试 6 个
///    关键词（`记忆`、`失忆 妻子`…）全部空手而归。旧实现会拿这些词去搜影片源，
///    实测 73 个采集源返回 0 条；新实现一个请求都不发。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:selene/models/ai_message.dart';
import 'package:selene/screens/ai_chat_screen.dart';

/// 把 fixture 里的工具链还原成 [AiToolCall]（与服务端下发顺序一致）
List<AiToolCall> _toolChainOf(Map<String, dynamic> fixture) => [
      for (final raw in fixture['toolCalls'] as List)
        AiToolCall(
          name: (raw as Map)['name'] as String,
          args: raw['args'],
          status: 'done',
          result: raw['result'] as String?,
          ok: raw['ok'] as bool?,
        ),
    ];

Map<String, dynamic> _load(String name) =>
    json.decode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('真实推荐片单回复：按模型的排序给出多部可点片名，不等同于书名号', () {
    final fixture = _load('ai_reply_ranked_list.json');
    final reply = fixture['reply'] as String;

    // 前提核对：这条真实回复里主推的片名确实没有书名号（所以才需要认加粗榜单项）
    expect(
      RegExp(r'\*\*1\. 星际穿越（2014）').hasMatch(reply),
      isTrue,
      reason: 'fixture 应保留真实回复的加粗编号写法',
    );

    final queries = extractPlayableSourceQueries(
      reply: reply,
      toolChain: _toolChainOf(fixture),
    );
    expect(
      queries,
      [
        '星际穿越',
        '盗梦空间',
        '机器人总动员',
        '流浪地球',
        '寻梦环游记',
        '降临',
        '银翼杀手2049',
        '黑客帝国',
      ],
      reason: '前 5 个应严格按模型给的榜单顺序；后面的来自它试查过的书名号片名',
    );

    // 模型试查用的剧情/类型词（豆瓣回空对象 {}）不能被当成片名
    expect(
      queries,
      isNot(contains('科幻')),
      reason: '`douban_lookup(query: 科幻)` 返回 {} —— 是类型词不是片名',
    );
    expect(
      queries,
      isNot(contains('银翼杀手')),
      reason: '`douban_lookup(query: 银翼杀手)` 返回 [] —— 未查到的词不作数',
    );
  });

  test('真实剧情描述提问：闸门挡下全部试探词，一个搜索请求都不发', () {
    final fixture = _load('ai_reply_plot_description.json');
    final queries = extractPlayableSourceQueries(
      reply: fixture['reply'] as String,
      toolChain: _toolChainOf(fixture),
    );

    expect(
      queries,
      isEmpty,
      reason: '6 个试探词要么是剧情描述（带空格/疑问词），要么查到了空结果',
    );

    // 逐个交代为什么被挡下（避免以后改动闸门时以为这里是「本来就空」）
    for (final query in [
      '电影 男主 出车祸 失忆 寻找妻子 剧情',
      '失忆 寻找妻子 车祸',
      '失忆 妻子',
      '豆瓣 电影 男主角车祸失忆 满世界找老婆 剧情 豆瓣',
      '电影 男主 车祸 失忆 找老婆 名字',
    ]) {
      expect(
        normalizePlayableSourceQuery(query),
        isNull,
        reason: '「$query」是剧情描述，不能拿去搜影片源',
      );
    }
    // 「记忆」本身像片名，靠「查了但返回空对象」这条规则挡下
    expect(normalizePlayableSourceQuery('记忆'), '记忆');
    expect(
      extractPlayableSourceQueries(
        reply: '搜索结果不太相关。',
        toolChain: [
          AiToolCall(
            name: 'douban_lookup',
            args: {'query': '记忆'},
            status: 'done',
            ok: true,
            result: '{}',
          ),
        ],
      ),
      isEmpty,
    );
  });
}
