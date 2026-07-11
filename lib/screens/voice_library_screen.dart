import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import '../memory/database.dart';
import '../services/locale_strings.dart';
import '../services/settings/tts_settings.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_background.dart';

/// 語音庫 — 管理已保存的 TTS 語音
class VoiceLibraryScreen extends StatefulWidget {
  const VoiceLibraryScreen({super.key});

  @override
  State<VoiceLibraryScreen> createState() => _VoiceLibraryScreenState();
}

class _VoiceLibraryScreenState extends State<VoiceLibraryScreen> {
  List<Map<String, dynamic>> _voices = [];
  bool _isLoading = true;
  final AudioPlayer _player = AudioPlayer();
  int? _playingId;
  String? _characterId;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingId = null);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_characterId == null) {
      _characterId =
          ModalRoute.of(context)?.settings.arguments as String? ?? 'default';
      _loadVoices();
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _playVoice(Map<String, dynamic> voice) async {
    final id = voice['id'] as int;
    final path = voice['file_path'] as String;

    if (_playingId == id) {
      await _player.stop();
      if (!mounted) return;
      setState(() => _playingId = null);
      return;
    }

    final file = File(path);
    if (!await file.exists()) return;

    await _player.stop();
    if (!mounted) return;
    setState(() => _playingId = id);
    await _player.play(DeviceFileSource(path));
  }

  Future<void> _loadVoices() async {
    final voices = await DatabaseHelper.getSavedVoices(
      characterId: _characterId,
    );
    if (mounted) {
      setState(() {
        _voices = voices;
        _isLoading = false;
      });
    }
  }

  Future<void> _editName(Map<String, dynamic> voice) async {
    final ctrl = TextEditingController(text: voice['name'] as String);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(
          L.pick(en: 'Rename', zhTW: '重命名'),
          style: YanciTheme.headingMedium.copyWith(fontSize: 16),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: YanciTheme.bodyText.copyWith(fontSize: 14),
          decoration: InputDecoration(
            hintText: L.pick(en: 'Voice name', zhTW: '語音名稱'),
            hintStyle: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: 0.4),
            ),
            border: InputBorder.none,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              L.get('cancel'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(
              L.get('save'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      await DatabaseHelper.updateVoiceName(voice['id'] as int, newName);
      _loadVoices();
    }
  }

  Future<void> _deleteVoice(Map<String, dynamic> voice) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        content: Text(
          L.pick(en: 'Delete this voice clip?', zhTW: '確認刪除這條語音？'),
          style: YanciTheme.bodyText.copyWith(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              L.get('cancel'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              L.get('confirm_delete'),
              style: TextStyle(color: Colors.red.withValues(alpha: 0.7)),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      // 刪除本地文件
      final path = voice['file_path'] as String;
      final file = File(path);
      if (await file.exists()) await file.delete();
      await DatabaseHelper.deleteVoice(voice['id'] as int);
      _loadVoices();
    }
  }

  String _safeFileName(String raw, String ext) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final base = cleaned.isEmpty
        ? 'voice'
        : cleaned.length > 64
        ? cleaned.substring(0, 64).trim()
        : cleaned;
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    return '${base}_$timestamp$ext';
  }

  Future<String> _uniquePath(String dir, String fileName) async {
    final ext = p.extension(fileName);
    final base = p.basenameWithoutExtension(fileName);
    var path = p.join(dir, fileName);
    var n = 2;
    while (await File(path).exists()) {
      path = p.join(dir, '$base ($n)$ext');
      n++;
    }
    return path;
  }

  bool _isFilePath(String path) {
    if (path.isEmpty) return false;
    final uri = Uri.tryParse(path);
    if (uri != null && uri.hasScheme && uri.scheme != 'file') return false;
    return p.isAbsolute(path) || (uri != null && uri.scheme == 'file');
  }

  String _normalizeFilePath(String path) {
    final uri = Uri.tryParse(path);
    if (uri != null && uri.scheme == 'file') return uri.toFilePath();
    return path;
  }

  Future<String?> _trySaveToRememberedDir(
    List<int> bytes,
    String fileName,
  ) async {
    final rememberedDir = await TtsSettings.getVoiceDownloadDir();
    if (!_isFilePath(rememberedDir)) return null;

    final dirPath = _normalizeFilePath(rememberedDir);
    final dir = Directory(dirPath);
    if (!await dir.exists()) return null;

    final destPath = await _uniquePath(dirPath, fileName);
    try {
      await File(destPath).writeAsBytes(bytes, flush: true);
      return destPath;
    } catch (_) {
      return null;
    }
  }

  Future<void> _rememberSavedPath(String savedTo) async {
    if (!_isFilePath(savedTo)) return;
    final filePath = _normalizeFilePath(savedTo);
    final dir = Directory(p.dirname(filePath));
    if (await dir.exists()) {
      await TtsSettings.saveVoiceDownloadDir(dir.path);
    }
  }

  void _showSavedPath(String path) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          L.pick(en: 'Saved to ($path)', zhTW: '已保存到（$path）'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: YanciTheme.accent,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        ),
      ),
    );
  }

  Future<void> _downloadVoice(Map<String, dynamic> voice) async {
    try {
      final sourcePath = voice['file_path'] as String;
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L.pick(en: 'Voice file not found', zhTW: '找不到語音檔')),
            backgroundColor: Colors.red.shade400,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
        return;
      }

      final bytes = await sourceFile.readAsBytes();
      final sourceExt = p.extension(sourcePath).toLowerCase();
      final ext = sourceExt.isEmpty ? '.mp3' : sourceExt;
      final fileName = _safeFileName(voice['name'] as String? ?? 'voice', ext);

      final autoSaved = await _trySaveToRememberedDir(bytes, fileName);
      if (autoSaved != null) {
        _showSavedPath(autoSaved);
        return;
      }

      final rememberedDir = await TtsSettings.getVoiceDownloadDir();
      final initialDir = _isFilePath(rememberedDir)
          ? _normalizeFilePath(rememberedDir)
          : null;
      final savedTo = await FilePicker.platform.saveFile(
        dialogTitle: L.pick(en: 'Save voice clip', zhTW: '保存語音檔'),
        fileName: fileName,
        initialDirectory: initialDir,
        type: FileType.custom,
        allowedExtensions: [ext.replaceFirst('.', '')],
        bytes: bytes,
      );
      if (savedTo == null) return;

      await _rememberSavedPath(savedTo);
      _showSavedPath(savedTo);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(en: 'Save failed: $e', zhTW: '保存失敗：$e'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          backgroundColor: Colors.red.shade400,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        content: Text(
          L.pick(en: 'Clear all saved voices?', zhTW: '確認清除全部語音緩存？'),
          style: YanciTheme.bodyText.copyWith(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              L.get('cancel'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              L.get('confirm_delete'),
              style: TextStyle(color: Colors.red.withValues(alpha: 0.7)),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      // 刪除所有本地文件
      for (final v in _voices) {
        final file = File(v['file_path'] as String);
        if (await file.exists()) await file.delete();
      }
      await DatabaseHelper.clearAllVoices(
        characterId: _characterId ?? 'default',
      );
      _loadVoices();
    }
  }

  String _formatDuration(int ms) {
    final seconds = (ms / 1000).ceil();
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    if (min > 0) return '$min:${sec.toString().padLeft(2, '0')}';
    return '${sec}s';
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              // ── 頂部欄 ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.arrow_back_ios_rounded,
                        size: 18,
                        color: YanciTheme.textPrimary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        L.pick(en: 'Voice Library', zhTW: '語音庫'),
                        style: YanciTheme.headingMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (_voices.isNotEmpty)
                      IconButton(
                        icon: Icon(
                          Icons.delete_sweep_outlined,
                          size: 20,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.5,
                          ),
                        ),
                        onPressed: _clearAll,
                        tooltip: L.pick(en: 'Clear all', zhTW: '清除全部'),
                      )
                    else
                      const SizedBox(width: 48),
                  ],
                ),
              ),

              // ── 內容 ──
              if (_isLoading)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_voices.isEmpty)
                Expanded(
                  child: Center(
                    child: Text(
                      L.pick(en: 'No saved voices yet', zhTW: '還沒有保存的語音'),
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: _voices.length,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemBuilder: (ctx, i) => _buildVoiceItem(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceItem(int i) {
    final v = _voices[i];
    final name = v['name'] as String;
    final source = v['source_conversation_title'] as String?;
    final durationMs = v['duration_ms'] as int? ?? 0;
    final fileSize = v['file_size'] as int? ?? 0;
    final createdAt = v['created_at'] as String;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: YanciTheme.isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.grey.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _playVoice(v),
            child: Icon(
              _playingId == (v['id'] as int)
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_outline_rounded,
              size: 28,
              color: YanciTheme.accent.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: YanciTheme.bodyText.copyWith(fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (source != null && source.isNotEmpty) source,
                    if (durationMs > 0) _formatDuration(durationMs),
                    if (fileSize > 0) _formatSize(fileSize),
                    createdAt.substring(0, 10),
                  ].join(' · '),
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _editName(v),
            child: Icon(
              Icons.edit_outlined,
              size: 16,
              color: YanciTheme.textSecondary.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(width: 14),
          GestureDetector(
            onTap: () => _downloadVoice(v),
            child: Icon(
              Icons.file_download_outlined,
              size: 16,
              color: YanciTheme.textSecondary.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(width: 14),
          GestureDetector(
            onTap: () => _deleteVoice(v),
            child: Icon(
              Icons.delete_outline_rounded,
              size: 16,
              color: Colors.red.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }
}
