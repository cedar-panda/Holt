import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:http/http.dart' as http;
import 'package:llamadart/llamadart.dart' as llama;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_adapter.dart';
import 'settings/api_settings.dart';
import 'locale_strings.dart';
import 'token_estimator.dart';

/// ═══════════════════════════════════════════════
/// 本地模型服務
/// ═══════════════════════════════════════════════
///
/// 職責：
/// - 設備 RAM / 存儲空間檢測 → 自動推薦模型
/// - 模型下載（斷點續傳 + 進度回調）
/// - 下載完成 → 自動加入星標模型列表
/// - 推理（implements ApiAdapter，與 API 共存）
///
/// 模型 ID 格式：`local:<model_key>`（如 local:qwen3-1.7b-q4）
/// 通過此前綴與 API 模型區分。
///

class LocalModelService implements ApiAdapter {
  // ─────────────────────────────────────────────
  // A. 模型目錄
  // ─────────────────────────────────────────────

  /// 可用模型清單
  /// 全部為已驗證存在的 uncensored / abliterated GGUF 直鏈，無需登入。
  static const List<LocalModelInfo> availableModels = [
    // ── Qwen3 系列（mlabonne abliteration → Mungert GGUF）──
    LocalModelInfo(
      key: 'qwen3-1.7b-q4',
      name: 'Qwen3 1.7B',
      nameEn: 'Qwen3 1.7B',
      quantization: 'Q4_K_M',
      sizeBytes: 1107409024, // HF x-linked-size: 1.03 GiB / 1.11 GB
      minRamBytes: 3 * 1024 * 1024 * 1024, // 3GB 最低
      recommendedRamBytes: 4 * 1024 * 1024 * 1024, // 4GB 推薦
      downloadUrl:
          'https://huggingface.co/Mungert/Qwen3-1.7B-abliterated-GGUF/resolve/e35bbde817ff7206b2800c792522ffe3325754b5/Qwen3-1.7B-abliterated-q4_k_m.gguf',
      expectedSha256:
          'cae49d3e29ddbe934b2c3cfcde39a69a8057195860677b6a9623cff4119ce6d7',
      description: '輕量伴侶模型，適合日常對話',
      descriptionEn: 'Lightweight companion model for daily chat',
      isDefault: true,
    ),
    LocalModelInfo(
      key: 'qwen3-4b-q4',
      name: 'Qwen3 4B',
      nameEn: 'Qwen3 4B',
      quantization: 'Q4_K_M',
      sizeBytes: 2497280736, // HF x-linked-size: 2.33 GiB / 2.50 GB
      minRamBytes: 4 * 1024 * 1024 * 1024, // 4GB 最低
      recommendedRamBytes: 6 * 1024 * 1024 * 1024, // 6GB 推薦
      downloadUrl:
          'https://huggingface.co/Mungert/Qwen3-4B-abliterated-GGUF/resolve/56175aed285a884480f49bb18d2a1b0e05a7749f/Qwen3-4B-abliterated-q4_k_m.gguf',
      expectedSha256:
          '2638dc26f9b18e5cd1cda97a2e649af7b2543e755ed3f14ab3825bd57ad57082',
      description: '進階伴侶模型，更好的理解力和表達',
      descriptionEn: 'Advanced companion model, better comprehension',
      isDefault: false,
    ),
    // ── Llama 3.2 系列（QuantFactory abliterated GGUF）──
    LocalModelInfo(
      key: 'llama3.2-3b-q4',
      name: 'Llama 3.2 3B',
      nameEn: 'Llama 3.2 3B',
      quantization: 'Q4_K_M',
      sizeBytes: 2019377472, // HF x-linked-size: 1.88 GiB / 2.02 GB
      minRamBytes: 3 * 1024 * 1024 * 1024, // 3GB 最低
      recommendedRamBytes: 4 * 1024 * 1024 * 1024, // 4GB 推薦
      downloadUrl:
          'https://huggingface.co/QuantFactory/Llama-3.2-3B-Instruct-abliterated-GGUF/resolve/120d74373f679f9d9e0463b435dfd3fb802d9eb0/Llama-3.2-3B-Instruct-abliterated.Q4_K_M.gguf',
      expectedSha256: '',
      description: 'Meta 通用模型，穩定均衡',
      descriptionEn: 'Meta general-purpose model, stable and balanced',
      isDefault: false,
    ),
    // ── Phi-4 系列（mradermacher imatrix abliterated GGUF）──
    LocalModelInfo(
      key: 'phi4-mini-q4',
      name: 'Phi-4 Mini 3.8B',
      nameEn: 'Phi-4 Mini 3.8B',
      quantization: 'Q4_K_M',
      sizeBytes: 2491875680, // HF x-linked-size: 2.32 GiB / 2.49 GB
      minRamBytes: 4 * 1024 * 1024 * 1024, // 4GB 最低
      recommendedRamBytes: 5 * 1024 * 1024 * 1024, // 5GB 推薦
      downloadUrl:
          'https://huggingface.co/mradermacher/Phi-4-mini-instruct-abliterated-i1-GGUF/resolve/c341f575d07990214b33e1c47f73e221d21a3009/Phi-4-mini-instruct-abliterated.i1-Q4_K_M.gguf',
      expectedSha256: '',
      description: 'Microsoft 推理模型，邏輯和數學較強',
      descriptionEn: 'Microsoft reasoning model, strong logic & math',
      isDefault: false,
    ),
    // ── Gemma 2 系列（Nidum uncensored GGUF）──
    LocalModelInfo(
      key: 'gemma2-nidum-2b-q4',
      name: 'Nidum Gemma 2B',
      nameEn: 'Nidum Gemma 2B',
      quantization: 'Q4_K_M',
      sizeBytes: 1630262304, // HF LFS size: 1.52 GiB / 1.63 GB
      minRamBytes: 3 * 1024 * 1024 * 1024,
      recommendedRamBytes: 4 * 1024 * 1024 * 1024,
      downloadUrl:
          'https://huggingface.co/osmapi/Nidum-Gemma-2B-Uncensored-GGUF/resolve/eba4cc8cfc927f1b65c1122efe47074f2f559043/Nidum-Limitless-Gemma-2B-Q4_K_M.gguf',
      expectedSha256:
          'ecba6019c7c635d4692c2827541db3ab221ef40e7d9642f3ed2b5d4ae8d16319',
      description: 'Gemma 2B 無護欄版本，手機端較平衡',
      descriptionEn: 'Uncensored Gemma 2B, balanced for phones',
      isDefault: false,
    ),
    // ── Gemma 4 系列（HauhauCS aggressive abliteration + imatrix）──
    LocalModelInfo(
      key: 'gemma4-e2b-q4',
      name: 'Gemma 4 E2B',
      nameEn: 'Gemma 4 E2B',
      quantization: 'Q4_K_P',
      sizeBytes: 3450277824, // HF x-linked-size: 3.21 GiB / 3.45 GB
      minRamBytes: 5 * 1024 * 1024 * 1024, // 5GB 最低
      recommendedRamBytes: 6 * 1024 * 1024 * 1024, // 6GB 推薦
      downloadUrl:
          'https://huggingface.co/HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive/resolve/da8593c3e407afcd3e7da94ff2d69d77e2a28a48/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive-Q4_K_P.gguf',
      expectedSha256:
          'aa866c1e514468f3d0f33971679d63c11b7c9c47acddd1cc5785fc467e52c21d',
      description: 'Google 端側模型，支持圖片+音頻輸入',
      descriptionEn: 'Google on-device model, image+audio input',
      isDefault: false,
    ),
    LocalModelInfo(
      key: 'gemma4-e4b-q4',
      name: 'Gemma 4 E4B',
      nameEn: 'Gemma 4 E4B',
      quantization: 'Q4_K_M',
      sizeBytes: 5335285728, // HF x-linked-size: 4.97 GiB / 5.34 GB
      minRamBytes: 6 * 1024 * 1024 * 1024, // 6GB 最低
      recommendedRamBytes: 8 * 1024 * 1024 * 1024, // 8GB 推薦
      downloadUrl:
          'https://huggingface.co/HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive/resolve/45b6a334b4bcd1d7f37179df58b3b1d66a184e5d/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf',
      expectedSha256:
          'd0027dd3a9128d9323e9f282c8bf010a8526c46477584535991dc1a869b56e96',
      description: 'Google 進階端側模型，更強的推理和對話',
      descriptionEn: 'Google advanced on-device, stronger reasoning',
      isDefault: false,
    ),
  ];

  // ─────────────────────────────────────────────
  // B. 設備檢測
  // ─────────────────────────────────────────────

  /// 獲取設備總 RAM（MemTotal，用於顯示）
  static Future<int> getDeviceTotalRam() async {
    try {
      if (Platform.isAndroid) {
        final memInfo = await File('/proc/meminfo').readAsString();
        final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(memInfo);
        if (match != null) {
          return int.parse(match.group(1)!) * 1024; // kB → bytes
        }
      }
      return 4 * 1024 * 1024 * 1024;
    } catch (_) {
      return 4 * 1024 * 1024 * 1024;
    }
  }

