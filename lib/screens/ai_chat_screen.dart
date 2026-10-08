import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';

import '../models/ai_message.dart';
import '../models/search_result.dart';
import '../services/ai_service.dart';
import '../services/sse_search_service.dart';
import '../services/theme_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';
import '../widgets/pulsing_dots_indicator.dart';
import '../widgets/windows_title_bar.dart';
import 'player_screen.dart';

/// 一条回复里最多取几个片名候选
///
/// 多个候选只渲染成按钮、**不**并发发起搜索（点哪个才搜哪个），所以这里可以
/// 宽松些；只用来限制按钮行数，避免一条推荐回答刷出十几行点击热区。
const int maxPlayableSourceQueries = 8;

/// 中日韩文字：用来区分「外文片名」与「中文描述句」
final RegExp _hasCjk = RegExp(r'[\u4e00-\u9fff]');

/// 中文疑问/请求类字眼：命中即认定是问句而非片名
final RegExp _cjkQuestionMarkers = RegExp(
  r'什么|怎么|怎样|如何|哪|为什么|多少|是谁|谁演|介绍|推荐|类似|求|'
  r'有没有|想看|叫什么|吗|呢',
);

/// 外文问句里的疑问/泛化词
final RegExp _asciiQuestionMarkers = RegExp(
  r'\b(who|what|which|where|when|why|how|is|are|was|were|do|does|did|'
  r'can|could|movie|film|recommend|similar)\b',
);

/// 纯数字段（「沙丘 2」里的 `2`）
final RegExp _numericSegment = RegExp(r'^[0-9]{1,4}$');

/// 元数据词：出现在联网搜索词里表示「关于某片的信息」，不是片名本身
const Set<String> _metadataWords = {
  '豆瓣', '豆瓣评分', '豆瓣电影', '评分', '影评', '简介', '剧情', '演员', '主演',
  '上映', '票房', '资源', '在线', '在线观看', '在线看', '下载', '预告', '解说',
  '解析', '结局', '彩蛋', '榜单', '排名', '剧照', '台词', '主题曲', '百度百科',
  '4k', '1080p', '720p', 'hd', '蓝光', '高清', '国语', '粤语', '中字', '双语',
  '完整版', '免费', 'top', 'imdb', 'wiki',
};

/// 书名号/引号配对表，用于判断「整词是否被包裹」
const Map<String, String> _wrapperPairs = {
  '《': '》',
  '「': '」',
  '【': '】',
  '“': '”',
  '"': '"',
  "'": "'",
};

/// 整个词是否被书名号/引号包裹（模型显式标注「这是片名」的信号）
bool _isWholeWrapped(String text) {
  if (text.length < 2) return false;
  final close = _wrapperPairs[text[0]];
  return close != null && text.endsWith(close);
}

/// 搜索词闸门：判断一段自由文本「像不像片名」，像就返回可用的搜索词
///
/// 影片源检索是跨采集源的关键词标题匹配，拿剧情描述去搜必然空手而归——
/// 实测「车祸失忆 寻找妻子」在 73 个源上返回 0 条结果、白等 9 秒。所以要在
/// 发起搜索前先过这道闸门：不像片名的词一律不发搜索，改请用户输入片名。
///
/// [trusted] 为 true 表示来源已明确声明这是片名（书名号 / 引号包裹）：此时
/// 只校验长度与换行——《谁先爱上他的》这类含疑问字的真片名不能被误杀。
String? normalizePlayableSourceQuery(String raw, {bool trusted = false}) {
  var text = raw.trim();
  if (_isWholeWrapped(text)) {
    text = text.substring(1, text.length - 1).trim();
    trusted = true;
  }
  if (text.isEmpty || text.contains('\n')) return null;

  // 已被明确标注为片名：只做长度兜底
  if (trusted) return text.length <= 40 ? text : null;

  // 问号：中文英文都一样，是问句
  if (RegExp(r'[?？]').hasMatch(text)) return null;

  // 纯外文片名：空格是片名的一部分（The Shawshank Redemption），不按空格拆词
  if (!_hasCjk.hasMatch(text)) {
    if (_asciiQuestionMarkers.hasMatch(text.toLowerCase())) return null;
    return text.length <= 60 ? text : null;
  }

  if (_cjkQuestionMarkers.hasMatch(text)) return null;
  if (text.length > 20) return null;
  if (_metadataWords.contains(text.toLowerCase())) return null;

  // 带空格的自由词：先剥掉元数据词与续集编号，只剩一段才当片名。
  // 剩多段说明是「车祸失忆 寻找妻子」这类剧情描述，闸门在这里挡下。
  if (RegExp(r'\s').hasMatch(text)) {
    final kept = <String>[];
    final segments = text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
    for (final segment in segments) {
      if (_numericSegment.hasMatch(segment)) {
        // 「沙丘 2」→「沙丘2」：中文采集源的续集标题就是这么写的
        if (kept.isNotEmpty) kept[kept.length - 1] = kept.last + segment;
        continue;
      }
      if (_metadataWords.contains(segment.toLowerCase())) continue;
      kept.add(segment);
    }
    if (kept.length != 1) return null;
    text = kept.first;
  }

  return text.length >= 2 ? text : null;
}

/// 标题类工具的结果里**明确显示什么都没查到**（`{}` / `[]`）
///
/// 实测：模型会拿剧情描述或类型词去试查（`douban_lookup(query: "记忆")`、
/// `query: "失忆 寻找妻子 车祸"`），豆瓣搜索接口回的就是空对象 `{}`。这类
/// 查询词只是模型的猜测，不能当片名去搜影片源——否则会拿「记忆」搜出一堆
/// 无关片子。反过来，查到了数据说明模型确实定位到了一部片。
///
/// 结果缺失或不是 JSON 时返回 false（无法判断，交回搜索词闸门决定）。
bool _toolResultEmpty(dynamic result) {
  if (result is! String) return false;
  final text = result.trim();
  if (text.isEmpty) return false;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return decoded.isEmpty;
    if (decoded is List) return decoded.isEmpty;
    return false;
  } catch (_) {
    return false;
  }
}

