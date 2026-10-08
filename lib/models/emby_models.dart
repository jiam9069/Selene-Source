/// 私人影库（MoonTVPlus Emby）相关数据模型
///
/// 这里的三个模型直接对应 MoonTVPlus 后端 `/api/emby/*` 的响应结构：
/// - `GET /api/emby/sources` → [EmbySource]
/// - `GET /api/emby/views`   → [EmbyView]
/// - `GET /api/emby/list`    → [EmbyItem]
///
/// `fromJson` 一律做防御性解析：字段缺失、类型不符（例如 `rating` 为 int、
/// `year` 为数字、字段为 `null`）时都返回安全默认值，绝不抛异常。
library;

/// 把任意 JSON 值安全地转换为 String
///
/// - `null` / 不支持的复杂类型 → `''`
/// - `num` → 整数值去掉多余的 `.0`（后端 `year` 可能是 `2026` 或 `2026.0`）
String _asString(dynamic value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is num) {
    if (value is double && value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toString();
  }
  if (value is bool) return value.toString();
  return '';
}

/// 把任意 JSON 值安全地转换为 double（兼容 int / double / 数字字符串）
double _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? 0.0;
  return 0.0;
}

/// 把任意 JSON 对象安全地转换为 `Map<String, dynamic>`
Map<String, dynamic>? _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

/// Emby 私人影库源（服务端 `emby.sources` 配置项）
class EmbySource {
  /// 源标识，如 `net` / `net2`，播放时用于拼 `emby_<key>` 源
  final String key;

  /// 源显示名，如 `Hohai公益Emby`
  final String name;

  const EmbySource({
    required this.key,
    required this.name,
  });

  factory EmbySource.fromJson(Map<String, dynamic> json) {
    return EmbySource(
      key: _asString(json['key']),
      name: _asString(json['name']),
    );
  }

  /// 显示用名称（后端没给 name 时退回 key，避免下拉项空白）
  String get displayName => name.isNotEmpty ? name : key;

  /// 从 `/api/emby/sources` 的完整响应体解析源列表
  ///
  /// 结构非预期（缺 `sources`、非数组、条目不是对象）时跳过该条目，
  /// 绝不抛异常。
  static List<EmbySource> listFromResponse(dynamic responseData) {
    final map = _asMap(responseData);
    if (map == null) return const [];

    final rawSources = map['sources'];
    if (rawSources is! List) return const [];

    final sources = <EmbySource>[];
    for (final entry in rawSources) {
      final sourceMap = _asMap(entry);
      if (sourceMap == null) continue;
      final source = EmbySource.fromJson(sourceMap);
      if (source.key.isEmpty) continue;
      sources.add(source);
    }
    return sources;
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
      };
}

/// Emby 媒体库分类（视图），如 `1️⃣最新剧集` / `6️⃣电影`
class EmbyView {
  /// 分类 id，请求列表时作为 `viewId`
  final String id;

  /// 分类名（带 emoji 序号，直接展示）
  final String name;

  /// 分类类型，已见 `tvshows` / `movies`
  final String type;

  const EmbyView({
    required this.id,
    required this.name,
    required this.type,
  });

  factory EmbyView.fromJson(Map<String, dynamic> json) {
    return EmbyView(
      id: _asString(json['id']),
      name: _asString(json['name']),
      type: _asString(json['type']),
    );
  }

  /// 显示用名称（后端没给 name 时给出兜底文案）
  String get displayName => name.isNotEmpty ? name : '未命名分类';

  /// 是否为电影库分类
  bool get isMovieView => type == 'movies';

  /// 从 `/api/emby/views` 的完整响应体解析分类列表
  static List<EmbyView> listFromResponse(dynamic responseData) {
    final map = _asMap(responseData);
    if (map == null) return const [];

    final rawViews = map['views'];
    if (rawViews is! List) return const [];

    final views = <EmbyView>[];
    for (final entry in rawViews) {
      final viewMap = _asMap(entry);
      if (viewMap == null) continue;
      final view = EmbyView.fromJson(viewMap);
      if (view.id.isEmpty) continue;
      views.add(view);
    }
    return views;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
      };
}

/// Emby 媒体条目（列表页的一张海报）
class EmbyItem {
  /// 条目 id，播放时作为 `id` 传给 PlayerScreen
  final String id;

  final String title;

  /// 海报地址，通常是绝对 https 地址，但仍需经 `ApiService.absolutize` 兜底
  final String poster;

  /// 年份，统一为 String（后端可能返回数字）
  final String year;

  /// 评分，兼容 int / double（后端常见 `0`）
  final double rating;

  /// 媒体类型：`movie`（电影）或 `tv`（剧集）
  final String mediaType;

  const EmbyItem({
    required this.id,
    required this.title,
    required this.poster,
    required this.year,
    required this.rating,
    required this.mediaType,
  });

  factory EmbyItem.fromJson(Map<String, dynamic> json) {
    final rawType = _asString(json['mediaType']).toLowerCase();
    final mediaType = (rawType == 'tv' || rawType == 'series')
        ? 'tv'
        : (rawType.isEmpty ? 'movie' : rawType);

    return EmbyItem(
      id: _asString(json['id']),
      title: _asString(json['title']),
      poster: _asString(json['poster']),
      year: _asString(json['year']),
      rating: _asDouble(json['rating']),
      mediaType: mediaType,
    );
  }

  /// 是否为剧集（显示「剧集」角标）
  bool get isTv => mediaType == 'tv';

  /// 是否为电影（显示「电影」角标）
  bool get isMovie => mediaType == 'movie';

  /// 角标文案
  String get typeLabel => isTv ? '剧集' : '电影';

  /// 年份展示文案
  String get displayYear => year.isNotEmpty ? year : '未知年份';

  /// 是否有有效评分（后端常见 `rating: 0`，此时不展示）
  bool get hasRating => rating > 0;

  /// 评分展示文案，无评分时为空串
  String get ratingText => hasRating ? rating.toStringAsFixed(1) : '';

  /// 从 `/api/emby/list` 的完整响应体解析条目列表
  static List<EmbyItem> listFromResponse(dynamic responseData) {
    final map = _asMap(responseData);
    if (map == null) return const [];

    final rawList = map['list'];
    if (rawList is! List) return const [];

    final items = <EmbyItem>[];
    for (final entry in rawList) {
      final itemMap = _asMap(entry);
      if (itemMap == null) continue;
      items.add(EmbyItem.fromJson(itemMap));
    }
    return items;
  }

  EmbyItem copyWith({
    String? id,
    String? title,
    String? poster,
    String? year,
    double? rating,
    String? mediaType,
  }) {
    return EmbyItem(
      id: id ?? this.id,
      title: title ?? this.title,
      poster: poster ?? this.poster,
      year: year ?? this.year,
      rating: rating ?? this.rating,
      mediaType: mediaType ?? this.mediaType,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'poster': poster,
        'year': year,
        'rating': rating,
        'mediaType': mediaType,
      };
}

/// Emby 列表接口的分页约定
///
/// `/api/emby/list` 每页固定返回 20 条，且响应里没有 total / pageCount
/// 字段，因此「返回不足 20 条」即代表已到末页。
class EmbyPagination {
  /// 每页条数（后端固定 20）
  static const int pageSize = 20;

  /// 是否为末页：本页条数不足 [pageSize]（含空列表）
  static bool isLastPage(int itemCount) => itemCount < pageSize;

  /// 由本页条数推导是否还有下一页
  static bool hasMoreAfter(int itemCount) => !isLastPage(itemCount);
}
