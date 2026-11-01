import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/locale_strings.dart';
import '../services/storage_usage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_background.dart';
import '../widgets/themed_notice.dart';

/// 設定 → 儲存空間：看 Holt 佔了多少、分類多選刪除。
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key});

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  StorageSnapshot? _snapshot;
  bool _deleting = false;
  bool _otherExpanded = false;
  final Set<StorageCategory> _expanded = <StorageCategory>{};
  final Map<StorageCategory, Set<String>> _selected =
      <StorageCategory, Set<String>>{
        for (final c in StorageCategory.values) c: <String>{},
      };

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final snapshot = await StorageUsageService.scan();
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      for (final c in StorageCategory.values) {
        final ids = snapshot.items[c]!.map((item) => item.id).toSet();
        _selected[c]!.removeWhere((id) => !ids.contains(id));
      }
    });
  }

  static String _size(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _date(DateTime? d) => d == null
      ? ''
      : '${d.year}/${d.month.toString().padLeft(2, '0')}/'
            '${d.day.toString().padLeft(2, '0')}';

  String _title(StorageCategory c) => switch (c) {
    StorageCategory.chatImages => L.pick(en: 'Chat images', zhTW: '聊天圖片'),
    StorageCategory.importedMedia => L.pick(
      en: 'Imported media',
      zhTW: '還原匯入的媒體',
    ),
    StorageCategory.backups => L.pick(en: 'Backup files', zhTW: '備份檔'),
    StorageCategory.voices => L.pick(en: 'Voice library', zhTW: '語音庫'),
    StorageCategory.localModels => L.pick(en: 'Local models', zhTW: '本地模型'),
    StorageCategory.cache => L.pick(en: 'Cache', zhTW: '暫存'),
  };

  IconData _icon(StorageCategory c) => switch (c) {
    StorageCategory.chatImages => Icons.photo_library_outlined,
    StorageCategory.importedMedia => Icons.move_to_inbox_outlined,
    StorageCategory.backups => Icons.inventory_2_outlined,
    StorageCategory.voices => Icons.graphic_eq_rounded,
    StorageCategory.localModels => Icons.memory_rounded,
    StorageCategory.cache => Icons.cleaning_services_outlined,
  };

  Future<void> _deleteSelected(StorageCategory c) async {
    final snapshot = _snapshot;
    if (snapshot == null || _deleting) return;
    final ids = _selected[c]!;
    final items = snapshot.items[c]!.where((i) => ids.contains(i.id)).toList();
    if (items.isEmpty) return;
    final bytes = items.fold<int>(0, (sum, i) => sum + i.bytes);
    final inUseImages =
        c == StorageCategory.chatImages || c == StorageCategory.importedMedia
        ? items.where((i) => i.inUse).length
        : 0;
    final warning = switch (c) {
      StorageCategory.chatImages when inUseImages > 0 => L.pick(
        en: '$inUseImages of them are still in chats and will show as broken images.',
        zhTW: '其中 $inUseImages 張還在對話裡，刪掉後那些氣泡會顯示破圖。',
      ),
      StorageCategory.importedMedia when inUseImages > 0 => L.pick(
        en: '$inUseImages of them are still used (avatars, backgrounds or chats) and will break.',
        zhTW: '其中 $inUseImages 個還在用（頭像、背景或對話），刪掉後會顯示破圖。',
      ),
      StorageCategory.backups => L.pick(
        en: 'Make sure you have another copy before deleting.',
        zhTW: '刪除前確認你在別的地方還留有一份。',
      ),
      StorageCategory.localModels => L.pick(
        en: 'You can download them again later.',
        zhTW: '之後需要可以再下載。',
      ),
      StorageCategory.cache => L.pick(
        en: 'Cache is rebuilt automatically when needed.',
        zhTW: '暫存需要時會自動重新產生。',
      ),
      _ => '',
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.themedOverlaySurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: YanciTheme.themedOverlayBorder, width: 0.8),
        ),
        title: Text(
          L.pick(
            en: 'Delete ${items.length} items (${_size(bytes)})?',
            zhTW: '刪除 ${items.length} 項（${_size(bytes)}）？',
          ),
          style: YanciTheme.headingMedium,
        ),
        content: Text(
          [
            L.pick(en: 'This cannot be undone.', zhTW: '刪除後無法復原。'),
            if (warning.isNotEmpty) warning,
          ].join('\n'),
          style: YanciTheme.bodySmall,
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: YanciTheme.textSecondary,
            ),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: YanciTheme.accent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              L.pick(en: 'Delete', zhTW: '刪除'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    await StorageUsageService.delete(c, items);
    imageCache.clear();
    await _scan();
    if (!mounted) return;
    setState(() => _deleting = false);
    showThemedPillNotice(
      context,
      L.pick(en: 'Freed ${_size(bytes)}', zhTW: '已釋放 ${_size(bytes)}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 48,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Text(
                      L.pick(en: 'Storage', zhTW: '儲存空間'),
                      style: YanciTheme.headingMedium,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        icon: Icon(
                          Icons.arrow_back_ios_rounded,
                          size: 20,
                          color: YanciTheme.textPrimary,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: snapshot == null
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        color: YanciTheme.accent,
                        onRefresh: _scan,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                          children: [
                            _summary(snapshot),
                            for (final c in StorageCategory.values)
                              _categoryCard(snapshot, c),
                            _otherCard(snapshot),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration get _card => BoxDecoration(
    color: YanciTheme.themedCardBackground(),
    borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
    border: Border.all(color: YanciTheme.themedCardBorder(), width: 0.6),
  );

  Widget _summary(StorageSnapshot s) {
    final total = s.totalBytes == 0 ? 1 : s.totalBytes;
    final parts = <(int, double)>[
      for (var i = 0; i < StorageCategory.values.length; i++)
        (s.bytesOf(StorageCategory.values[i]), 1.0 - i * 0.14),
      (s.otherBytes, 0.12),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: _card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L.pick(en: 'Holt data', zhTW: 'Holt 資料共'),
            style: YanciTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            _size(s.totalBytes),
            style: YanciTheme.headingLarge.copyWith(letterSpacing: 0.5),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: Row(
                children: [
                  for (final (bytes, alpha) in parts)
                    if (bytes > 0)
                      Expanded(
                        flex: (bytes / total * 1000).ceil(),
                        child: ColoredBox(
                          color: YanciTheme.accent.withValues(alpha: alpha),
                        ),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            L.pick(
              en: 'App itself (~200 MB) is not included. Pull down to rescan.',
              zhTW: '不含 App 本體（約 200 MB）。下拉可重新掃描。',
            ),
            style: YanciTheme.bodySmall.copyWith(fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _categoryCard(StorageSnapshot s, StorageCategory c) {
    final items = s.items[c]!;
    final expanded = _expanded.contains(c);
    final selected = _selected[c]!;
    final unused =
        c == StorageCategory.chatImages ||
            c == StorageCategory.importedMedia ||
            c == StorageCategory.voices
        ? items.where((i) => !i.inUse).toList()
        : const <StorageItem>[];
    final selectedBytes = items
        .where((i) => selected.contains(i.id))
        .fold<int>(0, (sum, i) => sum + i.bytes);
    final allSelected = items.isNotEmpty && selected.length == items.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: _card,
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            onTap: items.isEmpty
                ? null
                : () => setState(
                    () => expanded ? _expanded.remove(c) : _expanded.add(c),
                  ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(_icon(c), size: 20, color: YanciTheme.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_title(c), style: YanciTheme.bodyText),
                        Text(
                          c == StorageCategory.cache
                              ? L.pick(
                                  en: 'Rebuilt automatically',
                                  zhTW: '可隨時清除，會自動重建',
                                )
                              : L.pick(
                                  en: '${items.length} items',
                                  zhTW: '${items.length} 項',
                                ),
                          style: YanciTheme.bodySmall.copyWith(fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  Text(_size(s.bytesOf(c)), style: YanciTheme.bodySmall),
                  if (items.isNotEmpty)
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: YanciTheme.textSecondary,
                    ),
                ],
              ),
            ),
          ),
          if (expanded && items.isNotEmpty) ...[
            Divider(height: 1, color: YanciTheme.themedCardBorder()),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  if (c != StorageCategory.cache)
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: YanciTheme.textPrimary,
                      ),
                      onPressed: () => setState(() {
                        selected.clear();
                        if (!allSelected) {
                          selected.addAll(items.map((i) => i.id));
                        }
                      }),
                      child: Text(
                        allSelected
                            ? L.pick(en: 'Deselect all', zhTW: '取消全選')
                            : L.pick(en: 'Select all', zhTW: '全選'),
                      ),
                    ),
                  if (unused.isNotEmpty)
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: YanciTheme.textSecondary,
                      ),
                      onPressed: () => setState(
                        () => selected
                          ..clear()
                          ..addAll(unused.map((i) => i.id)),
                      ),
                      child: Text(
                        L.pick(
                          en: 'Unused (${unused.length})',
                          zhTW: '選沒在用的（${unused.length}）',
                        ),
                      ),
                    ),
                  const Spacer(),
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      backgroundColor: YanciTheme.accent.withValues(
                        alpha: 0.16,
                      ),
                      foregroundColor: YanciTheme.accent,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed:
                        _deleting ||
                            (c != StorageCategory.cache && selected.isEmpty)
                        ? null
                        : () {
                            if (c == StorageCategory.cache) {
                              selected
                                ..clear()
                                ..addAll(items.map((i) => i.id));
                            }
                            _deleteSelected(c);
                          },
                    child: Text(
                      c == StorageCategory.cache
                          ? L.pick(en: 'Clear', zhTW: '清除暫存')
                          : selected.isEmpty
                          ? L.pick(en: 'Delete', zhTW: '刪除')
                          : L.pick(
                              en: 'Delete ${selected.length} · ${_size(selectedBytes)}',
                              zhTW: '刪除 ${selected.length} 項 · ${_size(selectedBytes)}',
                            ),
                    ),
                  ),
                ],
              ),
            ),
            if (c == StorageCategory.chatImages ||
                c == StorageCategory.importedMedia)
              _imageGrid(items, selected)
            else if (c != StorageCategory.cache)
              for (final item in items) _itemRow(c, item, selected),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  static const Set<String> _imageExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.heic',
    '.bmp',
  };

  static bool _looksLikeImage(String path) =>
      _imageExtensions.contains(p.extension(path).toLowerCase());

  void _toggle(Set<String> selected, String id) => setState(
    () => selected.contains(id) ? selected.remove(id) : selected.add(id),
  );

  Widget _imageGrid(List<StorageItem> items, Set<String> selected) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final isSelected = selected.contains(item.id);
        return GestureDetector(
          onTap: () => _toggle(selected, item.id),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!_looksLikeImage(item.path!))
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: YanciTheme.accent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      p.extension(item.path!).replaceFirst('.', '').toUpperCase(),
                      style: YanciTheme.bodySmall.copyWith(fontSize: 11),
                    ),
                  ),
                )
              else
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(item.path!),
                  fit: BoxFit.cover,
                  cacheWidth: (90 * dpr).round(),
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: YanciTheme.accent.withValues(alpha: 0.08),
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: YanciTheme.textSecondary,
                    ),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: isSelected
                      ? Colors.black.withValues(alpha: 0.28)
                      : Colors.transparent,
                  border: Border.all(
                    color: isSelected
                        ? YanciTheme.accent
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  isSelected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: isSelected ? YanciTheme.accent : Colors.white,
                  shadows: const [Shadow(blurRadius: 4)],
                ),
              ),
              if (!item.inUse)
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      L.pick(en: 'Unused', zhTW: '沒在用'),
                      style: const TextStyle(fontSize: 9.5, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _itemRow(StorageCategory c, StorageItem item, Set<String> selected) {
    final label = item.label.isNotEmpty
        ? item.label
        : L.pick(en: 'Unlisted file', zhTW: '未登記的殘檔');
    final sub = [
      _date(item.date),
      _size(item.bytes),
      if (c == StorageCategory.voices && !item.inUse)
        L.pick(en: 'not in library', zhTW: '語音庫裡沒有'),
    ].where((s) => s.isNotEmpty).join(' · ');
    return CheckboxListTile(
      dense: true,
      value: selected.contains(item.id),
      onChanged: (_) => _toggle(selected, item.id),
      activeColor: YanciTheme.accent,
      checkboxShape: const CircleBorder(),
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: YanciTheme.bodyText.copyWith(fontSize: 14),
      ),
      subtitle: Text(sub, style: YanciTheme.bodySmall.copyWith(fontSize: 11.5)),
    );
  }

  static const Map<String, (String, String)> _otherNames =
      <String, (String, String)>{
        'yanci.db': ('Chat database', '聊天資料庫'),
        'yanci.db-wal': ('Database write log', '資料庫寫入日誌'),
        'yanci.db-shm': ('Database index', '資料庫索引'),
        'background_images': ('Backgrounds', '背景圖'),
        'avatars': ('Avatars', '頭像'),
        'stickers': ('Stickers', '表情包'),
        'fonts': ('Fonts', '字體'),
        'asr_zh': ('Speech recognition model', '語音辨識模型'),
        'generated_images': ('Generated images', '生成的圖片'),
        'shop_items': ('Shop item images', '商店物品圖'),
        'send_button_images': ('Send button images', '發送鍵圖片'),
        'reply_checkpoints': ('Reply checkpoints', '回覆中斷點'),
        'diagnostics': ('Diagnostics', '診斷紀錄'),
        'HoltBackup': ('Auto local backup', '自動本地備份'),
        'HoltBackup.prev': ('Previous auto backup', '上一份自動備份'),
        'picked_images': ('Picked images (unknown source)', '選圖殘檔（來源待查）'),
      };

  Widget _otherCard(StorageSnapshot s) {
    final expanded = _otherExpanded;
    return Container(
      decoration: _card,
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            onTap: s.otherParts.isEmpty
                ? null
                : () => setState(() => _otherExpanded = !expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 20,
                    color: YanciTheme.textSecondary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          L.pick(en: 'Other', zhTW: '其他'),
                          style: YanciTheme.bodyText,
                        ),
                        Text(
                          L.pick(
                            en: 'Needed to run — view only',
                            zhTW: 'App 運作需要，只看不刪；點開看明細',
                          ),
                          style: YanciTheme.bodySmall.copyWith(fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  Text(_size(s.otherBytes), style: YanciTheme.bodySmall),
                  if (s.otherParts.isNotEmpty)
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: YanciTheme.textSecondary,
                    ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            Divider(height: 1, color: YanciTheme.themedCardBorder()),
            for (final part in s.otherParts)
              Padding(
                padding: const EdgeInsets.fromLTRB(48, 10, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _otherNames[part.label] == null
                            ? part.label
                            : L.pick(
                                en: _otherNames[part.label]!.$1,
                                zhTW: _otherNames[part.label]!.$2,
                              ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: YanciTheme.bodyText.copyWith(fontSize: 14),
                      ),
                    ),
                    Text(_size(part.bytes), style: YanciTheme.bodySmall),
                  ],
                ),
              ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}