/// 提取回复里所有「可播放影片源」的片名候选（去重、按可信度排序、限量）
///
/// 与旧版最大的区别是**复数**：模型推荐片单时一条回复往往给出十几个片名，旧实现
/// 用 `firstMatch` 只取第一个，其余全成了死文本——实测「推荐几部高分科幻片」的
/// 回复里，客户端只搜了 1 部。
///
/// 优先级（越靠前越像片名）：
/// 1. 加粗编号榜单项里的片名（`**1. 星际穿越（2014）｜9.4 分**`）——这是模型
///    真正按序推荐给用户的片单，实测主推的 5 部全在这里；
/// 2. 标题类工具（豆瓣/TMDB/站内搜索）的 `query` 参数——模型确实按这些词查过
///    片，但仍要过闸门（模型也会往这里塞「车祸失忆 寻找妻子」这类剧情描述）；
/// 3. 回复里的《片名》/「片名」——模型显式标注，全部取用；
/// 4. `web_search` 的 query——必须过闸门才采用。
///
/// 调用方约定：只提取到 1 个就直接自动搜；多个则渲染成按钮让用户点选。
List<String> extractPlayableSourceQueries({
  required String reply,
  required List<AiToolCall> toolChain,
}) {
  final titles = <String>[];

  void add(String? raw, {bool trusted = false}) {
    if (raw == null || titles.length >= maxPlayableSourceQueries) return;
    final title = normalizePlayableSourceQuery(raw, trusted: trusted);
    if (title == null || titles.contains(title)) return;
    titles.add(title);
  }

  // 1) 加粗编号榜单项：`**1. 星际穿越（2014）｜9.4 分**`
  //
  // 为什么单独认这一种写法：实测模型写「高分片单」时会用加粗编号行做主推，
  // 而《片名》只出现在结尾的补充说明里（那次主推的 5 部一个书名号都没有）。
  // 只认「编号 + 书名号/竖线」两种结尾信号，避免把 `**说明：**`、
  // `**硬核烧脑向**（《2012》）` 这类加粗小标题误当片名。
  for (final match in RegExp(
    r'\*\*\s*\d+[.、]\s*([^*（(｜|\n]{1,24}?)\s*(?=[（(]\s*\d{4}|[｜|])',
  ).allMatches(reply)) {
    // 「机器人总动员 / WALL·E」这类中外双名只取前一半：采集源里中文名匹配率更高
    add(match.group(1)?.split('/').first);
  }

  // 2) 标题类工具的 query 参数
  const titleTools = {
    'douban_lookup',
    'tmdb_lookup',
    'search_videos',
    'search',
  };
  for (final call in toolChain) {
    if (!titleTools.contains(call.name)) continue;
    final args = call.args;
    if (args is! Map) continue;
    // 查了但明确什么都没查到（`{}` / `[]`）的查询词不算片名
    if (call.ok == false || _toolResultEmpty(call.result)) continue;
    add(args['query']?.toString());
  }

  // 3) 书名号 / 引号里的片名：模型显式标注为片名，不受闸门限制
  for (final match in RegExp(r'《([^》]{1,40})》').allMatches(reply)) {
    add(match.group(1), trusted: true);
  }
  for (final match in RegExp(r'「([^」]{1,40})」').allMatches(reply)) {
    add(match.group(1), trusted: true);
  }

  // 4) 联网搜索词兜底
  for (final call in toolChain) {
    if (call.name != 'web_search') continue;
    final args = call.args;
    if (args is! Map) continue;
    add(args['query']?.toString());
  }

  return titles;
}

