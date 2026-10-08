import 'dart:convert';

/// AI 问片对话角色
enum AiChatRole { user, assistant }

/// 一次工具调用（含参数与执行结果）
///
/// 用于两件事：
/// 1. 界面展示：流式期间实时渲染工具链（哪个在跑、哪个成功/失败、关键参数）；
/// 2. 随 history 回喂：流式结束后固化到 [AiChatMessage.toolCalls]，下次请求
///    服务端（新版工具式模式）会重建 `assistant(tool_calls) → tool → assistant`
///    转录，让模型直接复用此前拿到的数据，避免同一会话重复调用工具。
///
/// 字段与服务端 `HistoryTurn['toolCalls']` 一一对应（`name/key/args/result/ok`）。
class AiToolCall {
  /// 工具名，必须与后端下发的一致（如 `douban_lookup`）
  final String name;

  /// `start` 事件携带的原始参数（可能为 null）
  final dynamic args;

  /// 关键参数摘要（如搜索词「流浪地球」），用于紧凑展示；
  /// 服务端在 `args` 缺失时会用它兜底重建参数（`{query: key}`）
  final String? key;

  /// `start` / `done` / `failed`
  String status;

  /// 执行结果文本（`done` 事件携带）
  String? result;

  /// 执行是否成功（`done` 事件携带；`failed` 时为 false）
  bool? ok;

  AiToolCall({
    required this.name,
    this.args,
    this.key,
    this.status = 'start',
    this.result,
    this.ok,
  });

  /// 是否已执行完（无论成败）
  bool get isFinished => status == 'done' || status == 'failed';

  /// 转换为随 history 回喂服务端的结构
  Map<String, dynamic> toHistoryJson() => {
        'name': name,
        if (args != null) 'args': args,
        if (key != null) 'key': key,
        if (result != null) 'result': result,
        if (ok != null) 'ok': ok,
      };
}

/// 一条 AI 问片对话消息
///
/// [content] 可变：助手的回复是流式增量下发的，界面上会不断往后追加文本。
class AiChatMessage {
  final AiChatRole role;

  /// 消息内容（助手消息在流式响应中会被增量追加）
  String content;
  final DateTime time;

  /// 本条回复执行过的工具调用（流式结束时固化；随 history 回喂）
  final List<AiToolCall> toolCalls;

  /// 较早对话被服务端压缩后写回的摘要（含前缀的完整正文）；
  /// 存在时服务端优先重建摘要而不再重建工具详情，避免上下文重新膨胀。
  final List<String> compressedSummaries;

  AiChatMessage({
    required this.role,
    required this.content,
    DateTime? time,
    List<AiToolCall>? toolCalls,
    List<String>? compressedSummaries,
  })  : time = time ?? DateTime.now(),
        toolCalls = toolCalls ?? [],
        compressedSummaries = compressedSummaries ?? [];

  /// 是否为用户消息
  bool get isUser => role == AiChatRole.user;

  /// 转换为 `POST /api/ai/chat` 所需的 history 结构
  ///
  /// `toolCalls` / `compressedSummaries` 仅在非空时携带：旧模式服务端只取
  /// `role/content`（多余字段被丢弃），新版工具式模式会用它们重建转录。
  Map<String, dynamic> toHistoryJson() => {
        'role': role == AiChatRole.user ? 'user' : 'assistant',
        'content': content,
        if (compressedSummaries.isNotEmpty)
          'compressedSummaries': compressedSummaries,
        if (toolCalls.isNotEmpty)
          'toolCalls': toolCalls.map((t) => t.toHistoryJson()).toList(),
      };
}

/// 一条解析后的 SSE 事件
///
/// 对应后端 `/api/ai/chat` 流式响应中的一行 `data: {...}`：
/// - `{"text":"..."}`：助手回复的增量文本
/// - `{"type":"tool","name":"...","status":"start","args":{...}}`：工具开始（带参数）
/// - `{"type":"tool","name":"...","status":"done","result":"...","ok":true}`：工具完成
/// - `{"type":"tool","name":"...","status":"failed",...}`：工具执行失败
/// - `{"type":"context_compressed","summary":"..."}`：上下文压缩摘要（随本消息回喂）
/// - `[DONE]`：流结束
class AiStreamEvent {
  /// 增量文本（可能为 null）
  final String? text;

  /// 工具名（工具事件时非空）
  final String? toolName;

  /// 工具状态：`start` / `done` / `failed`
  final String? toolStatus;

  /// 工具调用参数（`start` 事件携带，结构由服务端决定）
  final dynamic toolArgs;

  /// 工具执行结果（`done` 事件携带）
  final String? toolResult;

  /// 工具执行是否成功（`done`/`failed` 事件携带）
  final bool? toolOk;

  /// 上下文压缩摘要（`context_compressed` 事件携带）
  final String? compressedSummary;

  /// 是否为 `[DONE]`（流结束）
  final bool done;

  const AiStreamEvent({
    this.text,
    this.toolName,
    this.toolStatus,
    this.toolArgs,
    this.toolResult,
    this.toolOk,
    this.compressedSummary,
    this.done = false,
  });

  /// 是否为工具调用事件
  bool get isTool => toolName != null;

  /// 工具是否正在执行（`done`/`failed` 都是已结束，不能把失败当进行中）
  bool get isToolRunning =>
      isTool && toolStatus != 'done' && toolStatus != 'failed';

  /// 解析 `data:` 后面的原始载荷
  ///
  /// 无法识别（空行、心跳、非法 JSON 等）时返回 null，调用方直接忽略即可。
  static AiStreamEvent? fromPayload(String payload) {
    final trimmed = payload.trim();
    if (trimmed.isEmpty) return null;
    // 结束标记不是 JSON
    if (trimmed == '[DONE]') return const AiStreamEvent(done: true);

    try {
      final decoded = json.decode(trimmed);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);

      // 工具调用事件（新版工具式模式：start 带参数，done 带结果与成败）
      if (map['type'] == 'tool') {
        final result = map['result'];
        return AiStreamEvent(
          toolName: map['name'] as String?,
          toolStatus: map['status'] as String?,
          toolArgs: map['args'],
          toolResult: result is String ? result : null,
          toolOk: map['ok'] is bool ? map['ok'] as bool : null,
        );
      }

      // 上下文压缩事件：摘要固化到本条消息，随 history 回喂时替换工具详情
      if (map['type'] == 'context_compressed') {
        final summary = map['summary'];
        if (summary is String && summary.trim().isNotEmpty) {
          return AiStreamEvent(compressedSummary: summary);
        }
        return null;
      }

      // 增量文本
      final text = map['text'];
      if (text is String) return AiStreamEvent(text: text);

      // 少数错误会以 {"error": "..."} 的形式夹在流里
      final error = map['error'];
      if (error is String && error.trim().isNotEmpty) {
        return AiStreamEvent(text: error.trim());
      }

      return null;
    } catch (_) {
      // 非法 JSON：忽略该行，不影响后续解析
      return null;
    }
  }
}
