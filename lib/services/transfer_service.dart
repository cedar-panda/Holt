import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'scratch_service.dart';

/// 轉帳服務 — 雙向轉帳（user ↔ character）。
///
/// TransferData 保持原 JSON 格式；messageId 同時是 wallet operation 的冪等鍵。
class TransferService {
  static Future<void> _serialTail = Future<void>.value();

  static Future<T> _serialized<T>(Future<T> Function() action) async {
    final previous = _serialTail;
    final release = Completer<void>();
    _serialTail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  static String _operationId(String messageId) => 'transfer_accept:$messageId';

  static TransferData? _readData(SharedPreferences prefs, String messageId) {
    final raw = prefs.getString('transfer_$messageId');
    if (raw == null) return null;
    return TransferData.fromJson(jsonDecode(raw));
  }

  static Future<void> _writeData(
    SharedPreferences prefs,
    String messageId,
    TransferData data,
  ) async {
    await prefs.setString('transfer_$messageId', jsonEncode(data.toJson()));
  }

  static Future<TransferData?> getData(String messageId) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      return _readData(prefs, messageId);
    });
  }

  static Future<void> saveData(String messageId, TransferData data) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      await _writeData(prefs, messageId, data);
    });
  }

  static Future<bool> acceptTransfer(String messageId, String characterId) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final data = _readData(prefs, messageId);
      if (data == null || data.status != 'pending' || data.amount <= 0) {
        return false;
      }

      final Map<String, int> deltas;
      if (data.direction == 'toUser') {
        deltas = {
          characterId: -data.amount,
          ScratchService.userAccountId: data.amount,
        };
      } else if (data.direction == 'toChar') {
        deltas = {
          ScratchService.userAccountId: -data.amount,
          characterId: data.amount,
        };
      } else {
        return false;
      }

      final operationId = _operationId(messageId);
      final result = await ScratchService.applyWalletOperation(
        operationId: operationId,
        deltas: deltas,
      );
      if (result == WalletOperationResult.insufficientFunds) return false;

      // Persist the domain state before discarding the wallet receipt. If this
      // write fails, retrying the same messageId sees an already-applied receipt
      // and only finishes the status update.
      await _writeData(prefs, messageId, data.copyWith(status: 'accepted'));
      await ScratchService.completeWalletOperation(operationId);
      return true;
    });
  }

  static Future<void> declineTransfer(String messageId) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final data = _readData(prefs, messageId);
      if (data == null || data.status != 'pending') return;

      final operationId = _operationId(messageId);
      // A crash may have moved both balances before status='accepted' was
      // saved. In that case decline must finalize acceptance, never undo only
      // one side or label a completed transfer as declined.
      if (await ScratchService.isWalletOperationApplied(operationId)) {
        await _writeData(prefs, messageId, data.copyWith(status: 'accepted'));
        await ScratchService.completeWalletOperation(operationId);
        return;
      }

      await _writeData(prefs, messageId, data.copyWith(status: 'declined'));
    });
  }
}

class TransferData {
  final int amount;

  /// 'toUser' = 角色轉給用戶, 'toChar' = 用戶轉給角色
  final String direction;

  /// 'pending' | 'accepted' | 'declined'
  final String status;

  const TransferData({
    required this.amount,
    required this.direction,
    this.status = 'pending',
  });

  TransferData copyWith({String? status}) => TransferData(
    amount: amount,
    direction: direction,
    status: status ?? this.status,
  );

  Map<String, dynamic> toJson() => {
    'amount': amount,
    'direction': direction,
    'status': status,
  };

  factory TransferData.fromJson(Map<String, dynamic> json) => TransferData(
    amount: json['amount'] as int,
    direction: json['direction'] as String,
    status: json['status'] as String? ?? 'pending',
  );
}
