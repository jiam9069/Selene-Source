import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../models/emby_models.dart';
import '../services/emby_service.dart';
import '../services/theme_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';
import '../widgets/simple_tab_switcher.dart';
import 'player_screen.dart';

/// 私人影库（MoonTVPlus Emby）浏览页
///
/// 流程：加载源 → 选中源（唯一源自动选中）→ 加载分类 → 选中首个分类 →
/// 加载第 1 页 → 滚动到底部自动加载下一页（不足 20 条即停）。
///
/// 播放沿用既有的 [PlayerScreen]：源标识为 `emby_<key>`，
/// 由 `ApiService.fetchSourceDetail` 路由到 `/api/emby/detail`。
///
/// 状态处理：加载中显示 spinner；未配置源 / 无分类 / 空分类均显示带「重试」
/// 的友好空状态（[EmbyService] 所有方法失败时返回空结果而不抛异常，
/// 所以「空」同时覆盖了失败与真的没有内容两种情况）。
/// 所有 `await` 之后都检查 `mounted`，避免真实后端 1~30 秒延迟下的
/// setState-after-dispose。
class PrivateLibraryScreen extends StatefulWidget {
  const PrivateLibraryScreen({super.key});

  @override
  State<PrivateLibraryScreen> createState() => _PrivateLibraryScreenState();
}

class _PrivateLibraryScreenState extends State<PrivateLibraryScreen> {
  /// 项目统一强调色
  static const Color _accentColor = Color(0xFF27ae60);

  final ScrollController _scrollController = ScrollController();

  List<EmbySource> _sources = const [];
  EmbySource? _selectedSource;

  List<EmbyView> _views = const [];
  EmbyView? _selectedView;

  List<EmbyItem> _items = const [];

  int _page = 1;
  bool _hasMore = true;

  /// 首次加载源列表
  bool _isLoadingSources = true;

  /// 切换源 / 分类时的整页加载
  bool _isLoadingCategory = false;

  /// 加载下一页
  bool _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadSources();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 数据加载
  // ---------------------------------------------------------------------------

  /// 加载源列表：无源 → 空状态；唯一源 → 自动选中；多源 → 默认选中第一个
  Future<void> _loadSources() async {
    if (!mounted) return;
    setState(() {
      _isLoadingSources = true;
      _isLoadingCategory = false;
    });

    final sources = await EmbyService.fetchSources();
    if (!mounted) return;

    if (sources.isEmpty) {
      setState(() {
        _sources = const [];
        _selectedSource = null;
        _views = const [];
        _selectedView = null;
        _items = const [];
        _hasMore = false;
        _isLoadingSources = false;
        _isLoadingMore = false;
      });
      return;
    }

    setState(() {
      _sources = sources;
      _isLoadingSources = false;
    });

    // 自动选中第一个源并立即加载其分类
    await _loadViews(sources.first);
  }

  /// 选中某个源并加载它的分类列表，随后自动加载第一个分类的第 1 页
  Future<void> _loadViews(EmbySource source) async {
    if (!mounted) return;
    setState(() {
      _selectedSource = source;
      _views = const [];
      _selectedView = null;
      _items = const [];
      _page = 1;
      _hasMore = true;
      _isLoadingCategory = true;
      _isLoadingMore = false;
    });

    final views = await EmbyService.fetchViews(source.key);
    if (!mounted) return;
    // 请求期间用户可能已切换源，丢弃过期结果
    if (_selectedSource?.key != source.key) return;

    if (views.isEmpty) {
      setState(() {
        _views = const [];
        _selectedView = null;
        _items = const [];
        _hasMore = false;
        _isLoadingCategory = false;
      });
      return;
    }

    setState(() {
      _views = views;
      _selectedView = views.first;
    });

    await _loadFirstPage(source, views.first);
  }

  /// 加载指定分类的第 1 页
  Future<void> _loadFirstPage(EmbySource source, EmbyView view) async {
    if (!mounted) return;
    setState(() {
      _isLoadingCategory = true;
      _isLoadingMore = false;
      _items = const [];
      _page = 1;
      _hasMore = true;
    });

    final items = await EmbyService.fetchList(
      sourceKey: source.key,
      viewId: view.id,
      page: 1,
    );
    if (!mounted) return;
    if (_selectedSource?.key != source.key || _selectedView?.id != view.id) {
      return;
    }

    setState(() {
      _items = items;
      _page = 1;
      _hasMore = !EmbyService.isLastPage(items.length);
      _isLoadingCategory = false;
    });
  }

