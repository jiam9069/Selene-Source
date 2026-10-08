import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/server_config.dart';
import 'user_data_service.dart';

/// 后端能力探测与令牌维护
///
/// MoonTVPlus 相对原版 MoonTV v100 有两处影响客户端的关键差异：
/// 1. `GET /api/server-config` 增加了能力开关字段（AI、弹幕、登录方式等），
///    可据此决定是否展示对应入口；
/// 2. 登录 Cookie 中的 access token 只有 4 小时有效期，过期后所有 `/api/*`
///    请求返回 401，需调用 `POST /api/auth/refresh` 换发新 Cookie。
///
/// 本类集中处理这两件事，避免各业务层重复判断。
class BackendService {
  static const Duration _timeout = Duration(seconds: 10);
  static const Duration _cacheTtl = Duration(minutes: 10);

  static ServerConfig? _cached;
  static DateTime? _cachedAt;

  /// 并发的刷新请求共用同一个 Future，避免同时拿着旧 Cookie 重复刷新
  static Future<bool>? _refreshing;

  /// 获取后端配置（带缓存）
  static Future<ServerConfig?> getServerConfig({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        _cached != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl) {
      return _cached;
    }

    final config = await _fetchServerConfig();
    if (config != null) {
      _cached = config;
      _cachedAt = DateTime.now();
    }
    return config;
  }

  /// 后端是否为 MoonTVPlus
  static Future<bool> isMoonTVPlus() async {
    final config = await getServerConfig();
    return config?.isMoonTVPlus ?? false;
  }

  /// 清理缓存（切换服务器或退出登录时调用）
  static void clearCache() {
    _cached = null;
    _cachedAt = null;
  }

  static Future<ServerConfig?> _fetchServerConfig() async {
    try {
      final baseUrl = await UserDataService.getServerUrl();
      if (baseUrl == null || baseUrl.isEmpty) return null;

      final response = await http.get(
        Uri.parse('${_normalizeBaseUrl(baseUrl)}/api/server-config'),
        headers: {'Accept': 'application/json'},
      ).timeout(_timeout);

      if (response.statusCode != 200) return null;

      final decoded = json.decode(response.body);
      if (decoded is! Map<String, dynamic>) return null;

      return ServerConfig.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 使用 Refresh Token 换发新的 access token
  ///
  /// 成功后新的 `auth` Cookie 会被写回本地存储。
  /// 返回 true 表示已拿到可用的新 Cookie。
  static Future<bool> refreshAccessToken() async {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;

    final future = _doRefresh();
    _refreshing = future;
    try {
      return await future;
    } finally {
      _refreshing = null;
    }
  }

  static Future<bool> _doRefresh() async {
    try {
      final baseUrl = await UserDataService.getServerUrl();
      final cookies = await UserDataService.getCookies();
      if (baseUrl == null || baseUrl.isEmpty) return false;
      if (cookies == null || cookies.isEmpty) return false;

      final response = await http.post(
        Uri.parse('${_normalizeBaseUrl(baseUrl)}/api/auth/refresh'),
        headers: {
          'Accept': 'application/json',
          'Cookie': cookies,
        },
      ).timeout(_timeout);

      if (response.statusCode != 200) return false;

      final newCookie = _parseAuthCookie(response);
      if (newCookie == null || newCookie.isEmpty) return false;

      await UserDataService.saveCookies(newCookie);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 从响应头中取出新的 `auth` Cookie
  ///
  /// 注意只在确实带回了 auth 时才更新，避免把其它 Set-Cookie 写坏。
  static String? _parseAuthCookie(http.Response response) {
    final raw = response.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return null;

    // 可能有多条 Set-Cookie，逐条找 auth
    for (final part in raw.split(',')) {
      final cookie = part.split(';').first.trim();
      if (cookie.startsWith('auth=')) {
        return cookie;
      }
    }
    return null;
  }

  static String _normalizeBaseUrl(String baseUrl) {
    var normalized = baseUrl.trim();
    if (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}