  /// 獲取當前可用 RAM（MemAvailable，用於判斷模型是否跑得動）
  /// MemAvailable 反映系統認為「不需要 swap 就能分配」的記憶體，
  /// 已扣除系統保留、AICore/TPU 鎖定、其他 App 佔用。
  static Future<int> getAvailableRam() async {
    try {
      if (Platform.isAndroid) {
        final memInfo = await File('/proc/meminfo').readAsString();
        final match = RegExp(r'MemAvailable:\s+(\d+)\s+kB').firstMatch(memInfo);
        if (match != null) {
          return int.parse(match.group(1)!) * 1024;
        }
      }
      return 4 * 1024 * 1024 * 1024;
    } catch (_) {
      return 4 * 1024 * 1024 * 1024;
    }
  }

  /// 向下相容：舊代碼調用 getDeviceRam() 的地方自動切到 available
  static Future<int> getDeviceRam() => getAvailableRam();

  /// 獲取可用存儲空間
  static Future<int> getAvailableStorage() async {
    try {
      if (Platform.isAndroid) {
        // 用外部存儲路徑（用戶看到的那個空間）
        final result = await Process.run('df', ['/storage/emulated/0']);
        final lines = (result.stdout as String).split('\n');
        if (lines.length > 1) {
          final parts = lines[1].split(RegExp(r'\s+'));
          if (parts.length > 3) {
            final availKB = int.tryParse(parts[3]) ?? 0;
            return availKB * 1024; // kB → bytes
          }
        }
      }
      // iOS / fallback
      await getApplicationDocumentsDirectory();
      // dart:io FileStat 不給磁盤空間，回退保守值
      return 10 * 1024 * 1024 * 1024;
    } catch (_) {
      return 10 * 1024 * 1024 * 1024;
    }
  }

  /// 根據設備狀態推薦模型
  /// 選可用記憶體能舒服跑的最大模型（available > usage × 1.3）
  static Future<LocalModelInfo?> recommendModel() async {
    final available = await getAvailableRam();
    final storage = await getAvailableStorage();

    for (final model in availableModels.reversed) {
      final estimatedUsage = (model.sizeBytes * 1.3).round();
      if (available >= estimatedUsage * 1.3 && storage >= model.sizeBytes * 2) {
        return model;
      }
    }
    return null;
  }

  /// 檢查設備是否能跑指定模型
  /// 使用 MemAvailable（實際可用），不看 MemTotal（總量騙人）。
  /// 預估運行佔用 ≈ 模型檔案 × 1.3（weights + KV cache + overhead）。
  static Future<ModelCompatibility> checkCompatibility(
    LocalModelInfo model,
  ) async {
    final available = await getAvailableRam();
    final storage = await getAvailableStorage();

    // 模型運行時實際佔用 ≈ 檔案大小 × 1.3
    final estimatedUsage = (model.sizeBytes * 1.3).round();

    if (storage < model.sizeBytes * 1.5) {
      return ModelCompatibility.storageInsufficient;
    }
    if (available < estimatedUsage) {
      return ModelCompatibility.ramInsufficient;
    }
    // 可用量是預估的 1.5 倍以上 → 寬裕
    if (available > estimatedUsage * 1.5) {
      return ModelCompatibility.recommended;
    }
    return ModelCompatibility.compatible;
  }

  // ─────────────────────────────────────────────
  // C. 下載管理
  // ─────────────────────────────────────────────

  static const String _keyDownloadedModels = 'local_downloaded_models';
  static const String _keyCustomModels = 'local_custom_models';
  static const String _downloadGroup = 'local_models';
  static const double _minCompleteRatio = 0.95;
  static bool _backgroundDownloaderStarted = false;
  static bool _flutterGemmaInitialized = false;
  static final Set<String> _cancelRequested = {};

  // ── enqueue 後台下載的回調管理 ──
  static final Map<String, Completer<void>> _downloadCompleters = {};
  static final Map<String, ValueChanged<double>?> _progressCallbacks = {};
  static final Map<String, VoidCallback?> _completeCallbacks = {};

  static Future<List<LocalModelInfo>> getAllModels() async {
    return [...availableModels, ...await getCustomModels()];
  }

  static Future<List<LocalModelInfo>> getCustomModels() async {
    final p = await SharedPreferences.getInstance();
    final encoded = p.getStringList(_keyCustomModels) ?? [];
    final models = <LocalModelInfo>[];
    for (final raw in encoded) {
      try {
        final data = jsonDecode(raw);
        if (data is Map<String, dynamic>) {
          models.add(LocalModelInfo.fromJson(data));
        }
      } catch (_) {
        // Ignore corrupt legacy entries instead of breaking model selection.
      }
    }
    return models;
  }

  static Future<LocalModelInfo> registerExternalModelPath(String path) async {
    if (kIsWeb) {
      throw Exception(
        L.locale == 'en'
            ? 'Browser builds cannot keep a permanent local file path. Use app download instead.'
            : '網頁版無法保存永久本機檔案路徑，請使用 App 內下載。',
      );
    }

    final file = File(path);
    if (!await file.exists()) {
      throw Exception(L.locale == 'en' ? 'Model file not found' : '找不到模型檔案');
    }

    final size = await file.length();
    if (size <= 0) {
      throw Exception(L.locale == 'en' ? 'Model file is empty' : '模型檔案是空的');
    }

    final ext = _extensionForPath(path);
    const supported = {'gguf', 'task', 'litertlm', 'bin'};
    if (!supported.contains(ext)) {
      throw Exception(
        L.locale == 'en' ? 'Unsupported model file .$ext' : '不支援的模型檔案 .$ext',
      );
    }

    if (ext == 'gguf' && !await _hasGgufHeader(file)) {
      throw Exception(
        L.locale == 'en'
            ? 'This file is not a valid GGUF model'
            : '這不是有效的 GGUF 模型檔',
      );
    }

    final verifiedBuiltIn = ext == 'gguf'
        ? await _verifiedBuiltInForExternalFile(file, size)
        : null;
    final filename = path.split(Platform.pathSeparator).last;
    final baseName = _stripExtension(filename);
    final hash = sha1
        .convert(utf8.encode('$path|$size'))
        .toString()
        .substring(0, 10);
    final key = verifiedBuiltIn == null
        ? 'custom-${_safeKey(baseName)}-$hash'
        : 'custom-${verifiedBuiltIn.key}-$hash';
    final model = LocalModelInfo(
      key: key,
      name: verifiedBuiltIn?.name ?? baseName,
      nameEn: verifiedBuiltIn?.nameEn ?? baseName,
      quantization:
          verifiedBuiltIn?.quantization ?? _quantizationFromName(baseName, ext),
      sizeBytes: size,
      minRamBytes: verifiedBuiltIn?.minRamBytes ?? _estimateMinRam(size),
      recommendedRamBytes:
          verifiedBuiltIn?.recommendedRamBytes ?? _estimateRecommendedRam(size),
      downloadUrl: '',
      expectedSha256: verifiedBuiltIn?.expectedSha256 ?? '',
      description: verifiedBuiltIn == null
          ? path
          : '${verifiedBuiltIn.description}\n$path',
      descriptionEn: verifiedBuiltIn == null
          ? path
          : '${verifiedBuiltIn.descriptionEn}\n$path',
      isDefault: false,
      localPath: path,
      isCustom: true,
    );

    final models = await getCustomModels();
    models.removeWhere((m) => m.localPath == path || m.key == key);
    models.add(model);
    await _saveCustomModels(models);
    await _markDownloaded(key);
    await _autoStar(key);
    return model;
  }

  static Future<LocalModelInfo?> _verifiedBuiltInForExternalFile(
    File file,
    int size,
  ) async {
    for (final model in availableModels) {
      if (model.expectedSha256.isEmpty || model.sizeBytes != size) continue;
      try {
        if (await _validateModelFile(file, model)) return model;
      } catch (_) {
        // Same byte length but different hash: treat it as an ordinary custom file.
      }
    }
    return null;
  }

