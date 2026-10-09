import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../models/book_models.dart';
import '../services/books_service.dart';
import '../services/theme_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';
import 'book_reader_screen.dart';

/// 电子书馆（MoonTVPlus 图书，MVP 走 Legado 文本链路）
///
/// 布局：顶部搜索框 → 书目列表（封面 + 书名 + 作者 + 简介）→
/// 点书进 [BookReaderScreen]（章节目录 + 正文阅读）。
///
/// 两点说明：
/// - 后端是 OPDS + Legado 双引擎，但 OPDS 给的是 epub / pdf 文件，
///   客户端没有对应渲染依赖，MVP 只放行 Legado 源的搜索结果；
/// - 只有 OPDS 源时入口照常出现，页面顶部给出「暂不支持」说明，
///   不做静默隐藏（否则配了书源的用户会以为客户端坏了）。
class BooksScreen extends StatefulWidget {
  const BooksScreen({super.key});

  @override
  State<BooksScreen> createState() => _BooksScreenState();
}

class _BooksScreenState extends State<BooksScreen> {
  /// 项目统一强调色
  static const Color _accentColor = Color(0xFF27ae60);

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  List<BookSource> _allSources = const [];
  List<BookSource> _legadoSources = const [];
  bool _isLoadingSources = true;

  List<BookListItem> _results = const [];
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
    final all = await BooksService.fetchSources();
    final legado = await BooksService.fetchSources(onlyLegado: true);
    if (!mounted) return;
    setState(() {
      _allSources = all;
      _legadoSources = legado;
      _isLoadingSources = false;
    });
  }

  bool get _hasOpdsOnly =>
      _allSources.isNotEmpty && _legadoSources.isEmpty;

  Future<void> _doSearch() async {
    final keyword = _searchController.text.trim();
    _searchFocusNode.unfocus();
    if (keyword.isEmpty) return;
    setState(() => _isSearching = true);
    // 后端会搜所有源（含 OPDS）；这里只放行 Legado 源的结果，
    // 避免「搜到但读不了」的死链
    final results = await BooksService.search(keyword);
    final legadoIds = _legadoSources.map((s) => s.id).toSet();
    if (!mounted) return;
    setState(() {
      _results =
          results.where((item) => legadoIds.contains(item.sourceId)).toList();
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
                  '电子书馆',
                  style: FontUtils.poppins(
                    fontSize: isTablet ? 24 : 20,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF2c3e50),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '搜书并在线阅读',
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
                hintText: '搜书名、作者…',
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

  Widget _buildBody(bool isDark) {
    if (_isLoadingSources) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_allSources.isEmpty) {
      return _buildMessageState(
        isDark: isDark,
        icon: LucideIcons.bookMarked,
        title: '没有可用的书源',
        description: '请在 MoonTVPlus 管理面板配置 Legado 或 OPDS 书源。',
        showRetry: true,
      );
    }
    // 只有 OPDS 源：能搜到但读不了，先说清楚再让用户搜
    if (_hasOpdsOnly) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                LucideIcons.info,
                size: 16,
                color: isDark ? const Color(0xFFb0b0b0) : const Color(0xFF7f8c8d),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '当前书源仅支持 OPDS（epub / pdf），客户端暂不支持该格式，'
                  '需要配置 Legado 书源后才能在线阅读。',
                  style: FontUtils.poppins(
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFFb0b0b0)
                        : const Color(0xFF7f8c8d),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_hasSearched) {
      if (_results.isEmpty) {
        return _buildMessageState(
          isDark: isDark,
          icon: LucideIcons.bookMarked,
          title: '没有找到相关书籍',
          description: '换个关键词再试。',
          showRetry: false,
        );
      }
      return _buildBookList(isDark);
    }
    return _buildMessageState(
      isDark: isDark,
      icon: LucideIcons.bookMarked,
      title: '搜一本书开始阅读',
      description:
          '已接入 ${_legadoSources.length} 个 Legado 书源。',
      showRetry: false,
    );
  }

  Widget _buildBookList(bool isDark) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: _results.length,
      itemBuilder: (context, index) =>
          _buildBookTile(isDark, _results[index]),
    );
  }

  Widget _buildBookTile(bool isDark, BookListItem item) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => BookReaderScreen(book: item),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 62,
                  height: 86,
                  child: item.cover.isEmpty
                      ? Container(
                          color: isDark
                              ? const Color(0xFF262626)
                              : const Color(0xFFecf0f1),
                          child: Icon(
                            LucideIcons.bookOpen,
                            size: 22,
                            color: isDark
                                ? const Color(0xFF666666)
                                : const Color(0xFFbdc3c7),
                          ),
                        )
                      : CachedNetworkImage(
                          imageUrl: item.cover,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            color: isDark
                                ? const Color(0xFF262626)
                                : const Color(0xFFecf0f1),
                            child: Icon(
                              LucideIcons.bookOpen,
                              size: 22,
                              color: isDark
                                  ? const Color(0xFF666666)
                                  : const Color(0xFFbdc3c7),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FontUtils.poppins(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color:
                            isDark ? Colors.white : const Color(0xFF2c3e50),
                      ),
                    ),
                    if (item.author.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          item.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: FontUtils.poppins(
                            fontSize: 12,
                            color: isDark
                                ? const Color(0xFFb0b0b0)
                                : const Color(0xFF7f8c8d),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '来源：${item.sourceName}',
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
                    if (item.summary.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          item.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: FontUtils.poppins(
                            fontSize: 12,
                            height: 1.4,
                            color: isDark
                                ? const Color(0xFF808080)
                                : const Color(0xFF95a5a6),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
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
                onPressed: () {
                  setState(() => _isLoadingSources = true);
                  _loadSources();
                },
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
