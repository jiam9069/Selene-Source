import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../models/manga_models.dart';
import '../services/manga_service.dart';
import '../services/theme_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';
import 'manga_detail_screen.dart';

/// 漫画展馆（MoonTVPlus 漫画，Suwayomi 后端）
///
/// 布局：顶部搜索框 + 源切换（横向滚动 chips）→ 封面网格 →
/// 点击进 [MangaDetailScreen]（详情 + 章节列表）。
///
/// MVP 从「搜索」切入；推荐 / 最新（后端 `/api/manga/recommend`）与
/// 书架 / 阅读进度（`/api/manga/shelf`、`/api/manga/history`）留到后续版本。
class MangaScreen extends StatefulWidget {
  const MangaScreen({super.key});

  @override
  State<MangaScreen> createState() => _MangaScreenState();
}

class _MangaScreenState extends State<MangaScreen> {
  /// 项目统一强调色
  static const Color _accentColor = Color(0xFF27ae60);

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  List<MangaSource> _sources = const [];
  bool _isLoadingSources = true;

  /// 当前选中的源（null = 全部源一起搜）
  MangaSource? _selectedSource;

  List<MangaItem> _results = const [];
  bool _isSearching = false;
  bool _hasSearched = false;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadSources() async {
    final sources = await MangaService.fetchSources();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _isLoadingSources = false;
    });
  }

  Future<void> _doSearch() async {
    final keyword = _searchController.text.trim();
    _searchFocusNode.unfocus();
    if (keyword.isEmpty) return;
    setState(() => _isSearching = true);
    final results = await MangaService.search(
      keyword,
      sourceId: _selectedSource?.id,
    );
    if (!mounted) return;
    setState(() {
      _results = results;
      _hasSearched = true;
      _isSearching = false;
    });
  }

  // ================================================================ 界面

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        final isDark = themeService.isDarkMode;
        return Theme(
          data: isDark ? themeService.darkTheme : themeService.lightTheme,
          child: Scaffold(
            backgroundColor:
                isDark ? const Color(0xFF141414) : const Color(0xFFF4F5F7),
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(isDark),
                  _buildSearchBar(isDark),
                  if (!_isLoadingSources && _sources.length > 1)
                    _buildSourceChips(isDark),
                  Expanded(child: _buildBody(isDark)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(bool isDark) {
    final isTablet = DeviceUtils.isTablet(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(isTablet ? 16 : 8, 8, 16, 4),
      child: Row(
        children: [
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
                  '漫画展馆',
                  style: FontUtils.poppins(
                    fontSize: isTablet ? 24 : 20,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF2c3e50),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '在线漫画搜索与阅读',
                  style: FontUtils.poppins(
                    fontSize: isTablet ? 13 : 12,
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

  Widget _buildSearchBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _doSearch(),
              style: FontUtils.poppins(
                fontSize: 14,
                color: isDark ? Colors.white : const Color(0xFF2c3e50),
              ),
              decoration: InputDecoration(
                hintText: '搜漫画名…',
                hintStyle: FontUtils.poppins(
                  fontSize: 14,
                  color:
                      isDark ? const Color(0xFF808080) : const Color(0xFF95a5a6),
                ),
                prefixIcon: Icon(
                  LucideIcons.search,
                  size: 18,
                  color:
                      isDark ? const Color(0xFF808080) : const Color(0xFF95a5a6),
                ),
                filled: true,
                fillColor: isDark ? const Color(0xFF1e1e1e) : Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _isSearching ? null : () => _doSearch(),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: _accentColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: _isSearching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Colors.white),
                      ),
                    )
                  : Text(
                      '搜索',
                      style: FontUtils.poppins(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 源切换：第一项固定为「全部」，后面接各源
  Widget _buildSourceChips(bool isDark) {
    final chips = <({String id, String label})>[
      (id: '', label: '全部'),
      for (final source in _sources) (id: source.id, label: source.displayName),
    ];
    final selectedId = _selectedSource?.id ?? '';

    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final chip in chips) ...[
            GestureDetector(
              onTap: () => setState(() {
                _selectedSource =
                    chip.id.isEmpty ? null : _findSourceById(chip.id);
              }),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: selectedId == chip.id
                      ? _accentColor
                      : (isDark ? const Color(0xFF1e1e1e) : Colors.white),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  chip.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: FontUtils.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: selectedId == chip.id
                        ? Colors.white
                        : (isDark
                            ? const Color(0xFFb0b0b0)
                            : const Color(0xFF7f8c8d)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  MangaSource? _findSourceById(String id) {
    for (final source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  Widget _buildBody(bool isDark) {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_hasSearched) {
      if (_isLoadingSources) {
        return const Center(child: CircularProgressIndicator());
      }
      return _buildMessageState(
        isDark: isDark,
        icon: LucideIcons.bookOpen,
        title: '搜一部漫画开始阅读',
        description: '支持在全部源里搜，也可以先选一个源。',
        showRetry: false,
      );
    }
    if (_results.isEmpty) {
      return _buildMessageState(
        isDark: isDark,
        icon: LucideIcons.imageOff,
        title: '没有找到相关漫画',
        description: '换个关键词，或切换源再试。',
        showRetry: true,
      );
    }
    return _buildGrid(isDark);
  }

  /// 封面网格：按屏宽自适应 2~4 列（平板放更多列）
  Widget _buildGrid(bool isDark) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount =
            (constraints.maxWidth / 130).clamp(2, 5).round();
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.62,
          ),
          itemCount: _results.length,
          itemBuilder: (context, index) =>
              _buildMangaCard(isDark, _results[index]),
        );
      },
    );
  }

  Widget _buildMangaCard(bool isDark, MangaItem item) {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => MangaDetailScreen(item: item),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.cover.isEmpty)
                    Container(
                      color: isDark
                          ? const Color(0xFF1e1e1e)
                          : Colors.white,
                      child: Icon(
                        LucideIcons.imageOff,
                        size: 32,
                        color: isDark
                            ? const Color(0xFF666666)
                            : const Color(0xFFbdc3c7),
                      ),
                    )
                  else
                    CachedNetworkImage(
                      imageUrl: item.cover,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        color: isDark
                            ? const Color(0xFF1e1e1e)
                            : const Color(0xFFecf0f1),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        color: isDark
                            ? const Color(0xFF1e1e1e)
                            : Colors.white,
                        child: Icon(
                          LucideIcons.imageOff,
                          size: 32,
                          color: isDark
                              ? const Color(0xFF666666)
                              : const Color(0xFFbdc3c7),
                        ),
                      ),
                    ),
                  // 源名角标：多源搜索时分辨同一部作品的不同来源
                  if (item.sourceName.isNotEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        color: Colors.black.withValues(alpha: 0.55),
                        child: Text(
                          item.sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: FontUtils.poppins(
                            fontSize: 10,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: FontUtils.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white : const Color(0xFF2c3e50),
              ),
            ),
          ),
          if (item.author.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                item.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FontUtils.poppins(
                  fontSize: 11,
                  color: isDark
                      ? const Color(0xFF808080)
                      : const Color(0xFF95a5a6),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageState({
    required bool isDark,
    required IconData icon,
    required String title,
    required String description,
    required bool showRetry,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 44,
              color: isDark ? const Color(0xFF666666) : const Color(0xFFbdc3c7),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: FontUtils.poppins(
                fontSize: 16,
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
                color:
                    isDark ? const Color(0xFF808080) : const Color(0xFF95a5a6),
              ),
            ),
            if (showRetry) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: _doSearch,
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