  /// 初始化原生背景下載。iOS/Android 可在 App 退到背景後繼續下載。
  static Future<void> initializeBackgroundDownloads() async {
    if (kIsWeb || _backgroundDownloaderStarted) return;
    _backgroundDownloaderStarted = true;

    try {
      final downloader = FileDownloader();
      downloader.registerCallbacks(
        group: _downloadGroup,
        taskStatusCallback: (update) {
          final taskId = update.task.taskId;
          // 完成 / 失敗 / 取消 → 觸發 completer
          if (update.status == TaskStatus.complete) {
            unawaited(_handleBackgroundStatus(update));
            _completeCallbacks[taskId]?.call();
            final c = _downloadCompleters.remove(taskId);
            _progressCallbacks.remove(taskId);
            _completeCallbacks.remove(taskId);
            if (c != null && !c.isCompleted) c.complete();
          } else if (update.status == TaskStatus.failed ||
              update.status == TaskStatus.canceled ||
              update.status == TaskStatus.notFound) {
            final err = update.status == TaskStatus.canceled
                ? (L.locale == 'en' ? 'Download cancelled' : '下載已取消')
                : '下載失敗：${update.status.name}';
            final c = _downloadCompleters.remove(taskId);
            _progressCallbacks.remove(taskId);
            _completeCallbacks.remove(taskId);
            if (c != null && !c.isCompleted) c.completeError(Exception(err));
          }
        },
        taskProgressCallback: (update) {
          final taskId = update.task.taskId;
          final cb = _progressCallbacks[taskId];
          if (cb != null && update.progress >= 0) {
            cb(update.progress.clamp(0.0, 1.0));
          }
        },
      );
      downloader.configureNotification(
        running: const TaskNotification(
          'Holt',
          'Downloading {displayName} {progress}',
        ),
        complete: const TaskNotification('Holt', '{displayName} downloaded'),
        error: const TaskNotification('Holt', '{displayName} failed'),
        paused: const TaskNotification('Holt', '{displayName} paused'),
        progressBar: true,
      );
      downloader.configureNotificationForGroup(
        _downloadGroup,
        running: const TaskNotification(
          'Holt',
          'Downloading {displayName} {progress}',
        ),
        complete: const TaskNotification('Holt', '{displayName} downloaded'),
        error: const TaskNotification('Holt', '{displayName} failed'),
        paused: const TaskNotification('Holt', '{displayName} paused'),
        progressBar: true,
        groupNotificationId: _downloadGroup,
      );
      await downloader.configure(
        globalConfig: [(Config.requestTimeout, const Duration(minutes: 30))],
        androidConfig: [
          (Config.runInForegroundIfFileLargerThan, 100),
          (Config.useCacheDir, Config.never),
        ],
        iOSConfig: [
          (Config.resourceTimeout, const Duration(hours: 4)),
          (Config.excludeFromCloudBackup, true),
        ],
      );
      await downloader.start(autoCleanDatabase: true);
    } catch (e) {
      _backgroundDownloaderStarted = false;
      debugPrint('Local model background downloader unavailable: $e');
    }
  }

  /// 獲取模型存儲目錄
  static Future<Directory> _modelDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/local_models');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 獲取指定模型的文件路徑
  static Future<String> modelPath(String key) async {
    final dir = await _modelDir();
    final info = await findModel(key);
    if (info?.localPath.isNotEmpty == true) return info!.localPath;
    return '${dir.path}/$key.${_extensionForModel(info)}';
  }

