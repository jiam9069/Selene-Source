/// 后端服务配置
///
/// 对应 `GET /api/server-config` 的响应。该接口无需登录即可访问，
/// 因此既用于连接性探测，也用于识别后端类型与能力开关。
///
/// - MoonTV v100 仅返回 `SiteName` / `StorageType` / `Version` 三个字段。
/// - MoonTVPlus（v200+）在此基础上增加了 `AIEnabled`、`WatchRoom`、
///   `DanmakuAutoLoadDefault`、各类登录开关等字段。
class ServerConfig {
  final String siteName;
  final String storageType;
  final String version;

  /// 后端是否为 MoonTVPlus（而非原版 MoonTV v100）
  final bool isMoonTVPlus;

  final bool tvModeEnabled;
  final bool enableOfflineDownload;
  final bool enableRegistration;
  final bool loginRequireTurnstile;
  final bool enableOidcLogin;
  final bool enableTelegramLogin;
  final bool danmakuAutoLoadDefault;

  /// AI 问片
  final bool aiEnabled;
  final bool aiEnableHomepageEntry;
  final bool aiEnableVideoCardEntry;
  final bool aiEnablePlayPageEntry;
  final bool aiEnableComments;

  /// 原始响应，便于后续扩展时按需读取
  final Map<String, dynamic> raw;

  ServerConfig({
    required this.siteName,
    required this.storageType,
    required this.version,
    required this.isMoonTVPlus,
    required this.tvModeEnabled,
    required this.enableOfflineDownload,
    required this.enableRegistration,
    required this.loginRequireTurnstile,
    required this.enableOidcLogin,
    required this.enableTelegramLogin,
    required this.danmakuAutoLoadDefault,
    required this.aiEnabled,
    required this.aiEnableHomepageEntry,
    required this.aiEnableVideoCardEntry,
    required this.aiEnablePlayPageEntry,
    required this.aiEnableComments,
    required this.raw,
  });

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      siteName: json['SiteName'] as String? ?? '',
      storageType: json['StorageType'] as String? ?? '',
      version: json['Version']?.toString() ?? '',
      isMoonTVPlus: _detectMoonTVPlus(json),
      tvModeEnabled: json['TVModeEnabled'] as bool? ?? false,
      enableOfflineDownload: json['EnableOfflineDownload'] as bool? ?? false,
      enableRegistration: json['EnableRegistration'] as bool? ?? false,
      loginRequireTurnstile: json['LoginRequireTurnstile'] as bool? ?? false,
      enableOidcLogin: json['EnableOIDCLogin'] as bool? ?? false,
      enableTelegramLogin: json['EnableTelegramLogin'] as bool? ?? false,
      danmakuAutoLoadDefault:
          json['DanmakuAutoLoadDefault'] as bool? ?? false,
      aiEnabled: json['AIEnabled'] as bool? ?? false,
      aiEnableHomepageEntry: json['AIEnableHomepageEntry'] as bool? ?? false,
      aiEnableVideoCardEntry: json['AIEnableVideoCardEntry'] as bool? ?? false,
      aiEnablePlayPageEntry: json['AIEnablePlayPageEntry'] as bool? ?? false,
      aiEnableComments: json['AIEnableAIComments'] as bool? ?? false,
      raw: json,
    );
  }

  /// 识别后端类型
  ///
  /// 优先看 MoonTVPlus 独有的字段；老版本 Plus 或精简部署缺少这些字段时，
  /// 退回按站点名与主版本号判断（MoonTV v100.x，MoonTVPlus v226.x）。
  static bool _detectMoonTVPlus(Map<String, dynamic> json) {
    if (json.containsKey('AIEnabled') ||
        json.containsKey('WatchRoom') ||
        json.containsKey('DanmakuAutoLoadDefault')) {
      return true;
    }

    final siteName = (json['SiteName'] as String? ?? '').toLowerCase();
    if (siteName.contains('moontvplus')) {
      return true;
    }

    final major = int.tryParse(
      (json['Version']?.toString() ?? '').split('.').first,
    );
    return major != null && major >= 200;
  }

  /// AI 问片是否有可用入口
  bool get aiFeatureVisible => aiEnabled;

  /// 站点显示名（缺省回退）
  String get displayName => siteName.isNotEmpty ? siteName : 'Selene';

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(raw);
}
