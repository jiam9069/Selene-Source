import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';

import '../models/ai_message.dart';
import '../services/ai_service.dart';
import '../services/theme_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';
import '../widgets/pulsing_dots_indicator.dart';
import '../widgets/windows_title_bar.dart';

/// AI 问片：与后端 `/api/ai/chat` 对话的流式聊天页
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

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

  /// 已经完成的工具步骤（如「已查询豆瓣」），让用户看到 AI 确实在干活。
  /// 只保留最近若干条，避免长时间对话把提示区撑爆。
  final List<String> _steps = [];

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
      _steps.clear();
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

    // 工具调用：更新进度提示（不打断正文渲染）
    if (event.isTool) {
      final label = _toolStatusText(event.toolName, event.toolStatus);
      setState(() {
        if (event.isToolRunning) {
          _toolStatus = label;
        } else {
          _toolStatus = null;
          _toolCallCount++;
          if (label != null && !_steps.contains(label)) {
            _steps.add(label);
            // 只保留最近 4 条，超出丢弃最早的
            if (_steps.length > 4) _steps.removeAt(0);
          }
        }
      });
      _scrollToBottom();
      return;
    }

    // 增量正文：先落库再节流重绘，数据不会丢
    final text = event.text;
    if (text != null && text.isNotEmpty) {
      _toolStatus = null;
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

    // 收尾时把还在等待的重绘立刻落地，避免丢掉最后一小段正文
    _flushTimer?.cancel();
    _flushTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;

    setState(() {
      _isStreaming = false;
      _toolStatus = null;

      // 助手没有任何内容时给出兜底提示，避免留下空气泡。
      // 分两种情况：AI 有调用工具但没输出正文（服务端问题），
      // 和完全没有响应（网络/超时），提示要能区分才好排查。
      final last = _messages.isEmpty ? null : _messages.last;
      if (last != null &&
          last.role == AiChatRole.assistant &&
          last.content.trim().isEmpty) {
        last.content = _toolCallCount > 0
            ? 'AI 已完成 $_toolCallCount 次工具调用，但没有返回文字回答。'
                '可能是模型服务异常，请再试一次。'
            : '（未收到回复，请稍后重试）';
      }
    });

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
  /// 返回值：进行中返回「正在…」，已完成返回「已…」；[status] 为 done 时
  /// 返回的是「完成态」文案，用于步骤记录。
  String? _toolStatusText(String? name, String? status) {
    final isDone = status == 'done';

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
            : (message.content.isEmpty
                // 等待首字时显示跳动的小圆点
                ? const SizedBox(
                    width: 54,
                    height: 20,
                    child: PulsingDotsIndicator(),
                  )
                : (plainText
                    // 流式输出中：纯文本，避免每个增量都全量解析 Markdown
                    ? Text(
                        message.content,
                        style: FontUtils.poppins(
                          fontSize: 14.5,
                          height: 1.6,
                          color: isDark
                              ? const Color(0xFFe8e8e8)
                              : const Color(0xFF2c3e50),
                        ),
                      )
                    : GptMarkdown(
                        message.content,
                        style: FontUtils.poppins(
                          fontSize: 14.5,
                          height: 1.6,
                          color: isDark
                              ? const Color(0xFFe8e8e8)
                              : const Color(0xFF2c3e50),
                        ),
                      ))),
      ),
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
    final current = _toolStatus ??
        (_steps.isEmpty ? '正在理解你的问题…' : '正在组织回答…');

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
            if (_steps.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 4),
                child: Text(
                  _steps.map((step) => '✓ $step').join('   '),
                  style: FontUtils.poppins(fontSize: 11.5, color: muted),
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
