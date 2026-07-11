import 'dart:async';

import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../widgets/gradient_background.dart';
import '../services/call_audio_pipeline.dart';

class VoiceCallScreen extends StatefulWidget {
  const VoiceCallScreen({super.key});

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen> {
  Timer? _saveTimer;
  String _ttsProvider = 'openai';
  bool _settingsLoaded = false;
  bool _settingsDirty = false;
  bool _isPopping = false;
  Future<void>? _saveLoop;

  void _debouncedSave() {
    if (!_settingsLoaded) return;
    _settingsDirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_flushPendingSave().catchError(_reportSaveError));
    });
  }

  void _reportSaveError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          L.pick(
            en: 'Voice settings could not be saved: $error',
            zhTW: '語音設定保存失敗：$error',
          ),
        ),
        backgroundColor: Colors.red,
      ),
    );
  }

  Future<void> _flushPendingSave() async {
    _saveTimer?.cancel();
    if (!_settingsLoaded) return;

    final running = _saveLoop;
    if (running != null) {
      await running;
      return;
    }

    final loop = _drainPendingSaves();
    _saveLoop = loop;
    try {
      await loop;
    } finally {
      if (identical(_saveLoop, loop)) _saveLoop = null;
    }
  }

  Future<void> _drainPendingSaves() async {
    while (_settingsDirty) {
      _settingsDirty = false;
      try {
        await _saveSettings();
      } catch (_) {
        _settingsDirty = true;
        rethrow;
      }
    }
  }

  Future<void> _handleBack() async {
    if (_isPopping) return;
    _isPopping = true;
    try {
      await _flushPendingSave();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _reportSaveError(e);
      _isPopping = false;
    }
  }

  String _ttsVoice = 'alloy';
  final _ttsOpenaiKeyCtrl = TextEditingController();

  final _ttsElevenlabsKeyCtrl = TextEditingController();
  final _ttsElevenlabsVoiceCtrl = TextEditingController();
  String _ttsActiveVoiceId = '';
  List<String> _ttsVoiceIdList = [];
  String _ttsElevenlabsModel = 'eleven_flash_v2_5';
  double _ttsElevenlabsStability = 0.5;
  double _ttsElevenlabsSimilarity = 0.75;

  String _callRingtone = 'gentle';
  bool _isTestingApi = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final tProv = await TtsSettings.getTtsProvider();
    final tVoice = await TtsSettings.getTtsVoice();
    final tOkey = await TtsSettings.getTtsOpenaiKey();
    final tEkey = await TtsSettings.getTtsElevenlabsKey();
    final tEvoice = await TtsSettings.getTtsElevenlabsVoiceId();
    final tElist = await TtsSettings.getVoiceIdList();
    final tEmodel = await TtsSettings.getTtsElevenlabsModel();
    final tEstab = await TtsSettings.getTtsElevenlabsStability();
    final tEsim = await TtsSettings.getTtsElevenlabsSimilarity();
    final ring = await TtsSettings.getCallRingtone();

    if (mounted) {
      setState(() {
        _ttsProvider = tProv;
        _ttsVoice = tVoice;
        _ttsOpenaiKeyCtrl.text = tOkey;
        _ttsElevenlabsKeyCtrl.text = tEkey;
        _ttsActiveVoiceId = tEvoice;
        _ttsVoiceIdList = tElist;
        _ttsElevenlabsModel = tEmodel;
        _ttsElevenlabsStability = tEstab;
        _ttsElevenlabsSimilarity = tEsim;
        _callRingtone = ring;
        _settingsLoaded = true;
      });
    }
  }

  final RingtonePlayer _previewPlayer = RingtonePlayer();
  Timer? _previewStopTimer;

  void _selectRingtone(String rt) async {
    setState(() => _callRingtone = rt);
    _previewStopTimer?.cancel();
    await _previewPlayer.stop();
    if (!mounted || _callRingtone != rt) return;
    _previewPlayer.start(rt);
    _previewStopTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _callRingtone == rt) _previewPlayer.stop();
    });
    TtsSettings.saveCallRingtone(rt);
  }

  Future<void> _testApiConnection(String provider, String key) async {
    if (key.isEmpty) return;
    setState(() => _isTestingApi = true);

    try {
      http.Response? response;
      if (provider == 'openai') {
        response = await http
            .get(
              Uri.parse('https://api.openai.com/v1/models'),
              headers: {'Authorization': 'Bearer $key'},
            )
            .timeout(const Duration(seconds: 20));
      } else if (provider == 'elevenlabs') {
        response = await http
            .get(
              Uri.parse('https://api.elevenlabs.io/v1/voices'),
              headers: {'xi-api-key': key},
            )
            .timeout(const Duration(seconds: 20));
      }

      if (response != null) {
        if (response.statusCode == 200) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  L.pick(en: 'Connection successful', zhTW: '連線成功'),
                ),
                backgroundColor: Colors.green,
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 2),
              ),
            );
          }
        } else {
          throw Exception('Status ${response.statusCode}: ${response.body}');
        }
      } else {
        throw UnsupportedError('尚未實作此服務的連線測試');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${L.pick(en: 'Connection failed', zhTW: '連線失敗')}: $e',
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isTestingApi = false);
    }
  }

  Future<void> _saveSettings() async {
    final provider = _ttsProvider;
    final voice = _ttsVoice;
    final openaiKey = _ttsOpenaiKeyCtrl.text.trim();
    final elevenlabsKey = _ttsElevenlabsKeyCtrl.text.trim();
    final elevenlabsVoiceId = _ttsActiveVoiceId;
    final elevenlabsModel = _ttsElevenlabsModel;
    final stability = _ttsElevenlabsStability;
    final similarity = _ttsElevenlabsSimilarity;

    await TtsSettings.saveTtsProvider(provider);
    await TtsSettings.saveTtsVoice(voice);
    await TtsSettings.saveTtsOpenaiKey(openaiKey);
    await TtsSettings.saveTtsElevenlabsKey(elevenlabsKey);
    await TtsSettings.saveTtsElevenlabsVoiceId(elevenlabsVoiceId);
    await TtsSettings.saveTtsElevenlabsModel(elevenlabsModel);
    await TtsSettings.saveTtsElevenlabsStability(stability);
    await TtsSettings.saveTtsElevenlabsSimilarity(similarity);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _previewStopTimer?.cancel();
    // 離開頁面立刻停掉鈴聲預覽——否則 looping 的預覽會洩漏出去，
    // 3 秒那個 if(mounted) 停不掉它，還會殘留到你之後撥電話時繼續響。
    _previewPlayer.stop();
    _ttsOpenaiKeyCtrl.dispose();
    _ttsElevenlabsKeyCtrl.dispose();
    _ttsElevenlabsVoiceCtrl.dispose();
    super.dispose();
  }

  Widget _buildGlassCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: YanciTheme.spacingMd,
            vertical: YanciTheme.spacingXs,
          ),
          decoration: BoxDecoration(
            color: YanciTheme.glassInputBg,
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            border: Border.all(color: YanciTheme.glassBorder, width: 0.5),
          ),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
        body: GradientBackground(
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: YanciTheme.spacingSm,
                    vertical: YanciTheme.spacingXs,
                  ),
                  child: SizedBox(
                    height: 48,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Center(
                          child: Text(
                            L.pick(en: 'Voice & Calls', zhTW: '語音與通話'),
                            textAlign: TextAlign.center,
                            style: YanciTheme.headingMedium,
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton(
                            icon: Icon(
                              Icons.arrow_back_ios_rounded,
                              size: 20,
                              color: YanciTheme.textPrimary,
                            ),
                            onPressed: _handleBack,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _settingsLoaded
                      ? ListView(
                          padding: const EdgeInsets.all(YanciTheme.spacingMd),
                          children: [
                            Text(
                              L.get('settings_tts_title'),
                              style: YanciTheme.bodySmall.copyWith(
                                color: YanciTheme.textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: YanciTheme.spacingSm),
                            _buildGlassCard(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  DropdownButton<String>(
                                    value: _ttsProvider,
                                    isExpanded: true,
                                    underline: const SizedBox(),
                                    style: YanciTheme.bodyText.copyWith(
                                      fontSize: 13,
                                    ),
                                    dropdownColor: YanciTheme.isDark
                                        ? const Color(0xF0302830)
                                        : Colors.white,
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'openai',
                                        child: Text('OpenAI TTS'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'elevenlabs',
                                        child: Text('ElevenLabs'),
                                      ),
                                    ],
                                    onChanged: (v) {
                                      setState(
                                        () => _ttsProvider = v ?? 'openai',
                                      );
                                      _debouncedSave();
                                    },
                                  ),
                                  const SizedBox(height: 8),
                                  if (_ttsProvider == 'openai') ...[
                                    TextField(
                                      controller: _ttsOpenaiKeyCtrl,
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 13,
                                      ),
                                      onChanged: (v) => _debouncedSave(),
                                      decoration: InputDecoration(
                                        hintText: L.get(
                                          'settings_tts_openai_hint',
                                        ),
                                        hintStyle: YanciTheme.bodySmall
                                            .copyWith(
                                              color: YanciTheme.textSecondary
                                                  .withValues(alpha: 0.4),
                                            ),
                                        suffixIcon: _isTestingApi
                                            ? const Padding(
                                                padding: EdgeInsets.all(12),
                                                child: SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                ),
                                              )
                                            : IconButton(
                                                icon: const Icon(
                                                  Icons.wifi_protected_setup,
                                                  size: 18,
                                                ),
                                                onPressed: () =>
                                                    _testApiConnection(
                                                      'openai',
                                                      _ttsOpenaiKeyCtrl.text,
                                                    ),
                                              ),
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      L.get('tts_voice'),
                                      style: YanciTheme.bodySmall,
                                    ),
                                    Wrap(
                                      spacing: 6,
                                      children:
                                          [
                                            'alloy',
                                            'echo',
                                            'fable',
                                            'onyx',
                                            'nova',
                                            'shimmer',
                                          ].map((v) {
                                            final isActive = _ttsVoice == v;
                                            return GestureDetector(
                                              onTap: () {
                                                setState(() => _ttsVoice = v);
                                                _debouncedSave();
                                              },
                                              child: Chip(
                                                label: Text(
                                                  v,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: isActive
                                                        ? YanciTheme.accent
                                                        : YanciTheme
                                                              .textSecondary,
                                                  ),
                                                ),
                                                backgroundColor: isActive
                                                    ? YanciTheme.accent
                                                          .withValues(
                                                            alpha: 0.1,
                                                          )
                                                    : Colors.transparent,
                                                side: BorderSide(
                                                  color: isActive
                                                      ? YanciTheme.accent
                                                            .withValues(
                                                              alpha: 0.3,
                                                            )
                                                      : YanciTheme.textSecondary
                                                            .withValues(
                                                              alpha: 0.15,
                                                            ),
                                                ),
                                                padding: EdgeInsets.zero,
                                                materialTapTargetSize:
                                                    MaterialTapTargetSize
                                                        .shrinkWrap,
                                              ),
                                            );
                                          }).toList(),
                                    ),
                                  ],
                                  if (_ttsProvider == 'elevenlabs') ...[
                                    TextField(
                                      controller: _ttsElevenlabsKeyCtrl,
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 13,
                                      ),
                                      onChanged: (v) => _debouncedSave(),
                                      decoration: InputDecoration(
                                        hintText: 'ElevenLabs API Key',
                                        hintStyle: YanciTheme.bodySmall
                                            .copyWith(
                                              color: YanciTheme.textSecondary
                                                  .withValues(alpha: 0.4),
                                            ),
                                        suffixIcon: _isTestingApi
                                            ? const Padding(
                                                padding: EdgeInsets.all(12),
                                                child: SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                ),
                                              )
                                            : IconButton(
                                                icon: const Icon(
                                                  Icons.wifi_protected_setup,
                                                  size: 18,
                                                ),
                                                onPressed: () =>
                                                    _testApiConnection(
                                                      'elevenlabs',
                                                      _ttsElevenlabsKeyCtrl
                                                          .text,
                                                    ),
                                                tooltip: L.pick(
                                                  en: 'Test connection',
                                                  zhTW: '測試連線',
                                                ),
                                              ),
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Voice ID',
                                      style: YanciTheme.bodySmall,
                                    ),
                                    const SizedBox(height: 4),
                                    ..._ttsVoiceIdList.map((vid) {
                                      final isActive = vid == _ttsActiveVoiceId;
                                      return Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 4,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isActive
                                              ? YanciTheme.accent.withValues(
                                                  alpha: 0.1,
                                                )
                                              : Colors.grey.withValues(
                                                  alpha: 0.06,
                                                ),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: isActive
                                              ? Border.all(
                                                  color: YanciTheme.accent
                                                      .withValues(alpha: 0.3),
                                                )
                                              : null,
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: GestureDetector(
                                                onTap: () {
                                                  setState(
                                                    () =>
                                                        _ttsActiveVoiceId = vid,
                                                  );
                                                  _debouncedSave();
                                                },
                                                child: Text(
                                                  vid,
                                                  style: YanciTheme.bodyText
                                                      .copyWith(
                                                        fontSize: 12,
                                                        color: isActive
                                                            ? YanciTheme.accent
                                                            : YanciTheme
                                                                  .textPrimary,
                                                      ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ),
                                            if (isActive)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 6,
                                                ),
                                                child: Icon(
                                                  Icons.check_rounded,
                                                  size: 14,
                                                  color: YanciTheme.accent,
                                                ),
                                              ),
                                            GestureDetector(
                                              onTap: () async {
                                                await TtsSettings.removeVoiceId(
                                                  vid,
                                                );
                                                final list =
                                                    await TtsSettings.getVoiceIdList();
                                                final active =
                                                    await TtsSettings.getTtsElevenlabsVoiceId();
                                                if (!mounted) return;
                                                setState(() {
                                                  _ttsVoiceIdList = list;
                                                  _ttsActiveVoiceId = active;
                                                });
                                              },
                                              child: Icon(
                                                Icons.close_rounded,
                                                size: 16,
                                                color: YanciTheme.textSecondary
                                                    .withValues(alpha: 0.4),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller: _ttsElevenlabsVoiceCtrl,
                                            style: YanciTheme.bodyText.copyWith(
                                              fontSize: 12,
                                            ),
                                            decoration: InputDecoration(
                                              hintText: L.pick(
                                                en: 'Paste new Voice ID',
                                                zhTW: '貼上新的 Voice ID',
                                              ),
                                              hintStyle: YanciTheme.bodySmall
                                                  .copyWith(
                                                    color: YanciTheme
                                                        .textSecondary
                                                        .withValues(alpha: 0.3),
                                                    fontSize: 12,
                                                  ),
                                              border: InputBorder.none,
                                              isDense: true,
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 8,
                                                  ),
                                            ),
                                          ),
                                        ),
                                        GestureDetector(
                                          onTap: () async {
                                            final vid = _ttsElevenlabsVoiceCtrl
                                                .text
                                                .trim();
                                            if (vid.isEmpty) return;
                                            await TtsSettings.addVoiceId(vid);
                                            if (_ttsVoiceIdList.isEmpty) {
                                              await TtsSettings.saveTtsElevenlabsVoiceId(
                                                vid,
                                              );
                                            }
                                            final list =
                                                await TtsSettings.getVoiceIdList();
                                            final active =
                                                await TtsSettings.getTtsElevenlabsVoiceId();
                                            if (!mounted) return;
                                            setState(() {
                                              _ttsVoiceIdList = list;
                                              _ttsActiveVoiceId = active.isEmpty
                                                  ? vid
                                                  : active;
                                              _ttsElevenlabsVoiceCtrl.clear();
                                            });
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: YanciTheme.accent
                                                  .withValues(alpha: 0.12),
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              Icons.add_rounded,
                                              size: 18,
                                              color: YanciTheme.accent,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      L.get('tts_model'),
                                      style: YanciTheme.bodySmall,
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 6,
                                      children:
                                          {
                                            'eleven_flash_v2_5': 'Flash v2.5',
                                            'eleven_multilingual_v2':
                                                'Multi v2',
                                            'eleven_v3': 'v3',
                                          }.entries.map((e) {
                                            final isActive =
                                                _ttsElevenlabsModel == e.key;
                                            return GestureDetector(
                                              onTap: () {
                                                setState(
                                                  () => _ttsElevenlabsModel =
                                                      e.key,
                                                );
                                                _debouncedSave();
                                              },
                                              child: Chip(
                                                label: Text(
                                                  e.value,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: isActive
                                                        ? YanciTheme.accent
                                                        : YanciTheme
                                                              .textSecondary,
                                                  ),
                                                ),
                                                backgroundColor: isActive
                                                    ? YanciTheme.accent
                                                          .withValues(
                                                            alpha: 0.1,
                                                          )
                                                    : Colors.transparent,
                                                side: BorderSide(
                                                  color: isActive
                                                      ? YanciTheme.accent
                                                            .withValues(
                                                              alpha: 0.3,
                                                            )
                                                      : YanciTheme.textSecondary
                                                            .withValues(
                                                              alpha: 0.15,
                                                            ),
                                                ),
                                                padding: EdgeInsets.zero,
                                                materialTapTargetSize:
                                                    MaterialTapTargetSize
                                                        .shrinkWrap,
                                              ),
                                            );
                                          }).toList(),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      L.pick(
                                        en: 'Stability: ${_ttsElevenlabsStability.toStringAsFixed(2)}',
                                        zhTW:
                                            '穩定：${_ttsElevenlabsStability.toStringAsFixed(2)}',
                                      ),
                                      style: YanciTheme.bodySmall,
                                    ),
                                    Slider(
                                      value: _ttsElevenlabsStability,
                                      min: 0.0,
                                      max: 1.0,
                                      divisions: 20,
                                      activeColor: YanciTheme.accent,
                                      inactiveColor: YanciTheme.textSecondary
                                          .withValues(alpha: 0.15),
                                      onChanged: (v) {
                                        setState(
                                          () => _ttsElevenlabsStability = v,
                                        );
                                        _debouncedSave();
                                      },
                                    ),
                                    Text(
                                      L.pick(
                                        en: 'Similarity: ${_ttsElevenlabsSimilarity.toStringAsFixed(2)}',
                                        zhTW:
                                            '相似：${_ttsElevenlabsSimilarity.toStringAsFixed(2)}',
                                      ),
                                      style: YanciTheme.bodySmall,
                                    ),
                                    Slider(
                                      value: _ttsElevenlabsSimilarity,
                                      min: 0.0,
                                      max: 1.0,
                                      divisions: 20,
                                      activeColor: YanciTheme.accent,
                                      inactiveColor: YanciTheme.textSecondary
                                          .withValues(alpha: 0.15),
                                      onChanged: (v) {
                                        setState(
                                          () => _ttsElevenlabsSimilarity = v,
                                        );
                                        _debouncedSave();
                                      },
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: YanciTheme.spacingMd),
                            Text(
                              L.get('settings_ringtone'),
                              style: YanciTheme.bodySmall.copyWith(
                                color: YanciTheme.textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              children: RingtonePlayer.ringtones.entries.map((
                                e,
                              ) {
                                final selected = _callRingtone == e.key;
                                final label = L.pick(
                                  en: const {
                                    'gentle': 'Gentle',
                                    'classic': 'Classic',
                                    'vibrate': 'Vibrate only',
                                  }[e.key]!,
                                  zhTW: e.value,
                                );
                                return ChoiceChip(
                                  label: Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: selected
                                          ? YanciTheme.accent
                                          : YanciTheme.textSecondary,
                                      fontFamily: YanciTheme.fontFamily,
                                    ),
                                  ),
                                  selected: selected,
                                  showCheckmark: false,
                                  selectedColor: YanciTheme.accent.withValues(
                                    alpha: 0.15,
                                  ),
                                  backgroundColor: YanciTheme.textSecondary
                                      .withValues(alpha: 0.06),
                                  side: BorderSide(
                                    color: selected
                                        ? YanciTheme.accent.withValues(
                                            alpha: 0.5,
                                          )
                                        : YanciTheme.textSecondary.withValues(
                                            alpha: 0.15,
                                          ),
                                    width: 0.5,
                                  ),
                                  onSelected: (_) => _selectRingtone(e.key),
                                );
                              }).toList(),
                            ),
                          ],
                        )
                      : const Center(child: CircularProgressIndicator()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
