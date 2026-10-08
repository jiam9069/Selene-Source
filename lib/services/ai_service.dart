import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/ai_message.dart';
import 'backend_service.dart';
import 'user_data_service.dart';

/// AI 问片服务
///
/// 对接 MoonTVPlus 的 `POST {baseUrl}/api/ai/chat`：请求体为 JSON，响应为
/// `text/event-stream` 的 SSE 事件流。
///
/// 该服务只负责协议解析，不会向调用方抛异常：HTTP 状态码异常、网络错误、
/// 超时等情况都会转换成一条带中文提示的 [AiStreamEvent]（且 `done: true`）。
class AiService {
  /// 建立连接（含等待响应头）的超时时间
  static const Duration _connectTimeout = Duration(seconds: 30);

  /// 两个 SSE 事件之间的最长空闲时间，超过则视为连接中断
  static const Duration _idleTimeout = Duration(seconds: 90);

  /// 流式获取助手回复
  ///
  /// [message] 为用户本次输入，[history] 为本次输入之前的历史消息。
  static Stream<AiStreamEvent> streamChat({
    required String message,
    List<AiChatMessage> history = const [],
  }) async* {
    final client = http.Client();
    try {
      final baseUrl = await UserDataService.getServerUrl();
      if (baseUrl == null || baseUrl.trim().isEmpty) {
        yield const AiStreamEvent(text: '服务器地址未配置，请先登录', done: true);
        return;
      }

      final cookies = await UserDataService.getCookies();

      // 与 api_service 保持一致：去掉结尾的 `/` 后拼接路径
      var cleanBaseUrl = baseUrl.trim();
      if (cleanBaseUrl.endsWith('/')) {
        cleanBaseUrl = cleanBaseUrl.substring(0, cleanBaseUrl.length - 1);
      }

      final request = http.Request(
        'POST',
        Uri.parse('$cleanBaseUrl/api/ai/chat'),
      );
      request.headers['Content-Type'] = 'application/json';
      request.headers['Accept'] = 'text/event-stream';
      request.headers['Cache-Control'] = 'no-cache';
      if (cookies != null && cookies.isNotEmpty) {
        request.headers['Cookie'] = cookies;
      }
      // 手动 UTF-8 编码字节，既保证中文正确，也不会改动 Content-Type 头
      request.bodyBytes = Uint8List.fromList(utf8.encode(json.encode({
        'message': message,
        'history': history.map((item) => item.toHistoryJson()).toList(),
      })));

      final response = await client.send(request).timeout(_connectTimeout);

      if (response.statusCode != 200) {
        // 错误响应体通常很小，可以直接读取后解析 {"error": "..."}
        final body = await response.stream.bytesToString();
        yield AiStreamEvent(
          text: _errorMessageFor(response.statusCode, body),
          done: true,
        );
        return;
      }

      // SSE 行可能被切分到多个 chunk 中，必须先缓冲再按 `\n` 切分；
      // utf8.decoder 是流式解码器，会自动处理跨 chunk 的多字节字符。
      const decoder = Utf8Decoder(allowMalformed: true);
      var buffer = '';

      await for (final chunk
          in response.stream.timeout(_idleTimeout).transform(decoder)) {
        buffer += chunk;
        var newlineIndex = buffer.indexOf('\n');
        while (newlineIndex != -1) {
          final line = buffer.substring(0, newlineIndex);
          buffer = buffer.substring(newlineIndex + 1);

          final event = _parseLine(line);
          if (event != null) {
            yield event;
            if (event.done) return;
          }
          newlineIndex = buffer.indexOf('\n');
        }
      }

      // 服务端可能没有以换行结尾，处理缓冲区里的最后一行
      final tailEvent = _parseLine(buffer);
      if (tailEvent != null) {
        yield tailEvent;
        if (tailEvent.done) return;
      }

      // 没有收到 [DONE] 但连接已关闭，补一个结束事件
      yield const AiStreamEvent(done: true);
    } on TimeoutException {
      yield const AiStreamEvent(text: 'AI 响应超时，请稍后重试', done: true);
    } catch (_) {
      yield const AiStreamEvent(text: '网络连接失败，请检查网络后重试', done: true);
    } finally {
      client.close();
    }
  }

  /// AI 问片是否可用（后端 server-config 中开启了 AIEnabled）
  static Future<bool> isAvailable() async {
    try {
      final config = await BackendService.getServerConfig();
      return config?.aiEnabled ?? false;
    } catch (_) {
      // 拿不到配置时按不可用处理，避免把用户带进一个必然失败的页面
      return false;
    }
  }

  /// 解析单行 SSE，非 `data:` 行返回 null
  static AiStreamEvent? _parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('data:')) return null;
    // 兼容 `data:{}` 与 `data: {}` 两种写法
    return AiStreamEvent.fromPayload(trimmed.substring(5));
  }

  /// 根据状态码与响应体生成中文错误提示
  static String _errorMessageFor(int statusCode, String body) {
    switch (statusCode) {
      case 401:
        return '登录已过期，请重新登录';
      case 403:
        return '无权限使用 AI 问片功能';
      case 400:
        return _extractError(body) ?? '请求内容有误，请换个说法再试';
      default:
        return _extractError(body) ?? 'AI 服务请求失败（HTTP $statusCode）';
    }
  }

  /// 从响应体中提取 `error` / `message` 字段
  static String? _extractError(String body) {
    if (body.trim().isEmpty) return null;
    try {
      final decoded = json.decode(body);
      if (decoded is Map) {
        final message = decoded['error'] ?? decoded['message'];
        if (message is String && message.trim().isNotEmpty) {
          return message.trim();
        }
      }
    } catch (_) {
      // 非 JSON 响应体，无法提取
      return null;
    }
    return null;
  }
}