  /// 滚动到底部附近时加载下一页
  Future<void> _loadMore() async {
    if (_isLoadingMore || _isLoadingCategory || !_hasMore) return;

    final source = _selectedSource;
    final view = _selectedView;
    if (source == null || view == null) return;

    setState(() => _isLoadingMore = true);

    final nextPage = _page + 1;
    final items = await EmbyService.fetchList(
      sourceKey: source.key,
      viewId: view.id,
      page: nextPage,
    );
    if (!mounted) return;
    // 过期响应：期间已切换源 / 分类
    if (_selectedSource?.key != source.key || _selectedView?.id != view.id) {
      return;
    }

    setState(() {
      _isLoadingMore = false;
      _page = nextPage;
      _items = [..._items, ...items];
      _hasMore = !EmbyService.isLastPage(items.length);
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  // ---------------------------------------------------------------------------
  // 交互
  // ---------------------------------------------------------------------------

  void _onSourceChanged(EmbySource source) {
    if (_selectedSource?.key == source.key) return;
    _loadViews(source);
  }

  void _onViewChanged(EmbyView view) {
    if (_selectedView?.id == view.id) return;
    final source = _selectedSource;
    if (source == null) return;

    setState(() => _selectedView = view);
    _loadFirstPage(source, view);
  }

  /// 重试当前上下文：没有源时重载源；有分类时重载当前分类
  void _retry() {
    final source = _selectedSource;
    final view = _selectedView;
    if (source == null) {
      _loadSources();
    } else if (view == null) {
      _loadViews(source);
    } else {
      _loadFirstPage(source, view);
    }
  }

  void _openPlayer(EmbyItem item) {
    final source = _selectedSource;
    if (source == null || item.id.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          source: 'emby_${source.key}',
          id: item.id,
          title: item.title,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        final isDark = themeService.isDarkMode;

        return Theme(
          data: isDark ? themeService.darkTheme : themeService.lightTheme,
          child: Scaffold(
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(isDark),
                  if (_sources.length > 1) _buildSourceSelector(),
                  if (_views.isNotEmpty) _buildViewSelector(),
                  Expanded(child: _buildBody(isDark)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 标题 + 副标题（副标题取自 MoonTVPlus 官方 Web UI 文案）
  Widget _buildHeader(bool isDark) {
    final isTablet = DeviceUtils.isTablet(context);
    final canPop = Navigator.of(context).canPop();

    return Padding(
      padding: EdgeInsets.fromLTRB(isTablet ? 16 : 8, 8, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (canPop)
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(LucideIcons.arrowLeft, size: 20),
              color: isDark ? Colors.white : const Color(0xFF2c3e50),
              tooltip: '返回',
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '私人影库',
                  style: FontUtils.poppins(
                    fontSize: isTablet ? 24 : 20,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF2c3e50),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '观看自我收藏的高清视频吧',
                  style: FontUtils.poppins(
                    fontSize: isTablet ? 13 : 12,
                    fontWeight: FontWeight.w400,
                    color: isDark
                        ? const Color(0xFFb0b0b0)
                        : const Color(0xFF7f8c8d),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 多源时的源选择器（唯一源时不展示）
  Widget _buildSourceSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SimpleTabSwitcher(
        tabs: _sources.map((source) => source.displayName).toList(),
        selectedTab: _selectedSource?.displayName ?? '',
        onTabChanged: (label) {
          for (final source in _sources) {
            if (source.displayName == label) {
              _onSourceChanged(source);
              return;
            }
          }
        },
      ),
    );
  }

  /// 分类（视图）标签
  Widget _buildViewSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SimpleTabSwitcher(
        tabs: _views.map((view) => view.displayName).toList(),
        selectedTab: _selectedView?.displayName ?? '',
        onTabChanged: (label) {
          for (final view in _views) {
            if (view.displayName == label) {
              _onViewChanged(view);
              return;
            }
          }
        },
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isLoadingSources || _isLoadingCategory) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

    // 未配置任何 Emby 源
    if (_sources.isEmpty) {
      return _buildMessageState(
        isDark: isDark,
        icon: LucideIcons.database,
        title: '尚未配置私人影库',
        description: '请先在 MoonTVPlus 服务端的「私人影库」中配置 Emby，'
            '然后点击重试。',
        showRetry: true,
      );
    }

    // 源存在但没有任何分类
    if (_views.isEmpty) {
      return _buildMessageState(
        isDark: isDark,
        icon: LucideIcons.folderSearch,
        title: '该影库暂无分类',
        description: '当前影库没有返回任何媒体分类，请稍后重试。',
        showRetry: true,
      );
    }

    // 分类存在但第一条都没有：可能是真空分类，也可能是请求失败
    // （EmbyService 失败时统一返回空列表，不抛异常）
    if (_items.isEmpty) {
      return _buildMessageState(
        isDark: isDark,
        icon: LucideIcons.film,
        title: '该分类暂无内容',
        description: '换个分类看看，或点击重试。若长时间无内容，'
            '请检查服务端 Emby 是否可用。',
        showRetry: true,
      );
    }

    return _buildGrid(isDark);
  }

  Widget _buildMessageState({
    required bool isDark,
    required IconData icon,
    required String title,
    required String description,
    required bool showRetry,
  }) {
    final isTablet = DeviceUtils.isTablet(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: isTablet ? 56 : 44,
              color: isDark
                  ? const Color(0xFF666666)
                  : const Color(0xFFbdc3c7),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: FontUtils.poppins(
                fontSize: isTablet ? 18 : 16,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : const Color(0xFF2c3e50),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: FontUtils.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: isDark
                    ? const Color(0xFFb0b0b0)
                    : const Color(0xFF7f8c8d),
              ),
            ),
            if (showRetry) ...[
              const SizedBox(height: 20),
              TextButton.icon(
                onPressed: _retry,
                icon: const Icon(LucideIcons.arrowDownUp, size: 16),
                label: Text(
                  '重试',
                  style: FontUtils.poppins(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _accentColor,
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: _accentColor,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: const BorderSide(color: _accentColor),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 响应式海报网格 + 无限滚动
  Widget _buildGrid(bool isDark) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = DeviceUtils.isTablet(context);
        final crossAxisCount = DeviceUtils.getTabletColumnCount(context);

        const double padding = 16.0;
        const double spacing = 12.0;
        final double availableWidth = constraints.maxWidth -
            (padding * 2) -
            (spacing * (crossAxisCount - 1));
        final double itemWidth = math.max(availableWidth / crossAxisCount, 80.0);
        // 海报 2:3 + 标题/年份文字区
        final double itemHeight = itemWidth * 1.5 + 48;

        return CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(padding),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  childAspectRatio: itemWidth / itemHeight,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: isTablet ? 12 : 16,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildItemCard(_items[index], isDark),
                  childCount: _items.length,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: _isLoadingMore
                  ? const Padding(
                      padding: EdgeInsets.only(bottom: 20),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : const SizedBox(height: 20),
            ),
          ],
        );
      },
    );
  }

  Widget _buildItemCard(EmbyItem item, bool isDark) {
    final badgeColor = item.isTv ? _accentColor : const Color(0xFF3498DB);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _openPlayer(item),
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: item.poster,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          color: isDark
                              ? const Color(0xFF333333)
                              : const Color(0xFFe0e0e0),
                        ),
                        errorWidget: (context, url, error) => Container(
                          color: isDark
                              ? const Color(0xFF333333)
                              : const Color(0xFFe0e0e0),
                          child: Icon(
                            LucideIcons.film,
                            color: isDark
                                ? const Color(0xFF666666)
                                : const Color(0xFF95a5a6),
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        item.typeLabel,
                        style: FontUtils.poppins(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: FontUtils.poppins(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white : const Color(0xFF2c3e50),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              item.hasRating
                  ? '${item.displayYear} · ${item.ratingText}'
                  : item.displayYear,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: FontUtils.poppins(
                fontSize: 11,
                fontWeight: FontWeight.w400,
                color: const Color(0xFF95a5a6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
