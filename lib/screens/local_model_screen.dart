import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/local_model_service.dart';
import '../services/locale_strings.dart';
import '../services/settings/api_settings.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_background.dart';

/// 本地模型管理頁面
class LocalModelScreen extends StatefulWidget {
  const LocalModelScreen({super.key});

  @override
  State<LocalModelScreen> createState() => _LocalModelScreenState();
}

class _LocalModelScreenState extends State<LocalModelScreen> {
  int _deviceTotalRam = 0;
  int _availableRam = 0;
  int _availableStorage = 0;
  LocalModelInfo? _recommended;
  List<LocalModelInfo> _models = [];
  bool _importingModel = false;
  bool _deviceInfoRefreshing = false;
  int _deviceInfoLoadId = 0;
  bool _savingLocalApi = false;
  bool _obscureLocalApiKey = true;
  final _localApiBaseUrlCtrl = TextEditingController();
  final _localApiKeyCtrl = TextEditingController();
  final _localApiModelCtrl = TextEditingController();
  final Map<String, bool> _downloaded = {};
  final Map<String, double> _downloadProgress = {};
  final Map<String, bool> _downloading = {};
  final Map<String, int> _lastProgressUpdateMs = {};
  final Map<String, double> _downloadSpeed = {};
  final Map<String, int> _lastSpeedBytes = {};
  final Map<String, int> _lastSpeedTimeMs = {};
  final Map<String, ModelCompatibility> _compatibility = {};

  @override
  void initState() {
    super.initState();
    _loadLocalApiSettings();
    _loadDeviceInfo();
    _resumeBackgroundDownloads();
  }

  Future<void> _resumeBackgroundDownloads() async {
    final active = await LocalModelService.resumeActiveDownloads(
      onProgress: (key, progress) {
        if (!mounted) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        final last = _lastProgressUpdateMs[key] ?? 0;
        if (progress >= 1 || now - last >= 300) {
          _lastProgressUpdateMs[key] = now;

          // 計算下載速度
          final model = LocalModelService.availableModels
              .cast<LocalModelInfo?>()
              .firstWhere((m) => m!.key == key, orElse: () => null);
          if (model != null) {
            final currentBytes = (progress * model.sizeBytes).round();
            final prevBytes = _lastSpeedBytes[key] ?? 0;
            final prevTime = _lastSpeedTimeMs[key] ?? now;
            final timeDelta = (now - prevTime) / 1000.0;
            if (timeDelta > 0.1 && currentBytes > prevBytes) {
              _downloadSpeed[key] = (currentBytes - prevBytes) / timeDelta;
            }
            _lastSpeedBytes[key] = currentBytes;
            _lastSpeedTimeMs[key] = now;
          }

          setState(() => _downloadProgress[key] = progress);
        }
      },
      onComplete: (key) {
        if (!mounted) return;
        setState(() {
          _downloaded[key] = true;
          _downloading[key] = false;
          _downloadProgress[key] = 1;
          _downloadSpeed.remove(key);
          _lastSpeedBytes.remove(key);
          _lastSpeedTimeMs.remove(key);
        });
        _loadDeviceInfo();
      },
    );
    if (!mounted || active.isEmpty) return;
    setState(() {
      for (final entry in active.entries) {
        _downloading[entry.key] = true;
        _downloadProgress[entry.key] = entry.value;
      }
    });
  }

  @override
  void dispose() {
    ApiSettings.saveLocalApiBaseUrl(_localApiBaseUrlCtrl.text.trim());
    ApiSettings.saveLocalApiKey(_localApiKeyCtrl.text.trim());
    ApiSettings.saveLocalApiModel(_localApiModelCtrl.text.trim());
    _localApiBaseUrlCtrl.dispose();
    _localApiKeyCtrl.dispose();
    _localApiModelCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLocalApiSettings() async {
    final baseUrl = await ApiSettings.getLocalApiBaseUrl();
    final key = await ApiSettings.getLocalApiKey();
    final model = await ApiSettings.getLocalApiModel();
    if (!mounted) return;
    setState(() {
      _localApiBaseUrlCtrl.text = baseUrl;
      _localApiKeyCtrl.text = key;
      _localApiModelCtrl.text = model;
    });
  }

  Future<void> _loadDeviceInfo() async {
    final loadId = ++_deviceInfoLoadId;
    final models = await LocalModelService.getAllModels();

    final downloaded = <String, bool>{};
    for (final model in models) {
      downloaded[model.key] = await LocalModelService.isDownloadedFast(
        model.key,
      );
      await Future<void>.delayed(Duration.zero);
    }

    if (!mounted) return;
    setState(() {
      _models = models;
      _downloaded.clear();
      _downloaded.addAll(downloaded);
      _deviceInfoRefreshing = true;
    });
    unawaited(_refreshDeviceStatsInBackground(loadId, models));
  }

  Future<void> _refreshDeviceStatsInBackground(
    int loadId,
    List<LocalModelInfo> models,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 160));
    final totalRam = await LocalModelService.getDeviceTotalRam();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final availRam = await LocalModelService.getAvailableRam();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final storage = await LocalModelService.getAvailableStorage();

