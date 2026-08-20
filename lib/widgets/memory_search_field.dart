import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class MemorySearchField extends StatelessWidget {
  final TextEditingController controller;
  final bool searching;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const MemorySearchField({
    super.key,
    required this.controller,
    required this.searching,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: YanciTheme.bodyText.copyWith(fontSize: 13),
        decoration: InputDecoration(
          hintText: L.pick(
            en: 'Search content, keyword or category',
            zhTW: '搜尋內容、關鍵詞或類別',
            zhCN: '搜索内容、关键词或类别',
          ),
          hintStyle: YanciTheme.bodySmall,
          prefixIcon: searching
              ? const Padding(
                  padding: EdgeInsets.all(13),
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                )
              : const Icon(Icons.search_rounded, size: 20),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: L.pick(
                    en: 'Clear search',
                    zhTW: '清除搜尋',
                    zhCN: '清除搜索',
                  ),
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
          filled: true,
          fillColor: YanciTheme.isDark
              ? Colors.white.withValues(alpha: 0.055)
              : Colors.white.withValues(alpha: 0.55),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
