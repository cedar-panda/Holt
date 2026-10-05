import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/backup_service.dart';
import '../services/local_device_sync_service.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

/// Open only from the backup sheet. Receiving is an explicit overwrite, never
/// an automatic merge or background sync.
class LocalDeviceSyncScreen extends StatefulWidget {
  const LocalDeviceSyncScreen({super.key});

  @override
  State<LocalDeviceSyncScreen> createState() => _LocalDeviceSyncScreenState();
}

class _LocalDeviceSyncScreenState extends State<LocalDeviceSyncScreen> {
  final _addressController = TextEditingController();
  final _codeController = TextEditingController();
  LocalDeviceSyncHost? _host;
  String? _pairingCode;
  String? _status;
  String? _error;
  bool _busy = false;
  bool _delivered = false;
  int? _received;
  int? _total;
  DateTime? _lastProgressUpdate;
  int _mode = 0; // 0 = choice, 1 = send, 2 = receive

  @override
  void dispose() {
    _addressController.dispose();
    _codeController.dispose();
    final host = _host;
    if (host != null) unawaited(host.close().catchError((Object _) {}));
    super.dispose();
  }

  String _t(String en, String zhTW, String zhCN) =>
      L.pick(en: en, zhTW: zhTW, zhCN: zhCN);

  Future<void> _startSending() async {
    if (_busy || _host != null) return;
    final code = LocalDeviceSyncService.createPairingCode();
    setState(() {
      _mode = 1;
      _busy = true;
      _pairingCode = code;
      _error = null;
      _delivered = false;
      _status = _t('Preparing encrypted backup…', '正在準備加密備份…', '正在准备加密备份…');
    });
    try {
      final host = await LocalDeviceSyncService.startHost(
        code: code,
        onDelivered: () {
          if (mounted) {
            setState(() {
              _delivered = true;
              _status = _t(
                'Transfer finished. You can close this page.',
                '傳輸完成，可以關閉此頁。',
                '传输完成，可以关闭此页。',
              );
            });
          }
        },
        onExpired: () {
          if (mounted) {
            setState(() {
              _host = null;
              _pairingCode = null;
              _error = _t(
                'Pairing expired. Create a new code.',
                '配對已過期，請重新產生配對碼。',
                '配对已过期，请重新生成配对码。',
              );
              _status = null;
            });
          }
        },
      );
      if (!mounted) {
        await host.close();
        return;
      }
      setState(() {
        _host = host;
        _busy = false;
        _status = _t(
          'Keep this page open until the other device receives it.',
          '請保持此頁開啟，直到另一台設備接收完成。',
          '请保持此页开启，直到另一台设备接收完成。',
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _t(
          'Could not start transfer. Check Wi-Fi and storage space.',
          '無法開始傳輸，請確認 Wi-Fi 與儲存空間。',
          '无法开始传输，请确认 Wi-Fi 与存储空间。',
        );
      });
    }
  }

  Future<void> _receive() async {
    if (_busy) return;
    final address = _addressController.text.trim();
    final code = _codeController.text.trim();
    try {
      LocalDeviceSyncService.parseTarget(address);
      if (!LocalDeviceSyncService.isValidCode(code)) {
        throw const FormatException('Invalid code');
      }
    } on FormatException {
      setState(
        () => _error = _t(
          'Enter the sender’s Wi-Fi address and complete pairing code.',
          '請輸入發送端的區網位址與完整配對碼。',
          '请输入发送端的局域网地址与完整配对码。',
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('Replace this device’s data?', '覆蓋本機資料？', '覆盖本机数据？')),
        content: Text(
          _t(
            'The other device’s complete backup will replace this device’s characters, chats, memories and settings. API keys stay on each device. Save a backup first if you need the current data.',
            '另一台設備的完整備份會覆蓋本機角色、對話、記憶與設定。API 金鑰仍各自留在原設備。若要保留本機資料，請先另存備份。',
            '另一台设备的完整备份会覆盖本机角色、对话、记忆与设置。API 密钥仍各自留在原设备。如需保留本机数据，请先另存备份。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L.get('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_t('Replace and receive', '覆蓋並接收', '覆盖并接收')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _received = null;
      _total = null;
      _status = _t('Connecting…', '正在連線…', '正在连接…');
    });
    File? transfer;
    try {
      transfer = await LocalDeviceSyncService.receive(
        target: address,
        code: code,
        onProgress: (received, total) {
          if (!mounted) return;
          final now = DateTime.now();
          if (_lastProgressUpdate != null &&
              now.difference(_lastProgressUpdate!) <
                  const Duration(milliseconds: 120) &&
              received != total) {
            return;
          }
          _lastProgressUpdate = now;
          setState(() {
            _received = received;
            _total = total;
            _status = _t(
              'Receiving encrypted backup…',
              '正在接收加密備份…',
              '正在接收加密备份…',
            );
          });
        },
      );
      if (!mounted) return;
      setState(
        () => _status = _t('Checking and restoring…', '正在驗證並還原…', '正在验证并还原…'),
      );
      await BackupService.importEncryptedPortableBundle(
        path: transfer.path,
        password: LocalDeviceSyncService.normalizeCode(code),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = _t(
          'Sync failed. Check that both devices are on the same Wi-Fi, the address and code match, and the sender page is still open.',
          '同步失敗。請確認兩台設備使用同一 Wi-Fi、位址與配對碼正確，且發送頁仍開啟。',
          '同步失败。请确认两台设备使用同一 Wi-Fi、地址与配对码正确，且发送页仍开启。',
        );
      });
    } finally {
      if (transfer != null && await transfer.exists()) await transfer.delete();
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _action({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        side: BorderSide(color: YanciTheme.accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: YanciTheme.accent),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: YanciTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: YanciTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final foreground = YanciTheme.textPrimary;
    return Scaffold(
      backgroundColor: YanciTheme.backgroundGradient.first,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: foreground,
        title: Text(
          _t('One-time Wi-Fi device sync', 'Wi-Fi 單次設備同步', 'Wi-Fi 单次设备同步'),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _t(
                  'Use the same Wi-Fi. Send once from one device and receive on the other. This replaces the receiving device’s data; it does not keep them in sync later.',
                  '兩台設備須連上同一 Wi-Fi。由一台發送、另一台接收一次；接收端資料會被覆蓋，之後不會持續同步。',
                  '两台设备须连接同一 Wi-Fi。由一台发送、另一台接收一次；接收端数据会被覆盖，之后不会持续同步。',
                ),
                style: TextStyle(color: YanciTheme.textSecondary, height: 1.5),
              ),
              const SizedBox(height: 20),
              if (_mode == 0) ...[
                _action(
                  icon: Icons.upload_rounded,
                  title: _t('Send from this device', '從這台設備發送', '从这台设备发送'),
                  subtitle: _t(
                    'Create a one-use encrypted backup and pairing code.',
                    '產生一次性加密備份與配對碼。',
                    '生成一次性加密备份与配对码。',
                  ),
                  onTap: _startSending,
                ),
                _action(
                  icon: Icons.download_rounded,
                  title: _t('Receive on this device', '在這台設備接收', '在这台设备接收'),
                  subtitle: _t(
                    'Replace this device’s data after confirmation.',
                    '確認後覆蓋本機資料。',
                    '确认后覆盖本机数据。',
                  ),
                  onTap: () => setState(() => _mode = 2),
                ),
              ] else if (_mode == 1) ...[
                if (_host == null && !_busy)
                  FilledButton(
                    onPressed: _startSending,
                    child: Text(
                      _t('Create new pairing code', '重新產生配對碼', '重新生成配对码'),
                    ),
                  ),
                if (_host != null) ...[
                  Text(
                    _t(
                      'Address to enter on the other device',
                      '在另一台設備輸入此位址',
                      '在另一台设备输入此地址',
                    ),
                    style: TextStyle(color: foreground),
                  ),
                  const SizedBox(height: 8),
                  for (final address in _host!.addresses)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: SelectableText(
                        '$address:${_host!.port}',
                        style: TextStyle(color: YanciTheme.accent),
                      ),
                      trailing: IconButton(
                        tooltip: _t('Copy address', '複製位址', '复制地址'),
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: '$address:${_host!.port}'),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    _t('One-time pairing code', '一次性配對碼', '一次性配对码'),
                    style: TextStyle(color: foreground),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    _pairingCode!,
                    style: TextStyle(
                      color: YanciTheme.accent,
                      fontSize: 21,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
                if (_delivered)
                  const Icon(Icons.check_circle_outline, size: 36),
              ] else ...[
                TextField(
                  controller: _addressController,
                  enabled: !_busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: _t('Sender address', '發送端位址', '发送端地址'),
                    hintText: '192.168.1.2:12345',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _codeController,
                  enabled: !_busy,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: _t('One-time pairing code', '一次性配對碼', '一次性配对码'),
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: _busy ? null : _receive,
                  child: Text(_t('Receive backup', '接收備份', '接收备份')),
                ),
                if (_received != null && _total != null && _total! > 0) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: _received! / _total!),
                ],
              ],
              if (_status != null) ...[
                const SizedBox(height: 16),
                Text(
                  _status!,
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