    final recommended = _recommendModelFromSnapshot(
      models,
      availableRam: availRam,
      availableStorage: storage,
    );
    final compat = <String, ModelCompatibility>{};
    for (final model in models) {
      compat[model.key] = _checkCompatibilityFromSnapshot(
        model,
        availableRam: availRam,
        availableStorage: storage,
      );
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }

    if (!mounted || loadId != _deviceInfoLoadId) return;
    setState(() {
      _deviceTotalRam = totalRam;
      _availableRam = availRam;
      _availableStorage = storage;
      _recommended = recommended;
      _compatibility.clear();
      _compatibility.addAll(compat);
      _deviceInfoRefreshing = false;
    });
  }

  LocalModelInfo? _recommendModelFromSnapshot(
    List<LocalModelInfo> models, {
    required int availableRam,
    required int availableStorage,
  }) {
    for (final model in models.reversed) {
      final estimatedUsage = (model.sizeBytes * 1.3).round();
      if (availableRam >= estimatedUsage * 1.3 &&
          availableStorage >= model.sizeBytes * 2) {
        return model;
      }
    }
    return null;
  }

  ModelCompatibility _checkCompatibilityFromSnapshot(
    LocalModelInfo model, {
    required int availableRam,
    required int availableStorage,
  }) {
    final estimatedUsage = (model.sizeBytes * 1.3).round();
    if (availableStorage < model.sizeBytes * 1.5) {
      return ModelCompatibility.storageInsufficient;
    }
    if (availableRam < estimatedUsage) {
      return ModelCompatibility.ramInsufficient;
    }
    if (availableRam >= estimatedUsage * 1.5) {
      return ModelCompatibility.recommended;
    }
    return ModelCompatibility.compatible;
  }

  Future<void> _handlePickLocalFile() async {
    setState(() => _importingModel = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['gguf', 'task', 'litertlm', 'bin'],
        allowMultiple: false,
        withData: false,
      );
      final path = result?.files.single.path;
      if (path == null || path.isEmpty) return;

      final model = await LocalModelService.registerExternalModelPath(path);
      await _loadDeviceInfo();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: '${model.nameEn} linked and starred.',
              zhTW: '已引用 ${model.name}，並自動星標。',
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${L.pick(en: 'Import failed', zhTW: '引用失敗')}：$e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _importingModel = false);
    }
  }

  Future<void> _handleSaveLocalApi() async {
    final baseUrl = _localApiBaseUrlCtrl.text.trim();
    final apiKey = _localApiKeyCtrl.text.trim();
    final model = _localApiModelCtrl.text.trim();

    if (baseUrl.isEmpty || model.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Base URL and model name are required',
              zhTW: '請填 Base URL 和模型名稱',
            ),
          ),
        ),
      );
      return;
    }

    setState(() => _savingLocalApi = true);
    try {
      await ApiSettings.saveLocalApiBaseUrl(baseUrl);
      await ApiSettings.saveLocalApiKey(apiKey);
      await ApiSettings.saveLocalApiModel(model);

      final modelId = ApiSettings.toLocalApiModelId(model);
      final starred = await ApiSettings.getStarredModels();
      if (!starred.contains(modelId)) {
        starred.add(modelId);
        await ApiSettings.saveStarredModels(starred);
      }
      await ApiSettings.saveModel(modelId);
      await ApiSettings.saveApiProvider('local_api');

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Local API saved and selected for chat.',
              zhTW: '本地 API 已保存，並設為當前聊天模型。',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingLocalApi = false);
    }
  }

  Future<void> _handleDownload(LocalModelInfo model) async {
    final compat = await LocalModelService.checkCompatibility(model);

    if (compat == ModelCompatibility.ramInsufficient) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(en: 'Not enough RAM for this model', zhTW: '記憶體不足，無法運行此模型'),
          ),
        ),
      );
      return;
    }
    if (compat == ModelCompatibility.storageInsufficient) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.pick(en: 'Not enough storage space', zhTW: '存儲空間不足')),
        ),
      );
      return;
    }

    setState(() {
      _downloading[model.key] = true;
      _downloadProgress[model.key] = 0;
      _lastProgressUpdateMs[model.key] = 0;
    });

    try {
      await LocalModelService.downloadModel(
        model,
        onProgress: (p) {
          if (!mounted) return;
          final now = DateTime.now().millisecondsSinceEpoch;
          final last = _lastProgressUpdateMs[model.key] ?? 0;
          if (p >= 1 || now - last >= 300) {
            _lastProgressUpdateMs[model.key] = now;

            // 計算下載速度
            final currentBytes = (p * model.sizeBytes).round();
            final prevBytes = _lastSpeedBytes[model.key] ?? 0;
            final prevTime = _lastSpeedTimeMs[model.key] ?? now;
            final timeDelta = (now - prevTime) / 1000.0;
            if (timeDelta > 0.1 && currentBytes > prevBytes) {
              _downloadSpeed[model.key] =
                  (currentBytes - prevBytes) / timeDelta;
            }
            _lastSpeedBytes[model.key] = currentBytes;
            _lastSpeedTimeMs[model.key] = now;

            setState(() => _downloadProgress[model.key] = p);
          }
        },
        onComplete: () {
          if (!mounted) return;
          setState(() {
            _downloaded[model.key] = true;
            _downloading[model.key] = false;
            _downloadProgress[model.key] = 1;
            _downloadSpeed.remove(model.key);
            _lastSpeedBytes.remove(model.key);
            _lastSpeedTimeMs.remove(model.key);
          });
          _loadDeviceInfo();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                L.pick(
                  en: '${model.nameEn} downloaded! Auto-starred for chat selection.',
                  zhTW: '${model.name} 下載完成！已自動星標，可在對話中選擇。',
                ),
              ),
            ),
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      // 主動取消時 _downloading 已被設為 false，跳過錯誤提示
      if (_downloading[model.key] != true) return;
      setState(() {
        _downloading[model.key] = false;
        _lastProgressUpdateMs.remove(model.key);
        _downloadSpeed.remove(model.key);
        _lastSpeedBytes.remove(model.key);
        _lastSpeedTimeMs.remove(model.key);
      });
      _loadDeviceInfo();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${L.pick(en: 'Download failed', zhTW: '下載失敗')}：$e'),
        ),
      );
    }
  }

  Future<void> _handleCancelDownload(LocalModelInfo model) async {
    setState(() {
      _downloading[model.key] = false;
      _downloadProgress.remove(model.key);
      _downloadSpeed.remove(model.key);
      _lastSpeedBytes.remove(model.key);
      _lastSpeedTimeMs.remove(model.key);
      _lastProgressUpdateMs.remove(model.key);
    });
    await LocalModelService.cancelDownload(model.key);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L.pick(en: 'Download cancelled', zhTW: '下載已取消')),
      ),
    );
  }

  String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String _formatDeviceValue(int bytes) {
    if (bytes > 0) return LocalModelService.formatSize(bytes);
    return _deviceInfoRefreshing
        ? (L.pick(en: 'Refreshing...', zhTW: '刷新中...'))
        : (L.pick(en: 'Unknown', zhTW: '未知'));
  }

  Color _availableRamColor() {
    if (_availableRam <= 0) return YanciTheme.textSecondary;
    if (_availableRam < 2 * 1024 * 1024 * 1024) return Colors.red;
    if (_availableRam < 4 * 1024 * 1024 * 1024) return Colors.orange;
    return Colors.green;
  }

  Future<void> _handleDelete(LocalModelInfo model) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.pick(en: 'Delete model?', zhTW: '刪除模型？')),
        content: Text(
          model.isCustom
              ? (L.pick(
                  en: 'Remove ${model.nameEn} from local model list? The original file will not be deleted.',
                  zhTW: '從本地模型列表移除 ${model.name}？不會刪除手機裡的原始檔案。',
                ))
              : (L.pick(
                  en: 'Delete ${model.nameEn}? This will free ${LocalModelService.formatSize(model.sizeBytes)} of storage.',
                  zhTW:
                      '刪除 ${model.name}？將釋放 ${LocalModelService.formatSize(model.sizeBytes)} 存儲空間。',
                )),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              model.isCustom
                  ? (L.pick(en: 'Remove', zhTW: '移除'))
                  : (L.pick(en: 'Delete', zhTW: '刪除')),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    await LocalModelService.deleteModel(model.key);
    if (!mounted) return;
    setState(() => _downloaded[model.key] = false);
    await _loadDeviceInfo();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              // ═══ 頂部標題列 ═══
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 20,
                        color: YanciTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      L.pick(en: 'Local Models', zhTW: '本地模型'),
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: YanciTheme.textPrimary,
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    ),
                  ],
                ),
              ),

              // ═══ 內容 ═══
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLocalApiCard(),
                      const SizedBox(height: 12),
                      _buildDeviceInfoCard(),
                      const SizedBox(height: 12),
                      _buildExternalModelCard(),
                      const SizedBox(height: 20),

                      if (_recommended != null) ...[
                        Text(
                          L.pick(
                            en: 'Recommended for your device:',
                            zhTW: '根據你的設備推薦：',
                          ),
                          style: TextStyle(
                            fontSize: 13,
                            color: YanciTheme.textSecondary,
                            fontFamily: YanciTheme.fontFamily,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],

                      ..._models.map(_buildModelCard),
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

  Widget _buildDeviceInfoCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YanciTheme.isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: YanciTheme.isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  L.pick(en: 'Device', zhTW: '設備狀態'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: YanciTheme.textPrimary,
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ),
              if (_deviceInfoRefreshing)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: YanciTheme.accent.withValues(alpha: 0.75),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _infoRow(
            L.pick(en: 'Total RAM', zhTW: '總記憶體'),
            _formatDeviceValue(_deviceTotalRam),
          ),
          const SizedBox(height: 4),
          _infoRow(
            L.pick(en: 'Available RAM', zhTW: '可用記憶體'),
            _formatDeviceValue(_availableRam),
            valueColor: _availableRamColor(),
          ),
          const SizedBox(height: 4),
          _infoRow(
            L.pick(en: 'Available storage', zhTW: '可用存儲'),
            _formatDeviceValue(_availableStorage),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () async {
              await LocalModelService.resetVulkanCache();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    L.pick(
                      en: 'GPU cache cleared — will retry on next load',
                      zhTW: 'GPU 快取已清除，下次加載時重新嘗試',
                    ),
                    style: TextStyle(fontFamily: YanciTheme.fontFamily),
                  ),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            child: Row(
              children: [
                Icon(
                  Icons.refresh_rounded,
                  size: 14,
                  color: YanciTheme.accent.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 6),
                Text(
                  L.pick(en: 'Reset GPU cache', zhTW: '重置 GPU 快取'),
                  style: TextStyle(
                    fontSize: 12,
                    color: YanciTheme.accent.withValues(alpha: 0.7),
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalApiCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YanciTheme.isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: YanciTheme.isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.dns_rounded, size: 18, color: YanciTheme.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  L.pick(en: 'Local API', zhTW: '本地 API'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: YanciTheme.textPrimary,
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            L.pick(
              en: 'Use an OpenAI-compatible server on your computer or LAN. On phones, use the computer LAN IP, not 127.0.0.1.',
              zhTW: L.pick(
                en: 'Connect to an OpenAI-compatible service on a computer or local network. On a phone, use the computer\'s LAN IP, not 127.0.0.1.',
                zhTW:
                    '連接電腦或局域網上的 OpenAI-compatible 服務。手機上要填電腦的局域網 IP，不是 127.0.0.1。',
              ),
            ),
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: YanciTheme.textSecondary,
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _localApiBaseUrlCtrl,
            keyboardType: TextInputType.url,
            style: TextStyle(
              fontSize: 13,
              color: YanciTheme.textPrimary,
              fontFamily: YanciTheme.fontFamily,
            ),
            decoration: _localApiInputDecoration(
              L.pick(
                en: 'Base URL, e.g. http://192.168.1.8:1234/v1',
                zhTW: 'Base URL，例如 http://192.168.1.8:1234/v1',
              ),
            ),
          ),
          Divider(
            height: 1,
            color: YanciTheme.textSecondary.withValues(alpha: 0.1),
          ),
          TextField(
            controller: _localApiKeyCtrl,
            obscureText: _obscureLocalApiKey,
            style: TextStyle(
              fontSize: 13,
              color: YanciTheme.textPrimary,
              fontFamily: YanciTheme.fontFamily,
            ),
            decoration: _localApiInputDecoration(
              L.pick(en: 'API Key (optional)', zhTW: 'API Key（可留空）'),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureLocalApiKey
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                  color: YanciTheme.textSecondary,
                ),
                onPressed: () =>
                    setState(() => _obscureLocalApiKey = !_obscureLocalApiKey),
              ),
            ),
          ),
          Divider(
            height: 1,
            color: YanciTheme.textSecondary.withValues(alpha: 0.1),
          ),
          TextField(
            controller: _localApiModelCtrl,
            style: TextStyle(
              fontSize: 13,
              color: YanciTheme.textPrimary,
              fontFamily: YanciTheme.fontFamily,
            ),
            decoration: _localApiInputDecoration(
              L.pick(en: 'Model name, e.g. qwen3-4b', zhTW: '模型名稱，例如 qwen3-4b'),
            ),
            onSubmitted: (_) => _handleSaveLocalApi(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _savingLocalApi ? null : _handleSaveLocalApi,
              icon: _savingLocalApi
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: YanciTheme.accent,
                      ),
                    )
                  : const Icon(Icons.check_rounded, size: 18),
              label: Text(
                _savingLocalApi
                    ? (L.pick(en: 'Saving...', zhTW: '保存中...'))
                    : (L.pick(en: 'Save and select', zhTW: '保存並設為當前')),
                style: TextStyle(fontFamily: YanciTheme.fontFamily),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: YanciTheme.accent,
                side: BorderSide(
                  color: YanciTheme.accent.withValues(alpha: 0.4),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _localApiInputDecoration(String hint, {Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        fontSize: 12,
        color: YanciTheme.textSecondary.withValues(alpha: 0.45),
        fontFamily: YanciTheme.fontFamily,
      ),
      border: InputBorder.none,
      isDense: true,
      suffixIcon: suffixIcon,
      suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    );
  }

  Widget _buildExternalModelCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YanciTheme.isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: YanciTheme.isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.folder_open_rounded,
                size: 18,
                color: YanciTheme.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  L.pick(en: 'Use a local model file', zhTW: '引用手機裡的模型檔'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: YanciTheme.textPrimary,
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            L.pick(
              en: 'Pick an existing .gguf, .task, .litertlm, or .bin file. It will be starred without downloading again.',
              zhTW: '選擇已下載的 .gguf、.task、.litertlm 或 .bin 檔案，會直接星標，不重新下載。',
            ),
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: YanciTheme.textSecondary,
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _importingModel ? null : _handlePickLocalFile,
              icon: _importingModel
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: YanciTheme.accent,
                      ),
                    )
                  : const Icon(Icons.add_rounded, size: 18),
              label: Text(
                _importingModel
                    ? (L.pick(en: 'Linking...', zhTW: '正在引用...'))
                    : (L.pick(en: 'Choose model file', zhTW: '選擇模型檔')),
                style: TextStyle(fontFamily: YanciTheme.fontFamily),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: YanciTheme.accent,
                side: BorderSide(
                  color: YanciTheme.accent.withValues(alpha: 0.4),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: YanciTheme.textSecondary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            color: valueColor ?? YanciTheme.textPrimary,
            fontWeight: FontWeight.w500,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
      ],
    );
  }

  Widget _buildModelCard(LocalModelInfo model) {
    final isDownloaded = _downloaded[model.key] ?? false;
    final isDownloading = _downloading[model.key] ?? false;
    final progress = _downloadProgress[model.key] ?? 0;
    final isRecommended = _recommended?.key == model.key;
    final compat = _compatibility[model.key];
    final isInsufficient =
        compat == ModelCompatibility.ramInsufficient ||
        compat == ModelCompatibility.storageInsufficient;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isInsufficient && !isDownloaded
            ? (YanciTheme.isDark
                  ? Colors.red.withValues(alpha: 0.05)
                  : Colors.red.withValues(alpha: 0.03))
            : (YanciTheme.isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.white.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isRecommended
              ? YanciTheme.accent.withValues(alpha: 0.4)
              : isInsufficient && !isDownloaded
              ? Colors.red.withValues(alpha: 0.2)
              : (YanciTheme.isDark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.black.withValues(alpha: 0.06)),
          width: isRecommended ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 標題行
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 4,
            children: [
              Text(
                L.pick(en: model.nameEn, zhTW: model.name),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isInsufficient && !isDownloaded
                      ? YanciTheme.textSecondary
                      : YanciTheme.textPrimary,
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: YanciTheme.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  model.quantization,
                  style: TextStyle(
                    fontSize: 10,
                    color: YanciTheme.accent,
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ),
              if (isRecommended)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    L.pick(en: 'Recommended', zhTW: '推薦'),
                    style: const TextStyle(fontSize: 10, color: Colors.green),
                  ),
                ),
              if (compat == ModelCompatibility.compatible && !isRecommended)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    L.pick(en: 'Tight', zhTW: '偏緊'),
                    style: const TextStyle(fontSize: 10, color: Colors.orange),
                  ),
                ),
              if (isInsufficient && !isDownloaded)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    compat == ModelCompatibility.ramInsufficient
                        ? (L.pick(en: 'RAM insufficient', zhTW: '記憶體不足'))
                        : (L.pick(en: 'Storage insufficient', zhTW: '存儲不足')),
                    style: const TextStyle(fontSize: 10, color: Colors.red),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 6),
          Text(
            L.pick(en: model.descriptionEn, zhTW: model.description),
            style: TextStyle(
              fontSize: 12,
              color: YanciTheme.textSecondary,
              fontFamily: YanciTheme.fontFamily,
            ),
          ),

          const SizedBox(height: 8),
          Text(
            LocalModelService.formatRequirement(model),
            style: TextStyle(
              fontSize: 11,
              color: YanciTheme.textSecondary.withValues(alpha: 0.7),
              fontFamily: YanciTheme.fontFamily,
            ),
          ),

          const SizedBox(height: 12),

          // 操作區
          if (isDownloading) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: YanciTheme.isDark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.black.withValues(alpha: 0.06),
                valueColor: AlwaysStoppedAnimation(YanciTheme.accent),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  '${(progress * 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 11,
                    color: YanciTheme.textSecondary,
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
                if ((_downloadSpeed[model.key] ?? 0) > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    _formatSpeed(_downloadSpeed[model.key]!),
                    style: TextStyle(
                      fontSize: 11,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.6),
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                ],
                const Spacer(),
                GestureDetector(
                  onTap: () => _handleCancelDownload(model),
                  child: Text(
                    L.pick(en: 'Cancel', zhTW: '取消'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.red.withValues(alpha: 0.7),
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                ),
              ],
            ),
          ] else if (model.isCustom && !isDownloaded) ...[
            Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: Colors.orange,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    L.pick(en: 'File unavailable', zhTW: '檔案不可用'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange,
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => _handleDelete(model),
                  child: Text(
                    L.pick(en: 'Remove', zhTW: '移除'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.red.withValues(alpha: 0.7),
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                ),
              ],
            ),
          ] else if (isDownloaded) ...[
            Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: Colors.green,
                ),
                const SizedBox(width: 6),
                Text(
                  model.isCustom
                      ? (L.pick(en: 'Linked · Starred', zhTW: '已引用 · 已星標'))
                      : (L.pick(en: 'Downloaded · Starred', zhTW: '已下載 · 已星標')),
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.green,
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => _handleDelete(model),
                  child: Text(
                    model.isCustom
                        ? (L.pick(en: 'Remove', zhTW: '移除'))
                        : (L.pick(en: 'Delete', zhTW: '刪除')),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.red.withValues(alpha: 0.7),
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => _handleDownload(model),
                style: OutlinedButton.styleFrom(
                  foregroundColor: YanciTheme.accent,
                  side: BorderSide(
                    color: YanciTheme.accent.withValues(alpha: 0.4),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: Text(
                  L.pick(
                    en: 'Download (${LocalModelService.formatSize(model.sizeBytes)})',
                    zhTW:
                        '下載（${LocalModelService.formatSize(model.sizeBytes)}）',
                  ),
                  style: TextStyle(fontFamily: YanciTheme.fontFamily),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