  /// 已下載的模型列表
  static Future<List<String>> getDownloadedModels() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_keyDownloadedModels) ?? [];
  }

  /// 輕量檢查：文件存在 + size 匹配 + GGUF header，不做 SHA256
  /// 用於 initialize() 等運行時路徑，避免對 1~5GB 文件做全文哈希
  static Future<bool> isDownloadedFast(String key) async {
    final info = await findModel(key);
    final path = await modelPath(key);
    final file = File(path);
    if (!await file.exists()) return false;

    if (info != null) {
      final complete = await _isCompleteModelFile(file, info);
      if (!complete) return false;
    }

    // 確保 SharedPreferences 裡有記錄
    final downloaded = await getDownloadedModels();
    if (!downloaded.contains(key)) {
      await _markDownloaded(key);
      await _autoStar(key);
    }
    return true;
  }

  /// 完整檢查（含 SHA256）：僅用於下載完成後驗證
  /// 運行時路徑請用 isDownloadedFast
  static Future<bool> isDownloaded(String key) async {
    final downloaded = await getDownloadedModels();
    final info = await findModel(key);
    final path = await modelPath(key);
    final file = File(path);
    final complete = info == null
        ? await file.exists()
        : await _isCompleteModelFile(file, info);

    if (complete) {
      if (info?.expectedSha256.isNotEmpty == true) {
        try {
          await _validateModelFile(file, info!);
        } catch (_) {
          if (downloaded.contains(key)) {
            await _unmarkDownloaded(key);
            await _removeStar(key);
          }
          return false;
        }
      }
      if (!downloaded.contains(key)) {
        await _markDownloaded(key);
        await _autoStar(key);
      }
      return true;
    }

    if (downloaded.contains(key)) {
      await _unmarkDownloaded(key);
      await _removeStar(key);
    }
    return false;
  }

  /// 下載模型（帶進度回調 + 斷點續傳）
  /// [onProgress] 回調 0.0 ~ 1.0
  /// 返回本地文件路徑
  static Future<String> downloadModel(
    LocalModelInfo model, {
    ValueChanged<double>? onProgress,
    VoidCallback? onComplete,
  }) async {
    if (model.downloadUrl.isEmpty) {
      throw Exception('下載地址未配置');
    }
    _cancelRequested.remove(model.key);

    final path = await modelPath(model.key);
    final file = File(path);
    final tempPath = '$path.downloading';
    final tempFile = File(tempPath);

    if (await _validateModelFile(file, model)) {
      await _markDownloaded(model.key);
      await _autoStar(model.key);
      onProgress?.call(1);
      onComplete?.call();
      return path;
    }

    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      return _downloadModelInBackground(
        model,
        onProgress: onProgress,
        onComplete: onComplete,
      );
    }

    if (await file.exists() && !await tempFile.exists()) {
      await file.rename(tempPath);
    }

    int downloadedBytes = 0;
    if (await tempFile.exists()) {
      downloadedBytes = await tempFile.length();
    }

    final request = http.Request('GET', Uri.parse(model.downloadUrl));
    request.headers.addAll(_downloadHeaders(model));
    if (downloadedBytes > 0) {
      request.headers['Range'] = 'bytes=$downloadedBytes-';
    }

    final client = http.Client();
    try {
      final response = await client.send(request);
      var resumeAccepted = downloadedBytes > 0 && response.statusCode == 206;
      if (downloadedBytes > 0 && response.statusCode == 200) {
        await tempFile.delete();
        downloadedBytes = 0;
        resumeAccepted = false;
      }
      if (response.statusCode == 416 &&
          await _isCompleteModelFile(tempFile, model)) {
        if (await file.exists()) await file.delete();
        await tempFile.rename(path);
        await _markDownloaded(model.key);
        await _autoStar(model.key);
        onProgress?.call(1);
        onComplete?.call();
        return path;
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw Exception(
          '下載失敗 HTTP ${response.statusCode}: ${response.reasonPhrase ?? ''}',
        );
      }
      final contentType = response.headers['content-type'] ?? '';
      if (contentType.contains('text/html')) {
        throw Exception('下載地址返回 HTML，可能是模型鏈接失效或需要授權');
      }
      final contentRangeTotal = _parseContentRangeTotal(
        response.headers['content-range'],
      );
      final int expectedTotal;
      if (contentRangeTotal != null) {
        expectedTotal = contentRangeTotal;
      } else if (response.contentLength != null) {
        expectedTotal = resumeAccepted
            ? downloadedBytes + response.contentLength!
            : response.contentLength!;
      } else {
        expectedTotal = model.sizeBytes;
      }
      final totalBytes = expectedTotal > 0 ? expectedTotal : model.sizeBytes;

      final sink = tempFile.openWrite(
        mode: resumeAccepted ? FileMode.append : FileMode.writeOnly,
      );
      int received = downloadedBytes;

      try {
        await for (final chunk in response.stream) {
          if (_cancelRequested.contains(model.key)) {
            _cancelRequested.remove(model.key);
            throw Exception(L.locale == 'en' ? 'Download cancelled' : '下載已取消');
          }
          sink.add(chunk);
          received += chunk.length;
          if (totalBytes > 0) {
            onProgress?.call((received / totalBytes).clamp(0.0, 1.0));
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      if (!await _validateModelFile(
        tempFile,
        model,
        expectedBytes: totalBytes,
      )) {
        final size = await tempFile.length();
        throw Exception(
          '下載未完成：${formatSize(size)} / ${formatSize(totalBytes)}',
        );
      }

      // 下載完成，重命名
      if (await file.exists()) await file.delete();
      await tempFile.rename(path);

      // 記錄已下載
      await _markDownloaded(model.key);

      // 自動加入星標
      await _autoStar(model.key);

      onComplete?.call();
      return path;
    } finally {
      client.close();
    }
  }

  static Future<String> _downloadModelInBackground(
    LocalModelInfo model, {
    ValueChanged<double>? onProgress,
    VoidCallback? onComplete,
  }) async {
    await initializeBackgroundDownloads();

    final taskId = 'local_model_${model.key}';
    final task = DownloadTask(
      taskId: taskId,
      url: model.downloadUrl,
      headers: _downloadHeaders(model),
      filename: '${model.key}.${_extensionForModel(model)}',
      directory: 'local_models',
      baseDirectory: BaseDirectory.applicationDocuments,
      group: _downloadGroup,
      updates: Updates.statusAndProgress,
      retries: 5,
      allowPause: true,
      priority: 0,
      metaData: model.key,
      displayName: model.name,
    );

    // 註冊回調 → 讓 initializeBackgroundDownloads 裡的 registered callback 分發
    final completer = Completer<void>();
    _downloadCompleters[taskId] = completer;
    _progressCallbacks[taskId] = onProgress;
    _completeCallbacks[taskId] = onComplete;

    // enqueue：丟給 OS 原生下載管理器，app 退背景/殺掉都能繼續
    final ok = await FileDownloader().enqueue(task);
    if (!ok) {
      _downloadCompleters.remove(taskId);
      _progressCallbacks.remove(taskId);
      _completeCallbacks.remove(taskId);
      throw Exception(L.locale == 'en' ? 'Failed to start download' : '無法啟動下載');
    }

    // 等待完成（由 registered taskStatusCallback 觸發 completer）
    await completer.future;
    _cancelRequested.remove(model.key);

    final path = await modelPath(model.key);
    final file = File(path);
    if (!await _validateModelFile(file, model)) {
      if (await file.exists()) await file.delete();
      throw Exception(
        L.locale == 'en'
            ? 'Downloaded file verification failed'
            : '下載檔案驗證失敗，請稍後重試或更換下載源',
      );
    }

    await _markDownloaded(model.key);
    await _autoStar(model.key);
    onProgress?.call(1);
    return path;
  }

  /// App 恢復時檢查並恢復正在進行的下載進度追蹤
  /// 返回正在下載的 model key → 當前進度 map
  static Future<Map<String, double>> resumeActiveDownloads({
    void Function(String key, double progress)? onProgress,
    void Function(String key)? onComplete,
  }) async {
    if (kIsWeb) return {};
    await initializeBackgroundDownloads();

    final result = <String, double>{};
    final records = await FileDownloader().database.allRecords(
      group: _downloadGroup,
    );
    for (final record in records) {
      final key = record.task.metaData;
      if (key.isEmpty) continue;

      if (record.status == TaskStatus.complete) {
        // 後台已下載完成但 app 不在前台沒收到回調
        final info = await findModel(key);
        if (info != null) {
          await _markDownloaded(key);
          await _autoStar(key);
          onComplete?.call(key);
        }
        debugPrint('Background download already complete for $key');
        continue;
      }

      if (record.status == TaskStatus.running ||
          record.status == TaskStatus.enqueued ||
          record.status == TaskStatus.waitingToRetry) {
        final taskId = record.task.taskId;
        final progress = record.progress.clamp(0.0, 1.0);
        result[key] = progress;

        // 重新掛回調，讓後續進度能推送到 UI
        if (!_downloadCompleters.containsKey(taskId)) {
          final completer = Completer<void>();
          _downloadCompleters[taskId] = completer;
        }
        _progressCallbacks[taskId] = (p) => onProgress?.call(key, p);
        _completeCallbacks[taskId] = () => onComplete?.call(key);

        debugPrint(
          'Resuming download tracking for $key at ${(progress * 100).toStringAsFixed(1)}%',
        );
      }
    }
    return result;
  }

  /// 取消正在進行的下載
  static Future<void> cancelDownload(String key) async {
    _cancelRequested.add(key);
    final taskId = 'local_model_$key';
    // 取消背景下載任務（Android/iOS）
    try {
      await FileDownloader().cancelTaskWithId(taskId);
    } catch (_) {}
    // 清理 completer（如果 cancel callback 沒觸發）
    final c = _downloadCompleters.remove(taskId);
    _progressCallbacks.remove(taskId);
    _completeCallbacks.remove(taskId);
    if (c != null && !c.isCompleted) {
      c.completeError(
        Exception(L.locale == 'en' ? 'Download cancelled' : '下載已取消'),
      );
    }
  }

  /// 刪除已下載的模型
  static Future<void> deleteModel(String key) async {
    final info = await findModel(key);
    if (info?.isCustom == true) {
      await _removeCustomModel(key);
      await _unmarkDownloaded(key);
      await _removeStar(key);
      return;
    }

    final path = await modelPath(key);
    final file = File(path);
    if (await file.exists()) await file.delete();

    // 刪除下載中的臨時文件
    final tempFile = File('$path.downloading');
    if (await tempFile.exists()) await tempFile.delete();

    // 從已下載列表移除
    await _unmarkDownloaded(key);

    // 從星標移除
    await _removeStar(key);
  }

  /// 獲取已下載模型佔用的總空間
  static Future<int> totalDownloadedSize() async {
    int total = 0;
    for (final model in await getAllModels()) {
      if (!await isDownloaded(model.key)) continue;
      final path = await modelPath(model.key);
      final file = File(path);
      if (await file.exists()) {
        total += await file.length();
      }
    }
    return total;
  }

  // ─────────────────────────────────────────────
  // D. 星標管理（與 API 模型共存）
  // ─────────────────────────────────────────────

  /// 本地模型的 model ID 格式：`local:<key>`
  static String toModelId(String key) => 'local:$key';

  /// 判斷是否是本地模型 ID
  static bool isLocalModelId(String modelId) => modelId.startsWith('local:');

  /// 從 model ID 提取 key
  static String extractKey(String modelId) =>
      modelId.startsWith('local:') ? modelId.substring(6) : modelId;

  static String fallbackDisplayNameForKey(String key) {
    if (!key.startsWith('custom-')) return key;
    final withoutPrefix = key.substring('custom-'.length);
    final withoutHash = withoutPrefix.replaceFirst(
      RegExp(r'-[a-f0-9]{10}$'),
      '',
    );
    return withoutHash.replaceAll('-', ' ');
  }

  static LocalModelInfo? _findBuiltInModel(String key) {
    for (final model in availableModels) {
      if (model.key == key) return model;
    }
    return null;
  }

  static Future<LocalModelInfo?> findModel(String key) async {
    final builtIn = _findBuiltInModel(key);
    if (builtIn != null) return builtIn;
    for (final model in await getCustomModels()) {
      if (model.key == key) return model;
    }
    return null;
  }

  static String _extensionForModel(LocalModelInfo? model) {
    if (model == null) return 'gguf';
    if (model.localPath.isNotEmpty) return _extensionForPath(model.localPath);
    if (model.downloadUrl.isEmpty) return 'gguf';
    final path = Uri.tryParse(model.downloadUrl)?.path ?? model.downloadUrl;
    return _extensionForPath(path.split('/').last);
  }

  static Map<String, String> _downloadHeaders(LocalModelInfo model) {
    return {
      'Accept': 'application/octet-stream',
      'User-Agent': 'Holt/1.0 local-model-downloader',
      'Known-Content-Length': model.sizeBytes.toString(),
    };
  }

  static String _extensionForPath(String path) {
    final filename = path.split('/').last;
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return 'gguf';
    return filename.substring(dot + 1).toLowerCase();
  }

  static String _stripExtension(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot <= 0) return filename;
    return filename.substring(0, dot);
  }

  static String _safeKey(String value) {
    final normalized = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (normalized.isEmpty) return 'model';
    return normalized.length > 36 ? normalized.substring(0, 36) : normalized;
  }

  static String _quantizationFromName(String name, String ext) {
    final match = RegExp(
      r'(iq\d_[a-z0-9]+|q\d_[a-z]_[a-z]|q\d_[a-z0-9]+|bf16|f16|q8_0)',
      caseSensitive: false,
    ).firstMatch(name);
    if (match != null) return match.group(1)!.toUpperCase();
    return ext.toUpperCase();
  }

  static int _estimateMinRam(int sizeBytes) {
    final estimate = (sizeBytes * 1.35).round();
    const floor = 3 * 1024 * 1024 * 1024;
    return estimate < floor ? floor : estimate;
  }

  static int _estimateRecommendedRam(int sizeBytes) {
    final estimate = (sizeBytes * 1.8).round();
    const floor = 4 * 1024 * 1024 * 1024;
    return estimate < floor ? floor : estimate;
  }

  static Future<bool> _hasGgufHeader(File file) async {
    final raf = await file.open();
    try {
      final header = await raf.read(4);
      return header.length == 4 &&
          header[0] == 0x47 &&
          header[1] == 0x47 &&
          header[2] == 0x55 &&
          header[3] == 0x46;
    } finally {
      await raf.close();
    }
  }

  static gemma.ModelFileType? _gemmaFileTypeForPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'task' => gemma.ModelFileType.task,
      'litertlm' => gemma.ModelFileType.litertlm,
      'bin' => gemma.ModelFileType.binary,
      _ => null,
    };
  }

  static gemma.ModelType _gemmaModelTypeForKey(String key) {
    final lower = key.toLowerCase();
    if (lower.contains('qwen3')) return gemma.ModelType.qwen3;
    if (lower.contains('qwen')) return gemma.ModelType.qwen;
    if (lower.contains('deepseek')) return gemma.ModelType.deepSeek;
    if (lower.contains('phi')) return gemma.ModelType.phi;
    if (lower.contains('gemma4')) return gemma.ModelType.gemma4;
    if (lower.contains('gemma')) return gemma.ModelType.gemmaIt;
    return gemma.ModelType.general;
  }

  static Future<void> _ensureFlutterGemmaInitialized() async {
    if (_flutterGemmaInitialized) return;
    await gemma.FlutterGemma.initialize();
    _flutterGemmaInitialized = true;
  }

  static Future<bool> _isCompleteModelFile(
    File file,
    LocalModelInfo model, {
    int? expectedBytes,
  }) async {
    if (!await file.exists()) return false;
    final size = await file.length();
    final expected = expectedBytes ?? model.sizeBytes;
    if (expected <= 0) return size > 0;
    if (expectedBytes != null ||
        model.expectedSha256.isNotEmpty ||
        model.isCustom) {
      // expectedBytes 來自 Content-Length，是精確值 → 必須完全一致。
      // 0.95 的寬容比例只留給「目錄裡手填的估計大小」這種粗值，
      // 否則缺尾 5% 的截斷模型會被當成完整文件收下（GGUF 魔數在文件頭，
      // 截尾檢測不到），載入時才崩。
      if (size != expected) return false;
    } else if (size < (expected * _minCompleteRatio).round()) {
      return false;
    }
    if (_extensionForModel(model) == 'gguf' && !await _hasGgufHeader(file)) {
      return false;
    }
    return true;
  }

  static Future<bool> _validateModelFile(
    File file,
    LocalModelInfo model, {
    int? expectedBytes,
  }) async {
    if (!await _isCompleteModelFile(
      file,
      model,
      expectedBytes: expectedBytes,
    )) {
      return false;
    }
    if (model.expectedSha256.isEmpty) return true;
    final actual = await _sha256ForFile(file);
    if (actual == model.expectedSha256.toLowerCase()) return true;
    throw Exception(
      L.locale == 'en'
          ? 'Model checksum mismatch. Source may have changed or the download is corrupt.'
          : '模型校驗失敗：來源可能已變更，或下載檔案已損壞。',
    );
  }

  static Future<String> _sha256ForFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase();
  }

  static int? _parseContentRangeTotal(String? value) {
    if (value == null) return null;
    final match = RegExp(r'/(\d+)$').firstMatch(value);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  static Future<void> _markDownloaded(String key) async {
    final p = await SharedPreferences.getInstance();
    final downloaded = p.getStringList(_keyDownloadedModels) ?? [];
    if (!downloaded.contains(key)) {
      downloaded.add(key);
      await p.setStringList(_keyDownloadedModels, downloaded);
    }
  }

  static Future<void> _saveCustomModels(List<LocalModelInfo> models) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
      _keyCustomModels,
      models.map((m) => jsonEncode(m.toJson())).toList(),
    );
  }

  static Future<void> _removeCustomModel(String key) async {
    final models = await getCustomModels();
    models.removeWhere((m) => m.key == key);
    await _saveCustomModels(models);
  }

  static Future<void> _unmarkDownloaded(String key) async {
    final p = await SharedPreferences.getInstance();
    final downloaded = p.getStringList(_keyDownloadedModels) ?? [];
    if (downloaded.remove(key)) {
      await p.setStringList(_keyDownloadedModels, downloaded);
    }
  }

  static Future<void> _handleBackgroundStatus(TaskStatusUpdate update) async {
    if (update.status != TaskStatus.complete) return;
    final key = update.task.metaData;
    final info = await findModel(key);
    if (info == null) return;
    final path = await modelPath(key);
    final file = File(path);
    if (!await _isCompleteModelFile(file, info)) return;
    await _markDownloaded(key);
    await _autoStar(key);
  }

  /// 下載完成後自動加入星標
  static Future<void> _autoStar(String key) async {
    final modelId = toModelId(key);
    final starred = await ApiSettings.getStarredModels();
    if (!starred.contains(modelId)) {
      starred.add(modelId);
      await ApiSettings.saveStarredModels(starred);
    }
  }

  /// 刪除模型時移除星標
  static Future<void> _removeStar(String key) async {
    final modelId = toModelId(key);
    final starred = await ApiSettings.getStarredModels();
    starred.remove(modelId);
    await ApiSettings.saveStarredModels(starred);
  }

  /// 獲取所有本地模型的顯示信息（給模型選擇器用）
  static Future<List<Map<String, String>>> downloadedModelEntries() async {
    final entries = <Map<String, String>>[];
    for (final info in await getAllModels()) {
      if (await isDownloadedFast(info.key)) {
        entries.add({
          'id': toModelId(info.key),
          'name': L.locale == 'en' ? '📱 ${info.nameEn}' : '📱 ${info.name}',
        });
      }
    }
    return entries;
  }

  // ─────────────────────────────────────────────
  // E. 推理（ApiAdapter 實現）
  // ─────────────────────────────────────────────

  final String _modelKey;
  String? _loadedModelPath;
  LocalModelInfo? _loadedModelInfo;
  gemma.InferenceModel? _gemmaModel;
  llama.LlamaEngine? _llamaEngine;
  Future<void> _inferenceQueue = Future.value();
  int _llamaGenerationMaxTokens = 768;
  int _llamaContextSize = 2048;
  bool _llamaCpuBackend = false;

  LocalModelService({required String modelKey}) : _modelKey = modelKey;

  // 推理安全閥：超時 + 卡住偵測
  static const Duration _inferenceTimeout = Duration(minutes: 5);
  static const Duration _tokenStallTimeout = Duration(minutes: 2);
  // 首 token 容忍更久：CPU prompt 處理（prefill）比 GPU 慢得多
  static const Duration _firstTokenTimeout = Duration(seconds: 180);

  /// 初始化模型（加載到內存）
  /// 用輕量檢查（file exists + size + header）取代 SHA256 全文校驗，
  /// SHA256 只在下載完成時做一次，運行時不再重複。
  /// 加載前檢查設備 RAM 是否足夠，防止跑到系統崩潰。
  Future<bool> initialize() async {
    final ready = await isDownloadedFast(_modelKey);
    if (!ready) return false;

    // ═══ RAM 預檢：用 MemAvailable 判斷，不看 MemTotal ═══
    final info = await findModel(_modelKey);
    if (info != null) {
      final available = await getAvailableRam();
      final estimatedUsage = (info.sizeBytes * 1.3).round();
      if (available < estimatedUsage) {
        final need = formatSize(estimatedUsage);
        final have = formatSize(available);
        throw Exception(
          L.locale == 'en'
              ? 'Not enough available RAM. Need ~$need, currently available $have. Close other apps or try a smaller model.'
              : '可用記憶體不足。預估需要 ~$need，當前可用 $have。請關閉其他 App 或嘗試更小的模型。',
        );
      }
    }

    _loadedModelPath = await modelPath(_modelKey);
    final ext = _loadedModelPath!.split('.').last.toLowerCase();

    if (ext == 'gguf') {
      final info = await findModel(_modelKey);
      _loadedModelInfo = info;
      final ctxSize = await _adaptiveContextSize(info);
      _llamaContextSize = ctxSize;
      _llamaGenerationMaxTokens = _adaptiveLlamaMaxTokens(info);
      _llamaEngine = llama.LlamaEngine(llama.LlamaBackend());
      await _llamaEngine!.setLogLevel(llama.LlamaLogLevel.none);
      await _loadLlamaModelWithBestBackend(
        _loadedModelPath!,
        info,
        contextSize: ctxSize,
      );
      return true;
    }

    final fileType = _gemmaFileTypeForPath(_loadedModelPath!);
    if (fileType == null) {
      throw Exception(
        L.locale == 'en'
            ? 'Local model format .$ext is downloaded, but no local runtime is configured for it.'
            : '本地模型 .$ext 已下載，但目前沒有可用的本地推理引擎。',
      );
    }

    await _ensureFlutterGemmaInitialized();
    await gemma.FlutterGemma.installModel(
      modelType: _gemmaModelTypeForKey(_modelKey),
      fileType: fileType,
    ).fromFile(_loadedModelPath!).install();

    // ═══ 自適應 maxTokens（只影響本地，不影響 API）═══
    final gemmaMaxTokens = await _adaptiveGemmaMaxTokens(info);

    // ═══ GPU → CPU fallback（跟 llamadart Vulkan 策略同理）═══
    _gpuCanaryCleared = false;
    final prefs = await SharedPreferences.getInstance();

    final gpuCanaryKey = _modelScopedKey(_keyGpuInferenceCanary, info);
    final gpuCanaryLevelKey = _modelScopedKey(_keyGpuCanaryLevel, info);

    // Crash canary 偵測（Gemma GPU 推理崩潰）
    final gemmaCanary = prefs.getBool(gpuCanaryKey) ?? false;
    if (gemmaCanary) {
      debugPrint('Crash canary detected for Gemma GPU! Forcing CPU.');
      await prefs.setBool('gemma_gpu_failed', true);
      await prefs.remove(gpuCanaryKey);
      await prefs.remove(gpuCanaryLevelKey);
    }

    final gemmaGpuFailed = prefs.getBool('gemma_gpu_failed') ?? false;

    if (!gemmaGpuFailed) {
      try {
        _gemmaModel = await gemma.FlutterGemma.getActiveModel(
          maxTokens: gemmaMaxTokens,
          preferredBackend: gemma.PreferredBackend.gpu,
        );
        debugPrint('Gemma loaded with GPU, maxTokens=$gemmaMaxTokens');
        // 埋金絲雀
        await prefs.setBool(gpuCanaryKey, true);
        await prefs.setInt(gpuCanaryLevelKey, 0);
        return true;
      } catch (e) {
        debugPrint('Gemma GPU failed: $e — falling back to CPU');
        await prefs.setBool('gemma_gpu_failed', true);
        await prefs.remove(gpuCanaryKey);
        // 清理可能的殘留狀態
        _gemmaModel = null;
      }
    }

    // CPU fallback（maxTokens 再壓一級保穩定）
    final cpuMaxTokens = (gemmaMaxTokens * 0.75).round().clamp(512, 2048);
    _gemmaModel = await gemma.FlutterGemma.getActiveModel(
      maxTokens: cpuMaxTokens,
      preferredBackend: gemma.PreferredBackend.cpu,
    );
    debugPrint('Gemma loaded with CPU fallback, maxTokens=$cpuMaxTokens');

    return true;
  }

  /// Gemma 自適應 maxTokens：根據 RAM headroom 動態調整
  /// API 端不受影響，API 默認 4096 走 adapter 自己的參數
  static Future<int> _adaptiveGemmaMaxTokens(LocalModelInfo? info) async {
    if (info == null) return 2048;
    final ram = await getDeviceRam();
    final headroom = ram - info.sizeBytes;
    // 模型 size 的 1.5 倍以上空間 → 4096
    if (headroom > info.sizeBytes * 1.5) return 4096;
    // 1.0 倍 → 2048
    if (headroom > info.sizeBytes * 1.0) return 2048;
    // 很緊 → 1024
    debugPrint(
      'Gemma RAM headroom tight (${formatSize(headroom)}), maxTokens=1024',
    );
    return 1024;
  }

  /// 清除 Gemma GPU 失敗快取（設定頁手動重置用）
  static Future<void> resetGemmaGpuCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('gemma_gpu_failed');
  }

  // Vulkan 分級策略快取 key
  static const String _keyVulkanFailed = 'local_vulkan_failed';
  // 0 = 未嘗試, 1 = 全層失敗, 2 = 半層也失敗（純 CPU）
  static const String _keyVulkanFailLevel = 'local_vulkan_fail_level';
  // Crash canary：GPU 推理崩潰金絲雀
  // 加載成功後設 true，第一個 token 成功後清除。
  // 如果 app 在推理時 ANR/crash，flag 來不及清 → 下次啟動偵測到 → 自動降級。
  static const String _keyGpuInferenceCanary = 'local_gpu_inference_canary';
  // 記錄 canary 被設定時的 Vulkan fail level，用於精確降級
  static const String _keyGpuCanaryLevel = 'local_gpu_canary_level';
  bool _gpuCanaryCleared = false;

  String _modelScopedKey(String prefix, LocalModelInfo? info) {
    return '$prefix.${info?.key ?? _modelKey}';
  }

  Future<void> _loadLlamaModelWithBestBackend(
    String modelPath,
    LocalModelInfo? info, {
    int contextSize = 4096,
  }) async {
    _gpuCanaryCleared = false;

    if (!kIsWeb && Platform.isAndroid) {
      // 未校驗的自定義模型先走 CPU；已匹配內建 SHA 的引用模型仍允許 GPU。
      final unverifiedCustom =
          info?.isCustom == true && (info?.expectedSha256.isEmpty ?? true);
      if (unverifiedCustom) {
        debugPrint('Custom model: forcing CPU backend to avoid GPU contention');
        await _llamaEngine!.loadModel(
          modelPath,
          modelParams: _llamaModelParams(
            info,
            preferredBackend: llama.GpuBackend.cpu,
            gpuLayers: 0,
            contextSize: contextSize.clamp(512, 2048),
          ),
        );
        _llamaCpuBackend = true;
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final failLevelKey = _modelScopedKey(_keyVulkanFailLevel, info);
      final gpuCanaryKey = _modelScopedKey(_keyGpuInferenceCanary, info);
      final gpuCanaryLevelKey = _modelScopedKey(_keyGpuCanaryLevel, info);

      // 舊版是全局 GPU 失敗快取，會讓大模型牽連小模型；升級後直接丟棄。
      if (prefs.containsKey(_keyVulkanFailed) ||
          prefs.containsKey(_keyVulkanFailLevel) ||
          prefs.containsKey(_keyGpuInferenceCanary) ||
          prefs.containsKey(_keyGpuCanaryLevel)) {
        await prefs.remove(_keyVulkanFailed);
        await prefs.remove(_keyVulkanFailLevel);
        await prefs.remove(_keyGpuInferenceCanary);
        await prefs.remove(_keyGpuCanaryLevel);
      }

      // ═══ Crash canary 偵測 ═══
      // 上次 GPU 加載成功但推理時 ANR/crash → canary flag 沒被清掉
      // GPU 推理崩潰 = GPU 資源競爭，半層 Vulkan 也會撞，直接跳到 CPU
      final canaryAlive = prefs.getBool(gpuCanaryKey) ?? false;
      if (canaryAlive) {
        await prefs.setInt(failLevelKey, 2); // 直接 CPU
        await prefs.remove(gpuCanaryKey);
        await prefs.remove(gpuCanaryLevelKey);
        debugPrint(
          'Crash canary detected! GPU inference crashed last time. '
          'Jumping straight to CPU backend.',
        );
      }

      final failLevel = prefs.getInt(failLevelKey) ?? 0;

      // ── 第一級：Vulkan 全層 offload ──
      if (failLevel < 1) {
        try {
          await _llamaEngine!.loadModel(
            modelPath,
            modelParams: _llamaModelParams(
              info,
              preferredBackend: llama.GpuBackend.vulkan,
              gpuLayers: llama.ModelParams.maxGpuLayers,
              contextSize: contextSize,
            ),
          );
          debugPrint('Local GGUF loaded with Vulkan full offload');
          _llamaCpuBackend = false;
          // 埋金絲雀：推理成功後才清
          await prefs.setBool(gpuCanaryKey, true);
          await prefs.setInt(gpuCanaryLevelKey, 0);
          return;
        } catch (e) {
          debugPrint('Vulkan full offload failed: $e');
          await prefs.setInt(failLevelKey, 1);
          await _resetLlamaEngine();
        }
      }

      // ── 第二級：Vulkan 部分 offload（~40% 層）──
      if (failLevel < 2) {
        try {
          final partialLayers = _estimatePartialGpuLayers(info);
          await _llamaEngine!.loadModel(
            modelPath,
            modelParams: _llamaModelParams(
              info,
              preferredBackend: llama.GpuBackend.vulkan,
              gpuLayers: partialLayers,
              contextSize: contextSize,
            ),
          );
          debugPrint(
            'Local GGUF loaded with Vulkan partial offload ($partialLayers layers)',
          );
          _llamaCpuBackend = false;
          // 埋金絲雀
          await prefs.setBool(gpuCanaryKey, true);
          await prefs.setInt(gpuCanaryLevelKey, 1);
          return;
        } catch (e) {
          debugPrint('Vulkan partial offload failed: $e');
          await prefs.setInt(failLevelKey, 2);
          await _resetLlamaEngine();
        }
      }

      debugPrint('Using CPU backend (Vulkan exhausted)');
    }

    // ── 最終：CPU（Android）或 auto（桌面）──
    await _llamaEngine!.loadModel(
      modelPath,
      modelParams: _llamaModelParams(
        info,
        preferredBackend: !kIsWeb && Platform.isAndroid
            ? llama.GpuBackend.cpu
            : llama.GpuBackend.auto,
        gpuLayers: !kIsWeb && Platform.isAndroid
            ? 0
            : llama.ModelParams.maxGpuLayers,
        contextSize: contextSize,
      ),
    );
    _llamaCpuBackend = !kIsWeb && Platform.isAndroid;
  }

  /// 重置 llama engine（Vulkan 失敗後需要重建）
  Future<void> _resetLlamaEngine() async {
    await _llamaEngine?.dispose();
    _llamaEngine = llama.LlamaEngine(llama.LlamaBackend());
    await _llamaEngine!.setLogLevel(llama.LlamaLogLevel.none);
  }

  /// 清除 Vulkan 失敗快取，下次加載會重新嘗試全層 offload
  /// 適用於系統更新後重試
  static Future<void> resetVulkanCache() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (key == _keyVulkanFailed ||
          key == _keyVulkanFailLevel ||
          key == _keyGpuInferenceCanary ||
          key == _keyGpuCanaryLevel ||
          key.startsWith('$_keyVulkanFailLevel.') ||
          key.startsWith('$_keyGpuInferenceCanary.') ||
          key.startsWith('$_keyGpuCanaryLevel.')) {
        await prefs.remove(key);
      }
    }
    debugPrint(
      'Vulkan fail cache cleared — will retry GPU offload on next load',
    );
  }

  /// 推理成功後清除金絲雀 flag
  Future<void> _clearGpuCanary(LocalModelInfo? info) async {
    final prefs = await SharedPreferences.getInstance();
    final gpuCanaryKey = _modelScopedKey(_keyGpuInferenceCanary, info);
    final gpuCanaryLevelKey = _modelScopedKey(_keyGpuCanaryLevel, info);
    if (prefs.getBool(gpuCanaryKey) ?? false) {
      await prefs.remove(gpuCanaryKey);
      await prefs.remove(gpuCanaryLevelKey);
      debugPrint('GPU inference canary cleared — GPU is stable');
    }
  }

  /// 估算部分 offload 的層數（保守，約 40%）
  static int _estimatePartialGpuLayers(LocalModelInfo? info) {
    if (info == null) return 8; // 保底
    // 粗估：每 500MB 模型 ≈ 8 層，取 40%
    final totalLayers = (info.sizeBytes / (500 * 1024 * 1024) * 8).round();
    final partial = (totalLayers * 0.4).round();
    return partial.clamp(4, 24); // 最少 4 層，最多 24 層
  }

  /// 動態 context size：RAM 充裕 4096，緊張時降到 2048
  static Future<int> _adaptiveContextSize(LocalModelInfo? info) async {
    if (info == null) return 4096;
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      if (info.sizeBytes <= 1300 * 1024 * 1024) return 2048;
      if (info.sizeBytes <= 2700 * 1024 * 1024) return 1536;
      return 1024;
    }
    final ram = await getDeviceRam();
    final headroom = ram - info.sizeBytes;
    // 模型 size 的 1.5 倍以上空間 → 完整 context
    if (headroom > info.sizeBytes * 0.5) return 4096;
    // 否則壓到 2048 省記憶體
    debugPrint('RAM headroom tight (${formatSize(headroom)}), using ctx=2048');
    return 2048;
  }

  /// 本地 GGUF 專用輸出上限；不影響任何聯網 API adapter。
  static int _adaptiveLlamaMaxTokens(LocalModelInfo? info) {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      final size = info?.sizeBytes ?? 0;
      if (size > 0 && size <= 1300 * 1024 * 1024) return 768;
      if (size > 0 && size <= 2700 * 1024 * 1024) return 640;
      return 512;
    }
    return 2048;
  }

  llama.ModelParams _llamaModelParams(
    LocalModelInfo? info, {
    required llama.GpuBackend preferredBackend,
    required int gpuLayers,
    int contextSize = 4096,
  }) {
    final isAndroid = !kIsWeb && Platform.isAndroid;
    return llama.ModelParams(
      contextSize: contextSize,
      gpuLayers: gpuLayers,
      preferredBackend: preferredBackend,
      modelBytesHint: info?.sizeBytes,
      // ── 加速開關 ──
      // q8_0 KV cache 要求 flash attention 必須開啟，auto 不夠穩
      flashAttention: llama.FlashAttention.enabled,
      cacheTypeK: llama.KvCacheType.q8_0, // KV cache 量化：省 ~50% 顯存
      cacheTypeV: llama.KvCacheType.q8_0,
      // ── 線程調優（0=auto，Android 上明確設定物理核心數效果更好）──
      numberOfThreads: isAndroid ? Platform.numberOfProcessors.clamp(1, 8) : 0,
      numberOfThreadsBatch: isAndroid
          ? Platform.numberOfProcessors.clamp(1, 8)
          : 0,
      // ── Batch 調優（prompt 處理吞吐）──
      batchSize: isAndroid ? 512 : 0,
      microBatchSize: isAndroid ? 128 : 0,
    );
  }

  @override
  Future<String> sendMessage({
    StructuredPrompt? structuredPrompt,
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
  }) async {
    if (_loadedModelPath == null) {
      throw Exception(L.locale == 'en' ? 'Local model not loaded' : '本地模型未加載');
    }

    // 用 stream 版本 + 超時保護，統一安全邏輯
    final buffer = StringBuffer();
    await for (final token in sendMessageStream(
      structuredPrompt: structuredPrompt,
      messages: messages,
      model: model,
      systemPrompt: systemPrompt,
    )) {
      buffer.write(token);
    }
    return buffer.toString();
  }

  @override
  Stream<String> sendMessageStream({
    StructuredPrompt? structuredPrompt,
    required List<Map<String, String>> messages,
    required String model,
    String? systemPrompt,
  }) async* {
    if (_loadedModelPath == null) {
      throw Exception(L.locale == 'en' ? 'Local model not loaded' : '本地模型未加載');
    }

    final previous = _inferenceQueue.catchError((_) {});
    final release = Completer<void>();
    _inferenceQueue = previous.then((_) => release.future);

    try {
      await previous;
      // 包裹原始 stream，加上超時 + 卡住偵測
      final rawStream = _llamaEngine != null
          ? _sendLlamaMessageStream(
              structuredPrompt: structuredPrompt,
              messages: messages,
              systemPrompt: systemPrompt,
            )
          : _sendGemmaMessageStream(
              systemPrompt: systemPrompt,
              structuredPrompt: structuredPrompt,
              messages: messages,
            );

      var timedOut = false;
      final guardedStream = rawStream.timeout(
        _firstTokenTimeout,
        onTimeout: (sink) {
          timedOut = true;
          debugPrint(
            'Local model token timeout (${_firstTokenTimeout.inSeconds}s no output)',
          );
          sink.add(
            L.locale == 'en'
                ? '\n\n[Generation stopped: no output]'
                : '\n\n[生成中斷：長時間無輸出]',
          );
          sink.close();
        },
      );

      final startTime = DateTime.now();
      var lastTokenTime = DateTime.now();
      var tokenCount = 0;

      await for (final token in guardedStream) {
        if (timedOut) {
          yield token;
          break;
        }

        final now = DateTime.now();

        // 整體超時
        if (now.difference(startTime) > _inferenceTimeout) {
          debugPrint(
            'Local model inference timeout (${_inferenceTimeout.inMinutes}min)',
          );
          yield L.locale == 'en'
              ? '\n\n[Generation stopped: timeout]'
              : '\n\n[生成中斷：超時]';
          break;
        }

        // 首 token 之後才做 token 間隔卡住偵測，避免 CPU prefill 被誤殺。
        if (tokenCount > 0 &&
            now.difference(lastTokenTime) > _tokenStallTimeout) {
          debugPrint(
            'Local model token stall (${_tokenStallTimeout.inSeconds}s no output)',
          );
          yield L.locale == 'en'
              ? '\n\n[Generation stopped: stalled]'
              : '\n\n[生成中斷：卡住]';
          break;
        }

        lastTokenTime = now;
        tokenCount++;

        // ═══ Crash canary：第一個 token 成功 → GPU 推理沒問題 → 清除金絲雀 ═══
        if (tokenCount == 1 && !_gpuCanaryCleared) {
          _gpuCanaryCleared = true;
          unawaited(_clearGpuCanary(_loadedModelInfo));
        }

        yield token;
      }
    } finally {
      if (!release.isCompleted) release.complete();
    }
  }

  /// Gemma stream（從 sendMessageStream 抽出來方便統一包裹）
  Stream<String> _sendGemmaMessageStream({
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
    required List<Map<String, String>> messages,
  }) async* {
    final chat = await _createGemmaChat(systemPrompt, structuredPrompt);
    await _replayMessages(chat, messages);
    await for (final response in chat.generateChatResponseAsync()) {
      if (response is gemma.TextResponse) {
        yield response.token;
      } else if (response is gemma.ThinkingResponse) {
        yield response.content;
      }
    }
  }

  /// 釋放模型（省內存）
  Future<void> dispose() async {
    await _llamaEngine?.dispose();
    _llamaEngine = null;
    await _gemmaModel?.close();
    _gemmaModel = null;
    _loadedModelPath = null;
    _loadedModelInfo = null;
  }

  Stream<String> _sendLlamaMessageStream({
    StructuredPrompt? structuredPrompt,
    required List<Map<String, String>> messages,
    String? systemPrompt,
  }) async* {
    final engine = _llamaEngine;
    if (engine == null) {
      throw Exception(L.locale == 'en' ? 'Local model not loaded' : '本地模型未加載');
    }

    final maxTokens = _effectiveLlamaMaxTokens();
    final promptBudget = _llamaPromptBudget(maxTokens);
    final llamaMessages = _buildLlamaMessages(
      structuredPrompt: structuredPrompt,
      messages: messages,
      systemPrompt: systemPrompt,
      maxPromptTokens: promptBudget,
    );

    try {
      await for (final content in _createLlamaTextStream(
        engine,
        llamaMessages,
        maxTokens,
      )) {
        yield content;
      }
    } catch (e) {
      if (!_isLlamaPromptTooLong(e)) rethrow;

      debugPrint('Local GGUF prompt too long; retrying with a smaller prompt');
      final retryMaxTokens = maxTokens > 512 ? 512 : maxTokens;
      final retryBudget = (_llamaPromptBudget(retryMaxTokens) * 0.6)
          .round()
          .clamp(128, _llamaContextSize)
          .toInt();
      final retryMessages = _buildLlamaMessages(
        structuredPrompt: structuredPrompt,
        messages: messages,
        systemPrompt: systemPrompt,
        maxPromptTokens: retryBudget,
      );

      await for (final content in _createLlamaTextStream(
        engine,
        retryMessages,
        retryMaxTokens,
      )) {
        yield content;
      }
    }
  }

  Stream<String> _createLlamaTextStream(
    llama.LlamaEngine engine,
    List<llama.LlamaChatMessage> llamaMessages,
    int maxTokens,
  ) async* {
    await for (final chunk in engine.create(
      llamaMessages,
      params: llama.GenerationParams(maxTokens: maxTokens),
      enableThinking: false,
    )) {
      if (chunk.choices.isEmpty) continue;
      final content = chunk.choices.first.delta.content;
      if (content != null && content.isNotEmpty) yield content;
    }
  }

  List<llama.LlamaChatMessage> _buildLlamaMessages({
    StructuredPrompt? structuredPrompt,
    required List<Map<String, String>> messages,
    String? systemPrompt,
    int? maxPromptTokens,
  }) {
    final result = <llama.LlamaChatMessage>[];
    final budget =
        maxPromptTokens ?? _llamaPromptBudget(_llamaGenerationMaxTokens);
    var remaining = budget;
    final prompt = structuredPrompt?.combined ?? systemPrompt ?? '';
    if (prompt.trim().isNotEmpty) {
      final systemBudget = _systemPromptBudget(remaining);
      final clippedPrompt = _truncateToTokenBudget(
        prompt,
        systemBudget,
        keepTail: false,
      );
      result.add(
        llama.LlamaChatMessage.fromText(
          role: llama.LlamaChatRole.system,
          text: clippedPrompt,
        ),
      );
      remaining -= TokenEstimator.estimate(clippedPrompt);
    }

    final selected = <Map<String, String>>[];
    for (final message in messages) {
      final role = message['role'] ?? 'user';
      final content = message['content'] ?? '';
      if (content.trim().isEmpty || role == 'system') continue;
      selected.add({'role': role, 'content': content});
    }

    final kept = <Map<String, String>>[];
    for (final message in selected.reversed) {
      if (remaining <= 0) break;
      final content = message['content'] ?? '';
      final estimate = TokenEstimator.estimate(content);
      if (estimate <= remaining) {
        kept.add(message);
        remaining -= estimate;
        continue;
      }

      if (remaining >= 96) {
        final clipped = _truncateToTokenBudget(
          content,
          remaining,
          keepTail: true,
        );
        if (clipped.trim().isNotEmpty) {
          kept.add({...message, 'content': clipped});
        }
      }
      break;
    }

    for (final message in kept.reversed) {
      final role = message['role'] ?? 'user';
      final content = message['content'] ?? '';
      result.add(
        llama.LlamaChatMessage.fromText(
          role: role == 'assistant'
              ? llama.LlamaChatRole.assistant
              : llama.LlamaChatRole.user,
          text: content,
        ),
      );
    }

    return result;
  }

  int _llamaPromptBudget(int responseTokens) {
    final budget = _llamaContextSize - responseTokens - 128;
    return budget.clamp(192, _llamaContextSize).toInt();
  }

  int _effectiveLlamaMaxTokens() {
    final backendCap = _llamaCpuBackend && _llamaGenerationMaxTokens > 512
        ? 512
        : _llamaGenerationMaxTokens;
    final contextCap = (_llamaContextSize * 0.45).floor();
    return backendCap.clamp(128, contextCap).toInt();
  }

  int _systemPromptBudget(int remainingPromptBudget) {
    if (remainingPromptBudget <= 0) return 0;
    final preferred = (remainingPromptBudget * 0.45).round();
    return preferred.clamp(96, remainingPromptBudget).toInt();
  }

  static bool _isLlamaPromptTooLong(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('tokenization failed') ||
        text.contains('prompt too long') ||
        text.contains('context') && text.contains('exceed');
  }

  static String _truncateToTokenBudget(
    String text,
    int maxTokens, {
    required bool keepTail,
  }) {
    if (text.isEmpty || maxTokens <= 0) return '';
    if (TokenEstimator.estimate(text) <= maxTokens) return text;

    var low = 0;
    var high = text.length;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      final candidate = keepTail
          ? text.substring(text.length - mid)
          : text.substring(0, mid);
      if (TokenEstimator.estimate(candidate) <= maxTokens) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }

    return keepTail
        ? text.substring(text.length - low)
        : text.substring(0, low);
  }

  Future<gemma.InferenceChat> _createGemmaChat(
    String? systemPrompt,
    StructuredPrompt? structuredPrompt,
  ) async {
    final model = _gemmaModel;
    if (model == null) {
      throw Exception(L.locale == 'en' ? 'Local model not loaded' : '本地模型未加載');
    }
    final prompt = structuredPrompt?.combined ?? systemPrompt ?? '';
    return model.createChat(
      systemInstruction: prompt.isEmpty ? null : prompt,
      modelType: _gemmaModelTypeForKey(_modelKey),
      isThinking: false,
    );
  }

  Future<void> _replayMessages(
    gemma.InferenceChat chat,
    List<Map<String, String>> messages,
  ) async {
    for (final message in messages) {
      final role = message['role'] ?? 'user';
      final content = message['content'] ?? '';
      if (content.trim().isEmpty || role == 'system') continue;
      await chat.addQueryChunk(
        gemma.Message.text(text: content, isUser: role != 'assistant'),
      );
    }
  }

  // ─────────────────────────────────────────────
  // F. 輔助
  // ─────────────────────────────────────────────

  /// 格式化文件大小
  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 格式化 RAM 需求描述
  static String formatRequirement(LocalModelInfo model) {
    final size = formatSize(model.sizeBytes);
    final estimated = formatSize((model.sizeBytes * 1.3).round());
    if (L.locale == 'en') {
      return 'Download: $size · Runtime ~$estimated';
    }
    return '下載：$size · 運行約需 ~$estimated';
  }
}

