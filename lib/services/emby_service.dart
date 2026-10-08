import 'package:flutter/foundation.dart';

import '../models/emby_models.dart';
import 'api_service.dart';

/// 私人影库（MoonTVPlus Emby）接口服务
///
/// HTTP 层完全复用 [ApiService]：base url 取自 `UserDataService.getServerUrl()`、
/// Cookie 取自 `UserDataService.getCookies()`，并自动处理 401 续期与超时。
/// 因此这里只负责拼路径、解析响应。
///
/// 所有方法都自行捕获异常并返回空结果 / `false`，绝不向调用方抛异常
/// （真实后端单个请求可能耗时 1~30 秒，调用方需要在每次 await 后检查 mounted）。
class EmbyService {
  /// 每页条数（后端固定 20，见 [EmbyPagination.pageSize]）
  static const int pageSize = EmbyPagination.pageSize;

  /// 可用性探测结果缓存：每次 App 运行只探测一次
  static bool? _availabilityCache;

  /// 统一日志前缀（项目 lint 禁止 `print`，这里用 debugPrint）
  static void _log(String message) {
    debugPrint('[EmbyService] $message');
  }

  /// 判断 Emby 私人影库是否可用（`/api/emby/sources` 返回非空）
  ///
  /// 结果会缓存在 [_availabilityCache]，可用 [resetAvailabilityCache] 清除。
  static Future<bool> isAvailable() async {
    final cached = _availabilityCache;
    if (cached != null) return cached;

    final sources = await fetchSources();
    final available = sources.isNotEmpty;
    _availabilityCache = available;
    return available;
  }

  /// 清除可用性缓存（例如退出登录、切换服务器后重新探测）
  static void resetAvailabilityCache() {
    _availabilityCache = null;
  }

  /// 获取所有已配置的 Emby 私人影库源
  ///
  /// 未配置 Emby 时后端返回 `{"sources":[]}`，这里同样返回空列表。
  static Future<List<EmbySource>> fetchSources() async {
    try {
      final response = await ApiService.get<Map<String, dynamic>>(
        '/api/emby/sources',
        fromJson: (data) => data as Map<String, dynamic>,
      );

      if (!response.success || response.data == null) {
        _log('获取私人影库源失败: ${response.message}');
        return const [];
      }

      return EmbySource.listFromResponse(response.data);
    } catch (e) {
      _log('获取私人影库源异常: $e');
      return const [];
    }
  }

  /// 获取指定源的分类（视图）列表
  ///
  /// [sourceKey] 为 [EmbySource.key]，始终显式传给后端 `source` 参数。
  static Future<List<EmbyView>> fetchViews(String sourceKey) async {
    if (sourceKey.isEmpty) return const [];

    try {
      final response = await ApiService.get<Map<String, dynamic>>(
        '/api/emby/views',
        queryParameters: {'source': sourceKey},
        fromJson: (data) => data as Map<String, dynamic>,
      );

      if (!response.success || response.data == null) {
        _log('获取私人影库分类失败: ${response.message}');
        return const [];
      }

      return EmbyView.listFromResponse(response.data);
    } catch (e) {
      _log('获取私人影库分类异常: $e');
      return const [];
    }
  }

  /// 获取指定分类第 [page] 页（1-based）的条目列表
  ///
  /// 海报地址统一经 [ApiService.absolutize] 补全，避免相对地址。
  /// 任何错误（网络、解析、非 2xx）都返回空列表。
  static Future<List<EmbyItem>> fetchList({
    required String sourceKey,
    required String viewId,
    required int page,
  }) async {
    if (sourceKey.isEmpty || viewId.isEmpty || page < 1) return const [];

    try {
      final response = await ApiService.get<Map<String, dynamic>>(
        '/api/emby/list',
        queryParameters: {
          'source': sourceKey,
          'viewId': viewId,
          'page': page.toString(),
        },
        fromJson: (data) => data as Map<String, dynamic>,
      );

      if (!response.success || response.data == null) {
        _log('获取私人影库列表失败: ${response.message}');
        return const [];
      }

      final parsed = EmbyItem.listFromResponse(response.data);
      final items = <EmbyItem>[];
      for (final item in parsed) {
        if (item.poster.isEmpty) {
          items.add(item);
          continue;
        }
        items.add(item.copyWith(poster: await ApiService.absolutize(item.poster)));
      }
      return items;
    } catch (e) {
      _log('获取私人影库列表异常: $e');
      return const [];
    }
  }

  /// 是否为末页（本页条数不足 [pageSize] 即为末页）
  ///
  /// 后端响应没有 total / pageCount 字段，只能靠条数判断。
  static bool isLastPage(int itemCount) =>
      EmbyPagination.isLastPage(itemCount);
}
