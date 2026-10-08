/// 搜索资源模型
class SearchResource {
  final String key;
  final String name;
  final String api;
  final String detail;
  final String from;
  final bool disabled;

  SearchResource({
    required this.key,
    required this.name,
    required this.api,
    required this.detail,
    required this.from,
    required this.disabled,
  });

  factory SearchResource.fromJson(Map<String, dynamic> json) {
    return SearchResource(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      api: json['api'] as String? ?? '',
      detail: json['detail'] as String? ?? '',
      from: json['from'] as String? ?? '',
      disabled: json['disabled'] as bool? ?? false,
    );
  }

  /// 是否可用于「本地搜索」
  ///
  /// MoonTVPlus 的 `/api/search/resources` 会在普通采集源之外追加源脚本条目
  /// （形如 `{key, name, script: true}`，没有 `api` 字段）。
  /// 这类源只能由服务端解析，本地搜索拿不到接口地址，必须跳过，
  /// 否则会拿空 URL 去请求，白白等到超时。
  bool get isSearchable => !disabled && api.isNotEmpty;

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'name': name,
      'api': api,
      'detail': detail,
      'from': from,
      'disabled': disabled,
    };
  }
}