// ─────────────────────────────────────────────
// 數據模型
// ─────────────────────────────────────────────

class LocalModelInfo {
  final String key;
  final String name;
  final String nameEn;
  final String quantization;
  final int sizeBytes;
  final int minRamBytes;
  final int recommendedRamBytes;
  final String downloadUrl;
  final String expectedSha256;
  final String description;
  final String descriptionEn;
  final bool isDefault;
  final String localPath;
  final bool isCustom;

  const LocalModelInfo({
    required this.key,
    required this.name,
    required this.nameEn,
    required this.quantization,
    required this.sizeBytes,
    required this.minRamBytes,
    required this.recommendedRamBytes,
    required this.downloadUrl,
    this.expectedSha256 = '',
    this.description = '',
    this.descriptionEn = '',
    this.isDefault = false,
    this.localPath = '',
    this.isCustom = false,
  });

  factory LocalModelInfo.fromJson(Map<String, dynamic> json) {
    return LocalModelInfo(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      nameEn: json['nameEn'] as String? ?? json['name'] as String? ?? '',
      quantization: json['quantization'] as String? ?? 'GGUF',
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      minRamBytes: json['minRamBytes'] as int? ?? 0,
      recommendedRamBytes: json['recommendedRamBytes'] as int? ?? 0,
      downloadUrl: json['downloadUrl'] as String? ?? '',
      expectedSha256: json['expectedSha256'] as String? ?? '',
      description: json['description'] as String? ?? '',
      descriptionEn: json['descriptionEn'] as String? ?? '',
      isDefault: json['isDefault'] as bool? ?? false,
      localPath: json['localPath'] as String? ?? '',
      isCustom: json['isCustom'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'name': name,
      'nameEn': nameEn,
      'quantization': quantization,
      'sizeBytes': sizeBytes,
      'minRamBytes': minRamBytes,
      'recommendedRamBytes': recommendedRamBytes,
      'downloadUrl': downloadUrl,
      'expectedSha256': expectedSha256,
      'description': description,
      'descriptionEn': descriptionEn,
      'isDefault': isDefault,
      'localPath': localPath,
      'isCustom': isCustom,
    };
  }
}

enum ModelCompatibility {
  recommended, // RAM 充足，推薦使用
  compatible, // RAM 夠用但不寬裕
  ramInsufficient, // RAM 不足
  storageInsufficient, // 存儲空間不足
}