/// AI 问片：与后端 `/api/ai/chat` 对话的流式聊天页
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  /// 测试接缝：替换「点影片源卡片 → 进播放器」的跳转动作。
  ///
  /// [PlayerScreen] 内部依赖 media_kit（本机需装 libmpv），单测环境构建
  /// 不了；测试注入一个只记录参数的空实现，既能断言跳转参数，
  /// 又不会真的去初始化播放器。
  @visibleForTesting
  static void Function(
    BuildContext context,
    SearchResult result,
    String stitle,
    String stype,
  )? sourceResultNavigatorOverride;

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  /// 空会话时的快捷提问
  static const List<String> _suggestions = [
    '推荐几部高分科幻片',
    '《流浪地球》讲什么',
    '本周有什么热门电影',
  ];

  /// 助手消息的最大宽度（桌面/平板固定宽度，手机按屏宽比例）
  static const double _wideBubbleWidth = 680;

  /// 随请求带上的历史消息上限
  static const int _maxHistoryLength = 20;

  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  final List<AiChatMessage> _messages = [];
  StreamSubscription<AiStreamEvent>? _subscription;

  /// 是否正在接收回复
  bool _isStreaming = false;

  /// 工具调用提示文案（如「正在查询豆瓣…」），null 表示当前没有工具在跑
  String? _toolStatus;

  /// 正在执行的工具的关键参数（如搜索词），随 [_toolStatus] 一起显示
  String? _toolStatusKey;

  /// 本次回复的工具链：流式期间渲染在进度行（已完成的步骤），结束时把
  /// 执行完成的条目固化进最后一条助手消息，随后随 history 回喂服务端，
  /// 让模型复用已取到的数据、同一会话不再重复调用工具。
  final List<AiToolCall> _toolChain = [];

  /// 本次回复期间服务端上下文压缩产生的摘要，结束时固化进助手消息
  ///（服务端重建转录时优先于工具详情，避免上下文重新膨胀）。
  final List<String> _compressedSummaries = [];

  /// 本次回复已经等待的秒数（流式期间每秒刷新）
  int _elapsedSeconds = 0;

  /// 每次工具完成的累计次数，用于「无正文」时的兜底说明
  int _toolCallCount = 0;

  /// 正文增量合并计时器：把高频 SSE 事件合并成低频重绘，
  /// 否则一条回答会触发 200+ 次 setState + Markdown 全量重解析，
  /// 在手机上足以让界面看起来「卡住不显示」。
  Timer? _flushTimer;

  /// 秒表计时器
  Timer? _tickTimer;

  /// 是否正在检查后端是否开启 AI
  bool _checkingAvailability = true;
  bool _isAvailable = false;
  String? _unavailableMessage;

  /// 影片源直出：当前进行中的搜索服务（一轮回复对应一次搜索）
  SSESearchService? _sourceSearch;

  /// 影片源搜索的流订阅（结果 / 进度 / 错误）
  final List<StreamSubscription> _sourceSubs = [];

  /// 影片源卡片数量上限：拿满就收线，避免列表过长拖垮首屏
  static const int _maxSourceCards = 12;

  @override
  void initState() {
    super.initState();
    _checkAvailability();
  }

  @override
  void dispose() {
    // 离开页面时取消订阅，后续事件不会再触发 setState
    _subscription?.cancel();
    _subscription = null;
    // 影片源搜索：取消订阅并断开 SSE（内部会清掉 15 秒超时定时器）
    unawaited(_stopSourceSearch());
    _flushTimer?.cancel();
    _flushTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 检查后端是否开启 AI 问片
  Future<void> _checkAvailability() async {
    // 首次由 initState 调用时正在构建，初始状态已就绪，无需再 setState
    if (!_checkingAvailability) {
      setState(() {
        _checkingAvailability = true;
        _unavailableMessage = null;
      });
    }

    final available = await AiService.isAvailable();
    if (!mounted) return;

    setState(() {
      _checkingAvailability = false;
      _isAvailable = available;
      _unavailableMessage = available ? null : '当前服务器未开启 AI 问片功能';
    });
  }

  /// 发送一条消息（[preset] 用于快捷提问直接发送）
  void _sendMessage([String? preset]) {
    if (!mounted || _isStreaming) return;

    final text = (preset ?? _inputController.text).trim();
    if (text.isEmpty) return;

    if (!_isAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_unavailableMessage ?? 'AI 问片功能当前不可用')),
      );
      return;
    }

    // 本次提问之前的历史记录（只带最近若干条，避免请求体无限膨胀）
    final history = _messages.length > _maxHistoryLength
        ? List<AiChatMessage>.from(
            _messages.sublist(_messages.length - _maxHistoryLength))
        : List<AiChatMessage>.from(_messages);

    // 快捷提问时保留输入框里可能存在的草稿
    if (preset == null) {
      _inputController.clear();
    }
    setState(() {
      _messages.add(AiChatMessage(role: AiChatRole.user, content: text));
      // 先占位一条空的助手消息，流式文本会追加到它上面
      _messages.add(AiChatMessage(role: AiChatRole.assistant, content: ''));
      _isStreaming = true;
      _toolStatus = null;
      _toolStatusKey = null;
      _toolChain.clear();
      _compressedSummaries.clear();
      _toolCallCount = 0;
      _elapsedSeconds = 0;
    });
    _startTimers();
    _scrollToBottom();

    // 上一路订阅理论上已经结束，这里再兜底取消一次
    _subscription?.cancel();
    _subscription =
        AiService.streamChat(message: text, history: history).listen(
      _onStreamEvent,
      onError: _onStreamError,
      onDone: _finishStreaming,
      cancelOnError: true,
    );
  }

  /// 启动「流式期间」的两个计时器：
  /// - 秒表：每秒刷新等待时长，让用户知道程序没有卡死
  /// - 正文合并器不需要在这里启动，由 [_scheduleFlush] 按需创建
  void _startTimers() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_isStreaming) return;
      setState(() {
        _elapsedSeconds++;
      });
    });
  }

  /// 高频正文事件的重绘节流
  ///
  /// 后端会把一条回答拆成数百个 `{"text":"..."}` 事件（实测 200+ 个），
  /// 每个都 setState 会让整棵消息列表 + Markdown 反复重解析。
  /// 这里把 100ms 内的增量合并成一次重绘。
  void _scheduleFlush() {
    if (_flushTimer != null) return; // 本周期内已经安排过
    _flushTimer = Timer(const Duration(milliseconds: 100), () {
      _flushTimer = null;
      if (!mounted) return;
      setState(() {});
      _scrollToBottom();
    });
  }

  /// 处理单个 SSE 事件
  void _onStreamEvent(AiStreamEvent event) {
    if (!mounted) return;

    // 工具调用：维护本次回复的工具链（不打断正文渲染）
    if (event.isTool) {
      final label = _toolStatusText(event.toolName, event.toolStatus);
      setState(() {
        if (event.isToolRunning) {
          final key = _toolArgKey(event.toolName, event.toolArgs);
          _toolChain.add(AiToolCall(
            name: event.toolName!,
            args: event.toolArgs,
            key: key,
          ));
          _toolStatus = label;
          _toolStatusKey = key;
        } else {
          // 完成/失败：落到第一条同名的进行中条目；没有 start 的孤立
          // 事件（服务端异常）直接补一条已完成记录
          final failed =
              event.toolStatus == 'failed' || event.toolOk == false;
          final status = failed
              ? 'failed'
              : (event.toolStatus == 'done' ? 'done' : event.toolStatus);
          AiToolCall? item;
          for (final c in _toolChain) {
            if (!c.isFinished && c.name == event.toolName) {
              item = c;
              break;
            }
          }
          if (item != null) {
            item.status = status ?? 'done';
            item.result = event.toolResult;
            item.ok = event.toolOk ?? !failed;
          } else {
            _toolChain.add(AiToolCall(
              name: event.toolName!,
              args: event.toolArgs,
              key: _toolArgKey(event.toolName, event.toolArgs),
              status: status ?? 'done',
              result: event.toolResult,
              ok: event.toolOk ?? !failed,
            ));
          }
          _toolStatus = null;
          _toolStatusKey = null;
          _toolCallCount++;
        }
      });
      _scrollToBottom();
      return;
    }

    // 上下文压缩事件：记录摘要（加前缀标记，与网页端固化格式一致），
    // 流结束时固化进本条助手消息、随 history 回喂
    final summary = event.compressedSummary;
    if (summary != null) {
      _compressedSummaries.add('【较早对话已压缩】\n${summary.trim()}');
      return;
    }

    // 增量正文：先落库再节流重绘，数据不会丢
    final text = event.text;
    if (text != null && text.isNotEmpty) {
      _toolStatus = null;
      _toolStatusKey = null;
      _appendAssistantText(text);
      _scheduleFlush();
    }

    if (event.done) {
      _finishStreaming();
    }
  }

  /// 服务层已兜底，这里只作为最后防线
  void _onStreamError(Object error) {
    if (!mounted) return;
    setState(() {
      _appendAssistantText('请求失败，请稍后重试');
    });
    _finishStreaming();
  }

  /// 结束一次流式回复
  void _finishStreaming() {
    if (!mounted) return;
    // [DONE] 事件与底层流关闭都会走到这里（事件先触发一次、订阅 onDone
    // 再触发一次），必须幂等，否则工具链会重复固化进同一条消息。
    if (!_isStreaming) return;

    // 收尾时把还在等待的重绘立刻落地，避免丢掉最后一小段正文
    _flushTimer?.cancel();
    _flushTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;

    AiChatMessage? finished;
    setState(() {
      _isStreaming = false;
      _toolStatus = null;
      _toolStatusKey = null;

      // 助手没有任何内容时给出兜底提示，避免留下空气泡。
      // 分两种情况：AI 有调用工具但没输出正文（服务端问题），
      // 和完全没有响应（网络/超时），提示要能区分才好排查。
      final last = _messages.isEmpty ? null : _messages.last;
      if (last != null && last.role == AiChatRole.assistant) {
        // 把本次回复的工具链与压缩摘要固化进消息：之后随 history 回喂，
        // 服务端（新版工具式模式）据此重建工具转录，模型可直接复用数据。
        // 只带执行完成的条目，避免把中断的半截调用喂给服务端。
        last.toolCalls.addAll(_toolChain.where((t) => t.isFinished));
        last.compressedSummaries.addAll(_compressedSummaries);

        if (last.content.trim().isEmpty) {
          last.content = _toolCallCount > 0
              ? 'AI 已完成 $_toolCallCount 次工具调用，但没有返回文字回答。'
                  '可能是模型服务异常，请再试一次。'
              : '（未收到回复，请稍后重试）';
        }
        finished = last;
      }
    });

    // 影片源直出：从工具参数/回复里提取片名，直接把可播放源摆到回答下面
    _maybeStartSourceSearch(finished);

    // 重新启用输入框后把焦点还给用户（桌面端支持边等边打字）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (DeviceUtils.isPC()) {
        _inputFocusNode.requestFocus();
      }
    });

    _scrollToBottom();
  }

  /// 追加助手文本（调用方负责包在 setState 里）
  void _appendAssistantText(String text) {
    final last = _messages.isEmpty ? null : _messages.last;
    if (last != null && last.role == AiChatRole.assistant) {
      last.content += text;
    } else {
      _messages.add(AiChatMessage(role: AiChatRole.assistant, content: text));
    }
  }

  /// 工具名 -> 中文提示
  ///
  /// 工具名必须与后端 `/api/ai/chat` 实际下发的名称一致。实测 MoonTVPlus
  /// 会用到：`douban_lookup`、`web_search`、`fetch_page`、`tmdb_lookup`、
  /// `get_user_favorites`、`get_user_recent`、`get_current_time`、`glob`、`bash`
  /// 等。之前只映射了 4 个并不存在的名字，导致所有真实工具都落到 default，
  /// 界面上只剩一句没有信息量的「已完成」。
  ///
  /// 返回值：进行中返回「正在…」，已完成返回「已…」；[status] 为 done 或
  /// failed 时返回的是「完成态」文案（失败由步骤行的红 ✕ 标记，不能再当成
  /// 进行中显示「正在…」）。
  String? _toolStatusText(String? name, String? status) {
    final isDone = status == 'done' || status == 'failed';

    // 工具名 -> (进行中, 已完成)
    const table = <String, List<String>>{
      'search_videos': ['正在搜索影片…', '已搜索影片'],
      'search': ['正在搜索影片…', '已搜索影片'],
      'get_video_detail': ['正在获取影片详情…', '已获取影片详情'],
      'get_detail': ['正在获取影片详情…', '已获取影片详情'],
      'get_hot_movies': ['正在挑选影片…', '已获取热门影片'],
      'get_recommendations': ['正在挑选影片…', '已生成推荐'],
      'douban_lookup': ['正在查询豆瓣…', '已查询豆瓣'],
      'tmdb_lookup': ['正在查询 TMDB…', '已查询 TMDB'],
      'web_search': ['正在联网搜索…', '已联网搜索'],
      'fetch_page': ['正在阅读网页…', '已阅读网页'],
      'get_user_favorites': ['正在读取我的收藏…', '已读取我的收藏'],
      'get_user_recent': ['正在读取观看记录…', '已读取观看记录'],
      'get_current_time': ['正在确认当前时间…', '已确认当前时间'],
      'glob': ['正在检索本地资料…', '已检索本地资料'],
      'grep': ['正在检索本地资料…', '已检索本地资料'],
      'bash': ['正在执行检索命令…', '已执行检索命令'],
    };

    final entry = table[name];
    if (entry != null) return isDone ? entry[1] : entry[0];

    // 未知工具：保留工具名，便于排查，同时避免出现无意义的「已完成」
    if (name == null || name.isEmpty) {
      return isDone ? '已完成一步' : '正在处理…';
    }
    return isDone ? '已完成 $name' : '正在执行 $name…';
  }

  /// 滚动到底部（流式输出时直接跳转，避免动画堆积）
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final double target = _scrollController.position.maxScrollExtent;
      if (_isStreaming) {
        _scrollController.jumpTo(target);
      } else {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 桌面端回车发送、Shift+回车换行
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!DeviceUtils.isPC()) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }

    _sendMessage();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        final isDark = themeService.isDarkMode;
        // 顶栏与输入栏同色，让状态栏 / 手势条区域也保持同一种底色
        final chromeColor = isDark ? const Color(0xFF1e1e1e) : Colors.white;
        final pageColor =
            isDark ? const Color(0xFF121212) : const Color(0xFFf5f5f5);
        return Scaffold(
          backgroundColor: pageColor,
          body: Container(
            color: chromeColor,
            child: SafeArea(
              child: Column(
                children: [
                  // Windows 自定义标题栏（保证窗口可拖拽、可关闭）
                  if (DeviceUtils.isWindows()) const WindowsTitleBar(),
                  _buildHeader(isDark),
                  Expanded(
                    child: Container(
                      color: pageColor,
                      child: _buildBody(isDark),
                    ),
                  ),
                  _buildInputBar(isDark),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 顶部标题栏
  Widget _buildHeader(bool isDark) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark ? const Color(0xFF2a2a2a) : const Color(0xFFe8e8e8),
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            tooltip: '返回',
            icon: const Icon(Icons.arrow_back),
            style: IconButton.styleFrom(
              foregroundColor: isDark ? Colors.white : const Color(0xFF2c3e50),
            ),
          ),
          const SizedBox(width: 4),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: const Color(0xFF27ae60).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.auto_awesome,
              size: 16,
              color: Color(0xFF27ae60),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'AI 问片',
            style: FontUtils.poppins(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : const Color(0xFF2c3e50),
            ),
          ),
        ],
      ),
    );
  }

  /// 主体区域：加载 / 不可用 / 空会话 / 消息列表
  Widget _buildBody(bool isDark) {
    if (_checkingAvailability) return _buildLoadingView(isDark);
    if (!_isAvailable) return _buildUnavailableView(isDark);
    if (_messages.isEmpty) return _buildEmptyView(isDark);
    return _buildMessageList(isDark);
  }

  Widget _buildLoadingView(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF27ae60)),
          ),
          const SizedBox(height: 16),
          Text(
            '正在检查 AI 服务…',
            style: FontUtils.poppins(
              color: isDark ? const Color(0xFFb0b0b0) : const Color(0xFF7f8c8d),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnavailableView(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 64,
              color: isDark ? const Color(0xFF666666) : const Color(0xFF95a5a6),
            ),
            const SizedBox(height: 16),
            Text(
              _unavailableMessage ?? 'AI 问片功能暂不可用',
              textAlign: TextAlign.center,
              style: FontUtils.poppins(
                color:
                    isDark ? const Color(0xFFb0b0b0) : const Color(0xFF7f8c8d),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _checkAvailability,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF27ae60),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(
                '重试',
                style: FontUtils.poppins(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 空会话引导 + 快捷提问
  Widget _buildEmptyView(bool isDark) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFF27ae60).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  size: 36,
                  color: Color(0xFF27ae60),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '有什么想看的？',
                style: FontUtils.poppins(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF2c3e50),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '问我推荐、剧情或热度，我来帮你找片',
                textAlign: TextAlign.center,
                style: FontUtils.poppins(
                  fontSize: 13.5,
                  color: isDark
                      ? const Color(0xFFb0b0b0)
                      : const Color(0xFF7f8c8d),
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: _suggestions
                    .map((text) => _buildSuggestionChip(text, isDark))
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSuggestionChip(String text, bool isDark) {
    return MouseRegion(
      cursor: DeviceUtils.isPC()
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      child: InkWell(
        onTap: _isStreaming ? null : () => _sendMessage(text),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark ? const Color(0xFF2f2f2f) : const Color(0xFFe0e0e0),
            ),
          ),
          child: Text(
            text,
            style: FontUtils.poppins(
              fontSize: 13,
              color: isDark ? const Color(0xFFe8e8e8) : const Color(0xFF2c3e50),
            ),
          ),
        ),
      ),
    );
  }

  /// 消息列表（流式进行中的进度提示作为最后一项插入）
  Widget _buildMessageList(bool isDark) {
    final isWide = DeviceUtils.isTablet(context);
    // 只要还在等待回复就显示进度，而不是只在工具调用期间显示：
    // 否则模型「思考 / 调工具」那段时间界面毫无反馈，看起来就像卡死了。
    final showProgress = _isStreaming;

    return SelectionArea(
      child: ListView.builder(
        controller: _scrollController,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          isWide ? 32 : 12,
          16,
          isWide ? 32 : 12,
          8,
        ),
        itemCount: _messages.length + (showProgress ? 1 : 0),
        itemBuilder: (context, index) {
          if (showProgress && index == _messages.length) {
            return _buildProgressRow(isDark);
          }
          // 正在流式输出的那条消息用纯文本渲染：Markdown 每次增量都要全量
          // 重新解析，在手机上是明显的卡顿来源；回答结束后再切回 Markdown。
          final isTailStreaming =
              showProgress && index == _messages.length - 1;
          return _buildMessageBubble(
            _messages[index],
            isDark,
            isWide,
            plainText: isTailStreaming,
          );
        },
      ),
    );
  }

  Widget _buildMessageBubble(
    AiChatMessage message,
    bool isDark,
    bool isWide, {
    bool plainText = false,
  }) {
    final isUser = message.isUser;
    final double maxWidth =
        isWide ? _wideBubbleWidth : MediaQuery.sizeOf(context).width * 0.78;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser
              ? const Color(0xFF27ae60)
              : (isDark ? const Color(0xFF1e1e1e) : Colors.white),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
          border: isUser
              ? null
              : Border.all(
                  color: isDark
                      ? const Color(0xFF2a2a2a)
                      : const Color(0xFFe8e8e8),
                ),
        ),
        child: isUser
            ? Text(
                message.content,
                style: FontUtils.poppins(
                  fontSize: 14.5,
                  height: 1.5,
                  color: Colors.white,
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.content.isEmpty)
                    // 等待首字时显示跳动的小圆点
                    const SizedBox(
                      width: 54,
                      height: 20,
                      child: PulsingDotsIndicator(),
                    )
                  else if (plainText)
                    // 流式输出中：纯文本，避免每个增量都全量解析 Markdown
                    Text(
                      message.content,
                      style: FontUtils.poppins(
                        fontSize: 14.5,
                        height: 1.6,
                        color: isDark
                            ? const Color(0xFFe8e8e8)
                            : const Color(0xFF2c3e50),
                      ),
                    )
                  else
                    GptMarkdown(
                      message.content,
                      style: FontUtils.poppins(
                        fontSize: 14.5,
                        height: 1.6,
                        color: isDark
                            ? const Color(0xFFe8e8e8)
                            : const Color(0xFF2c3e50),
                      ),
                    ),
                  // 固化后的工具链：本条回复查了哪些数据源，翻看历史时仍在
                  if (message.toolCalls.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _buildToolChainList(
                        message.toolCalls,
                        isDark: isDark,
                      ),
                    ),
                  // 影片源直出：回答完成后自动搜同名可播放源；回复里有多部片
                  // 时列成可点按钮；一个片名都提不到时退化为手动入口
                  if (message.sourceQuery != null ||
                      message.showManualSourceSearch ||
                      message.sourceQueryCandidates.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _buildSourceSection(message, isDark),
                    ),
                ],
              ),
      ),
    );
  }

  /// 决定本条回复要不要发起影片源搜索（回复流结束后调用一次）
  ///
  /// 三种出路：
  /// - 只提到 1 部片 → 直接自动搜，省一次点击（旧行为）；
  /// - 提到多部片（推荐片单）→ **不**并发搜一堆，而是列成可点按钮，点哪个搜哪个；
  /// - 一个片名都没提到 → 挂手动入口，由用户给出片名。
  void _maybeStartSourceSearch(AiChatMessage? target) {
    if (target == null || !mounted || _isStreaming) return;

    final queries = extractPlayableSourceQueries(
      reply: target.content,
      toolChain: target.toolCalls,
    );

    // 回复里没有片名时，退一步看用户自己问的话——例如用户写了
    // 「有《流浪地球》的资源吗」而模型答非所问，仍能把片名捞出来。
    final userText = _precedingUserText(target);
    if (queries.isEmpty && userText != null) {
      queries.addAll(
        extractPlayableSourceQueries(reply: userText, toolChain: const []),
      );
    }

    if (queries.length == 1) {
      unawaited(_startSourceSearch(target, queries.first));
      return;
    }
    if (queries.length > 1) {
      // 多部片：搜索是串行的、每轮十几秒，替用户猜「哪 5 部」既慢又容易猜错，
      // 索性把片名摆出来当按钮——这也是输入成本最低的一条路。
      setState(() {
        target.sourceQueryCandidates
          ..clear()
          ..addAll(queries);
      });
      return;
    }

    if (userText != null && userText.isNotEmpty) {
      setState(() => target.showManualSourceSearch = true);
    }
  }

  /// 取 [target] 之前最近的一条用户消息文本（手动搜索的兜底词）
  String? _precedingUserText(AiChatMessage target) {
    final idx = _messages.indexOf(target);
    for (var i = idx - 1; i >= 0; i--) {
      if (_messages[i].isUser) return _messages[i].content.trim();
    }
    return null;
  }

  /// 发起一轮影片源搜索，结果以卡片形式增量挂到 [target] 消息上
  ///
  /// 与搜索页共用 [SSESearchService]（`/api/search/ws`），但只取前
  /// [_maxSourceCards] 张卡片：各源的结果到达即渲染，拿满就提前收线。
  Future<void> _startSourceSearch(AiChatMessage target, String query) async {
    if (!mounted) return;
    await _stopSourceSearch();
    if (!mounted) return;

    final service = SSESearchService();
    _sourceSearch = service;
    final seen = <String>{};
    final cards = <SearchResult>[];

    setState(() {
      target.sourceQuery = query;
      target.sourceSearchRunning = true;
      target.sourceSearchDone = false;
      target.sourceSearchFailed = false;
      target.sourceProgress = null;
      target.showManualSourceSearch = false;
      target.sourceCards.clear();
    });

    try {
      await service.startSearch(query);
    } catch (_) {
      await _stopSourceSearch();
      if (!mounted) return;
      setState(() {
        target.sourceSearchRunning = false;
        target.sourceSearchDone = true;
        target.sourceSearchFailed = true;
      });
      return;
    }
    if (!mounted) return;

    // 各源结果增量到达：去重后立即上卡片，让用户在搜索没结束时就能点播
    _sourceSubs.add(service.incrementalResultsStream.listen((batch) {
      if (!mounted) return;
      var changed = false;
      for (final result in batch) {
        if (cards.length >= _maxSourceCards) break;
        if (seen.add('${result.source}|${result.id}')) {
          cards.add(result);
          changed = true;
        }
      }
      if (!changed) return;
      setState(() {
        target.sourceCards
          ..clear()
          ..addAll(cards);
      });
      _scrollToBottom();
      if (cards.length >= _maxSourceCards) {
        // 拿满上限就收线：继续等其余源只会让页面一直挂着「搜索中」
        unawaited(_stopSourceSearch().then((_) {
          if (!mounted) return;
          setState(() {
            target.sourceSearchRunning = false;
            target.sourceSearchDone = true;
            target.sourceProgress = null;
          });
        }));
      }
    }));

    // 进度：显示「正在搜的源（已完成/总数）」；isComplete 收尾
    _sourceSubs.add(service.progressStream.listen((progress) {
      if (!mounted) return;
      setState(() {
        if (progress.isComplete) {
          target.sourceSearchRunning = false;
          target.sourceSearchDone = true;
          target.sourceProgress = null;
        } else if (progress.currentSource != null) {
          target.sourceProgress =
              '${progress.currentSource}（${progress.completedSources}/${progress.totalSources}）';
        }
      });
    }));

    // 错误：已有卡片时静默降级（部分源失败不影响其余卡片）；
    // 一张都没有时标记失败，给出「换词重搜」出路。
    _sourceSubs.add(service.errorStream.listen((_) {
      if (!mounted || target.sourceCards.isNotEmpty) return;
      setState(() {
        target.sourceSearchRunning = false;
        target.sourceSearchDone = true;
        target.sourceSearchFailed = true;
        target.sourceProgress = null;
      });
    }));
  }

  /// 停止当前影片源搜索：先退订（不再 setState），再断开 SSE 与超时定时器
  Future<void> _stopSourceSearch() async {
    final subs = List<StreamSubscription>.from(_sourceSubs);
    _sourceSubs.clear();
    final service = _sourceSearch;
    _sourceSearch = null;
    for (final sub in subs) {
      await sub.cancel();
    }
    // 退订之后就没人再改界面了，随后再断开 SSE：每部片都是新建一个
    // SSESearchService，旧连接收尾与新搜索互不影响。
    await service?.stopSearch();
  }

  /// 点击影片源卡片 → 直接进播放器（与搜索页同一套导航参数）
  void _openSourceResult(AiChatMessage message, SearchResult result) {
    final stitle = message.sourceQuery ?? result.title;
    final stype = result.episodes.length > 1 ? 'tv' : 'movie';
    final override = AiChatScreen.sourceResultNavigatorOverride;
    if (override != null) {
      override(context, result, stitle, stype);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PlayerScreen(
          source: result.source,
          id: result.id,
          year: result.year,
          title: result.title,
          stitle: stitle,
          stype: stype,
        ),
      ),
    );
  }

  /// 没搜到结果时换一个词重搜
  Future<void> _requerySourceSearch(AiChatMessage message) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => _SourceQueryDialog(
        title: message.sourceQuery == null ? '输入片名搜源' : '换词重搜',
        initial: message.sourceQuery ?? '',
      ),
    );
    if (!mounted) return;
    final query = (picked ?? '').trim();
    if (query.isEmpty) return;
    await _startSourceSearch(message, query);
  }

  /// 影片源直出区块：正文区块（手动入口/搜索中/卡片/换词重搜）+ 多片名按钮组
  ///
  /// 按钮组挂在正文**下方**且常驻：搜索出结果时列表会自动滚到底，按钮就在
  /// 视野里，用户点一下就能换下一部，不必往回翻。只有一个候选时不会走到这里
  /// （那条路直接自动搜索）。
  Widget _buildSourceSection(AiChatMessage message, bool isDark) {
    final body = _buildSourceBody(message, isDark);
    if (message.sourceQueryCandidates.length < 2) {
      return body ?? const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (body != null) ...[
          body,
          const SizedBox(height: 6),
        ],
        _buildSourceCandidateButtons(message, isDark),
      ],
    );
  }

  /// 回复里提到多部片时的一组可点片名按钮（点哪个就搜哪个）
  Widget _buildSourceCandidateButtons(AiChatMessage message, bool isDark) {
    final muted = isDark ? const Color(0xFF8a8a8a) : const Color(0xFF95a5a6);
    final normal = isDark ? const Color(0xFFe8e8e8) : const Color(0xFF2c3e50);
    final count = message.sourceQueryCandidates.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          message.sourceQuery == null
              ? '🎬 回复里提到 $count 部，点片名搜可播放源'
              : '🎬 换一部：点片名重新搜可播放源',
          style: FontUtils.poppins(fontSize: 12, color: muted),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 2,
          children: [
            for (final title in message.sourceQueryCandidates)
              _buildSourceCandidateButton(
                message,
                title,
                active: message.sourceQuery == title,
                normalColor: normal,
              ),
          ],
        ),
      ],
    );
  }

  /// 单个片名按钮：[active] 表示当前正在展示/已搜过这一部
  Widget _buildSourceCandidateButton(
    AiChatMessage message,
    String title, {
    required bool active,
    required Color normalColor,
  }) {
    const accent = Color(0xFF27ae60);
    return TextButton.icon(
      // 同一部片再点一次没有新信息，按钮置灰避免重复请求
      onPressed:
          active ? null : () => unawaited(_startSourceSearch(message, title)),
      style: TextButton.styleFrom(
        foregroundColor: accent,
        // 置灰态即「当前这一部」：绿底白字
        disabledForegroundColor: Colors.white,
        disabledBackgroundColor: accent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: active ? accent : const Color(0x6627ae60)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      icon: const Icon(Icons.play_arrow_rounded, size: 15),
      label: Text(
        title,
        style: TextStyle(
          fontSize: 12.5,
          color: active ? Colors.white : normalColor,
        ),
      ),
    );
  }

  /// 影片源区块正文：没发起搜索时的手动入口 / 搜索中 / 卡片列表 / 零结果
  ///
  /// 返回 null 表示当前没有东西可展示。
  Widget? _buildSourceBody(AiChatMessage message, bool isDark) {
    final muted = isDark ? const Color(0xFF8a8a8a) : const Color(0xFF95a5a6);
    const accent = Color(0xFF27ae60);

    // 还没发起过搜索：只给「输入片名」入口。
    //
    // 这里**不再**拿原问题直接去搜：能走到这一步就说明回复和用户问句里都提不出
    // 片名，多半是「男主出车祸失忆一直在找妻子」这种剧情描述——关键词检索拿它
    // 搜必然 0 结果（实测 73 个源全空、白等 9 秒）。与其发一个注定失败的请求，
    // 不如直接请用户给片名。
    if (message.sourceQuery == null) {
      if (!message.showManualSourceSearch) return null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search, size: 14, color: muted),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '没识别到片名，影片源需要按片名搜',
                  style: FontUtils.poppins(fontSize: 12, color: muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          TextButton.icon(
            onPressed: () => unawaited(_requerySourceSearch(message)),
            style: TextButton.styleFrom(
              foregroundColor: accent,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.edit, size: 15),
            label: const Text('输入片名搜源', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      );
    }

    // 有结果：标题 + 可播放卡片（点击直接进播放器）
    //
    // 放在「搜索中」之前判断：结果是一条条流回来的，先到先看，
    // 不必干等整个搜索结束（多源聚合常常十几秒）。
    if (message.sourceCards.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text('🎬', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '可播放源 · ${message.sourceQuery}',
                  style: FontUtils.poppins(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color:
                        isDark ? const Color(0xFFe8e8e8) : const Color(0xFF2c3e50),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          for (final result in message.sourceCards)
            _buildSourceCardRow(message, result, isDark),
          if (message.sourceCards.length >= _maxSourceCards)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 4),
              child: Text(
                '已展示前 $_maxSourceCards 个结果',
                style: FontUtils.poppins(fontSize: 11, color: muted),
              ),
            ),
          // 卡片先到先看，搜索还没结束就在下面继续提示
          if (message.sourceSearchRunning)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '继续搜索中…${message.sourceProgress == null ? '' : ' ${message.sourceProgress}'}',
                      style: FontUtils.poppins(fontSize: 11, color: muted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    }

    // 搜索中（还没有任何结果）
    if (message.sourceSearchRunning) {
      final progress = message.sourceProgress;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '正在搜索影片源…${progress == null ? '' : ' $progress'}',
              style: FontUtils.poppins(fontSize: 12, color: muted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    // 没搜到（或搜索失败）：说明 + 换词重搜的出路
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 14, color: muted),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                message.sourceSearchFailed
                    ? '影片源搜索未成功，可能超时或未登录'
                    : '暂时没搜到可播放源',
                style: FontUtils.poppins(fontSize: 12, color: muted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        TextButton(
          onPressed: () => unawaited(_requerySourceSearch(message)),
          style: TextButton.styleFrom(
            foregroundColor: accent,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          child: const Text('换词重搜', style: TextStyle(fontSize: 12.5)),
        ),
      ],
    );
  }

  /// 一张可播放源卡片：海报 + 标题/年份/源/集数，点击进播放器
  Widget _buildSourceCardRow(
    AiChatMessage message,
    SearchResult result,
    bool isDark,
  ) {
    final muted = isDark ? const Color(0xFF8a8a8a) : const Color(0xFF95a5a6);
    final meta = <String>[
      if (result.year.isNotEmpty) result.year,
      if (result.sourceName.isNotEmpty) result.sourceName,
      if (result.episodes.length > 1) '共${result.episodes.length}集',
    ].join(' · ');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openSourceResult(message, result),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 38,
                  height: 54,
                  child: result.poster.isEmpty
                      ? _posterPlaceholder(isDark)
                      : Image.network(
                          result.poster,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              _posterPlaceholder(isDark),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      result.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FontUtils.poppins(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? const Color(0xFFe8e8e8)
                            : const Color(0xFF2c3e50),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      meta.isEmpty ? '点击播放' : meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FontUtils.poppins(fontSize: 11.5, color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.play_circle_fill,
                color: Color(0xFF27ae60),
                size: 26,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _posterPlaceholder(bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF2a2a2a) : const Color(0xFFececec),
      child: Icon(
        Icons.movie,
        size: 18,
        color: isDark ? const Color(0xFF666666) : const Color(0xFFb0b0b0),
      ),
    );
  }

  /// 提取工具调用的关键参数（用于进度提示与步骤行的紧凑展示）
  ///
  /// 与网页端 `AIChatPanel.tsx` 的 `TOOL_KEY_EXTRACTORS` 保持一致：
  /// 搜索类取 `query`，抓网页取 `url`，豆瓣/TMDB 按 id 兜底，TMDB 热榜
  /// 显示「热榜」。取不到时返回 null（只显示工具名提示）。
  static String? _toolArgKey(String? name, dynamic args) {
    if (args is! Map) return null;
    switch (name) {
      case 'web_search':
        final q = args['query']?.toString();
        return (q == null || q.isEmpty) ? null : q;
      case 'fetch_page':
        final url = args['url']?.toString();
        return (url == null || url.isEmpty) ? null : url;
      case 'douban_lookup':
        final q = args['query']?.toString();
        if (q != null && q.isNotEmpty) return q;
        final id = args['id'];
        return id == null ? null : 'ID:$id';
      case 'tmdb_lookup':
        if (args['trending'] == true) return '热榜';
        final q = args['query']?.toString();
        if (q != null && q.isNotEmpty) return q;
        final id = args['id'];
        return id == null ? null : 'ID:$id';
      default:
        return null;
    }
  }

  /// 工具链列表：每行「状态图标 + 中文标签（+ 关键参数）」
  ///
  /// 进度行里只放执行完成的条目（进行中的那条由上方 label 实时显示）；
  /// 助手气泡里放固化后的完整链条，翻看历史时能看到这条回答查过什么。
  Widget _buildToolChainList(
    List<AiToolCall> items, {
    required bool isDark,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 3),
            child: _buildToolChainRow(items[i], isDark: isDark),
          ),
      ],
    );
  }

  /// 工具链单行：状态图标（✓ 绿 / ✕ 红）+ 中文标签（+ 关键参数，超长截断）
  Widget _buildToolChainRow(AiToolCall item, {required bool isDark}) {
    final muted = isDark ? const Color(0xFF8a8a8a) : const Color(0xFF95a5a6);
    const accent = Color(0xFF27ae60);
    const danger = Color(0xFFe74c3c);

    final failed = item.status == 'failed' || item.ok == false;
    final label = _toolStatusText(item.name, item.status);
    final key = (item.key == null || item.key!.isEmpty)
        ? null
        : (item.key!.length > 60 ? '${item.key!.substring(0, 60)}...' : item.key!);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: Center(
            child: Text(
              failed ? '✕' : '✓',
              style: FontUtils.poppins(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: failed ? danger : accent,
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            key == null
                ? (label ?? '已完成 ${item.name}')
                : '${label ?? '已完成 ${item.name}'}  $key',
            overflow: TextOverflow.ellipsis,
            style: FontUtils.poppins(fontSize: 11.5, color: muted),
          ),
        ),
      ],
    );
  }

  /// 流式进行中的进度提示
  ///
  /// 显示三样东西，缺一不可：
  /// 1. 当前正在做什么（工具名映射后的中文，如「正在查询豆瓣…」）
  /// 2. 已经等了多久（秒表）—— 没有它，「正在处理…」看起来和卡死没区别
  /// 3. 最近完成的步骤 —— 证明 AI 确实在推进
  Widget _buildProgressRow(bool isDark) {
    const accent = Color(0xFF27ae60);
    final muted = isDark ? const Color(0xFF8a8a8a) : const Color(0xFF95a5a6);
    final String? runningLabel = _toolStatus;
    final current = runningLabel == null
        ? (_toolChain.isEmpty ? '正在理解你的问题…' : '正在组织回答…')
        : ((_toolStatusKey ?? '').isEmpty
            ? runningLabel
            : '$runningLabel（$_toolStatusKey）');

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    current,
                    style: FontUtils.poppins(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: accent,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '已等待 $_elapsedSeconds 秒',
                  style: FontUtils.poppins(fontSize: 11.5, color: muted),
                ),
              ],
            ),
            // 已完成的工具步骤（进行中的那条由上方 label 实时显示，不重复）
            if (_toolChain.any((t) => t.isFinished))
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 4),
                child: _buildToolChainList(
                  _toolChain.where((t) => t.isFinished).toList(),
                  isDark: isDark,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 底部输入区
  Widget _buildInputBar(bool isDark) {
    final canSend = !_isStreaming && _isAvailable;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF2a2a2a) : const Color(0xFFe8e8e8),
          ),
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                // Enter 发送（桌面端）
                child: Focus(
                  onKeyEvent: _handleKeyEvent,
                  child: TextField(
                    controller: _inputController,
                    focusNode: _inputFocusNode,
                    enabled: !_isStreaming,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    style: FontUtils.poppins(
                      fontSize: 14.5,
                      color: isDark ? Colors.white : const Color(0xFF2c3e50),
                    ),
                    cursorColor: const Color(0xFF27ae60),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText:
                          _isStreaming ? 'AI 正在回复…' : '问我任何影片相关问题…',
                      hintStyle: FontUtils.poppins(
                        fontSize: 14,
                        color: isDark
                            ? const Color(0xFF666666)
                            : const Color(0xFF95a5a6),
                      ),
                      filled: true,
                      fillColor:
                          isDark ? const Color(0xFF2a2a2a) : const Color(0xFFf2f3f5),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(22)),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(22)),
                        borderSide: BorderSide.none,
                      ),
                      disabledBorder: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(22)),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(22)),
                        borderSide:
                            BorderSide(color: Color(0xFF27ae60), width: 1.2),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              MouseRegion(
                cursor: DeviceUtils.isPC() && canSend
                    ? SystemMouseCursors.click
                    : MouseCursor.defer,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: canSend
                        ? const Color(0xFF27ae60)
                        : (isDark
                            ? const Color(0xFF2f2f2f)
                            : const Color(0xFFe0e0e0)),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                    onPressed: canSend ? () => _sendMessage() : null,
                    tooltip: '发送',
                    icon: Icon(
                      Icons.send_rounded,
                      size: 18,
                      color: canSend
                          ? Colors.white
                          : (isDark
                              ? const Color(0xFF666666)
                              : const Color(0xFFa0a0a0)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「输入片名搜源 / 换词重搜」对话框：输入控制器由对话框自己持有
///
/// 不能让调用方在 `showDialog` 返回后立刻 `dispose` 控制器——对话框退场动画
/// 期间 TextField 仍会重建并 addListener，会抛「A TextEditingController was
/// used after being disposed」。控制器跟着 State 一起释放就没有这个时间差。
class _SourceQueryDialog extends StatefulWidget {
  const _SourceQueryDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_SourceQueryDialog> createState() => _SourceQueryDialogState();
}

class _SourceQueryDialogState extends State<_SourceQueryDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '输入片名或关键词'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('搜索'),
        ),
      ],
    );
  }
}
