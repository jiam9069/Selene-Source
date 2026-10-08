import 'dart:convert';

/// AI 问片对话角色
enum AiChatRole { user, assistant }

/// 一条 AI 问片对话消息
///
/// [content] 可变：助手的回复是流式增量下发的，界面上会不断往后追加文本。
class AiChatMessage {
  final AiChatRole role;

  /// 消息内容（助手消息在流式响应中会被增量追加）
  String content;
  final DateTime time;

  AiChatMessage({
    required this.role,
    required this.content,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  /// 是否为用户消息
  bool get isUser => role == AiChatRole.user;

  /// 转换为 `POST /api/ai/chat` 所需的 history 结构
  Map<String, String> toHistoryJson() => {
        'role': role == AiChatRole.user ? 'user' : 'assistant',
        'content': content,
      };
}

/// 一条解析后的 SSE 事件
///
/// 对应后端 `/api/ai/chat` 流式响应中的一行 `data: {...}`：
/// - `{"text":"..."}`：助手回复的增量文本
/// - `{"type":"tool","name":"...","status":"start"|"done"}`：工具调用状态
/// - `[DONE]`：流结束
class AiStreamEvent {
  /// 增量文本（可能为 null）
  final String? text;

  /// 工具名（工具事件时非空）
  final String? toolName;

  /// 工具状态：`start` / `done`
  final String? toolStatus;

  /// 是否为 `[DONE]`（流结束）
  final bool done;

  const AiStreamEvent({
    this.text,
    this.toolName,
    this.toolStatus,
    this.done = false,
  });

  /// 是否为工具调用事件
  bool get isTool => toolName != null;

  /// 工具是否正在执行
  bool get isToolRunning => isTool && toolStatus != 'done';

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

      // 工具调用事件
      if (map['type'] == 'tool') {
        return AiStreamEvent(
          toolName: map['name'] as String?,
          toolStatus: map['status'] as String?,
        );
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
