import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 刮刮樂服務 — 獎池、幣值管理、刮刮樂數據持久化。
///
/// 幣值仍沿用原本的 SharedPreferences keys；wallet journal 只負責讓跨帳戶
/// 更新可重入、可從中途寫入恢復，不改變現有備份格式或初始餘額語義。
class ScratchService {
  static const int defaultCoins = 800;
  static const int ticketCost = 30;
  static const String userAccountId = '_user';

  static const String _walletJournalKey = 'scratch_wallet_journal_v1';
  static const String _userCoinKey = 'scratch_coins__user';
  static const int _dailyGrant = 30;
  static const String _replayLabel = '再來一張';

  static final StreamController<int> _userCoinsChanged =
      StreamController<int>.broadcast();
  static final StreamController<CharacterCoinsChanged> _characterCoinsChanged =
      StreamController<CharacterCoinsChanged>.broadcast();
  static final _rng = Random();

  // A release-completer queue is used instead of an external mutex package.
  // The tail itself never completes with an error, so one failed operation
  // cannot poison all later wallet work.
  static Future<void> _serialTail = Future<void>.value();

  static Stream<int> get userCoinsChanged => _userCoinsChanged.stream;
  static Stream<CharacterCoinsChanged> get characterCoinsChanged =>
      _characterCoinsChanged.stream;

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

  static String _coinKey(String accountId) =>
      accountId == userAccountId ? _userCoinKey : 'scratch_coins_$accountId';

  static int _readBalance(SharedPreferences prefs, String accountId) =>
      prefs.getInt(_coinKey(accountId)) ?? defaultCoins;

  static Future<void> _writeBalance(
    SharedPreferences prefs,
    String accountId,
    int value,
  ) async {
    await prefs.setInt(_coinKey(accountId), value);
    if (accountId == userAccountId) {
      _userCoinsChanged.add(value);
    } else {
      _characterCoinsChanged.add(
        CharacterCoinsChanged(characterId: accountId, coins: value),
      );
    }
  }

  static Map<String, dynamic> _readJournal(SharedPreferences prefs) {
    final raw = prefs.getString(_walletJournalKey);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException {
      // A corrupt journal must not make every balance read unusable. Existing
      // balances remain authoritative; future operations start a new journal.
    } on TypeError {
      // Same fallback for malformed map keys/values.
    }
    return <String, dynamic>{};
  }

  static Future<void> _writeJournal(
    SharedPreferences prefs,
    Map<String, dynamic> journal,
  ) async {
    await prefs.setString(_walletJournalKey, jsonEncode(journal));
  }

  /// Finishes every operation whose journal was persisted before all balance
  /// keys were written. No later wallet operation can pass this recovery step,
  /// so setting the recorded absolute `after` values is deterministic.
  static Future<Map<String, dynamic>> _recoverWalletLocked(
    SharedPreferences prefs,
  ) async {
    final journal = _readJournal(prefs);
    var changed = false;
    for (final entry in journal.entries) {
      final rawOperation = entry.value;
      if (rawOperation is! Map || rawOperation['status'] != 'prepared') {
        continue;
      }
      final accounts = rawOperation['accounts'];
      if (accounts is! Map) continue;
      for (final accountEntry in accounts.entries) {
        final values = accountEntry.value;
        if (values is! Map) continue;
        final after = values['after'];
        if (after is! int) continue;
        await _writeBalance(prefs, accountEntry.key.toString(), after);
      }
      rawOperation['status'] = 'applied';
      changed = true;
    }
    if (changed) await _writeJournal(prefs, journal);
    return journal;
  }

  static Future<WalletOperationResult> _applyWalletOperationLocked(
    SharedPreferences prefs, {
    required String operationId,
    required Map<String, int> deltas,
  }) async {
    if (operationId.trim().isEmpty) {
      throw ArgumentError.value(
        operationId,
        'operationId',
        'must not be empty',
      );
    }
    final journal = await _recoverWalletLocked(prefs);
    final existing = journal[operationId];
    if (existing is Map && existing['status'] == 'applied') {
      return WalletOperationResult.alreadyApplied;
    }

    final accountPlan = <String, dynamic>{};
    for (final entry in deltas.entries) {
      final before = _readBalance(prefs, entry.key);
      final after = before + entry.value;
      if (after < 0) return WalletOperationResult.insufficientFunds;
      accountPlan[entry.key] = {'before': before, 'after': after};
    }

    journal[operationId] = <String, dynamic>{
      'status': 'prepared',
      'accounts': accountPlan,
      'created_at': DateTime.now().toIso8601String(),
    };
    await _writeJournal(prefs, journal);

    for (final entry in accountPlan.entries) {
      final values = entry.value as Map;
      await _writeBalance(prefs, entry.key, values['after'] as int);
    }
    (journal[operationId] as Map)['status'] = 'applied';
    await _writeJournal(prefs, journal);
    return WalletOperationResult.applied;
  }

  static Future<void> _completeWalletOperationLocked(
    SharedPreferences prefs,
    String operationId,
  ) async {
    final journal = await _recoverWalletLocked(prefs);
    if (journal.remove(operationId) != null) {
      await _writeJournal(prefs, journal);
    }
  }

  /// Applies one or more account deltas as one recoverable operation.
  /// Call [completeWalletOperation] only after the related domain record
  /// (transfer status, scratch state, gift reservation) has been persisted.
  static Future<WalletOperationResult> applyWalletOperation({
    required String operationId,
    required Map<String, int> deltas,
  }) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      return _applyWalletOperationLocked(
        prefs,
        operationId: operationId,
        deltas: deltas,
      );
    });
  }

  static Future<bool> isWalletOperationApplied(String operationId) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final journal = await _recoverWalletLocked(prefs);
      final operation = journal[operationId];
      return operation is Map && operation['status'] == 'applied';
    });
  }

  static Future<void> completeWalletOperation(String operationId) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      await _completeWalletOperationLocked(prefs, operationId);
    });
  }

  // ══════════════════════════════════════════════
  // TODO: 每日自動發放 — 遊戲系統上線後刪除
  // ══════════════════════════════════════════════

  static Future<void> checkDailyGrant({required List<String> characterIds}) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final entities = <String>[userAccountId, ...characterIds.toSet()];

      for (final accountId in entities) {
        final markerKey = accountId == userAccountId
            ? 'scratch_daily_grant_user'
            : 'scratch_daily_grant_$accountId';
        if (prefs.getString(markerKey) == today) continue;

        final operationId = 'daily_grant:$today:$accountId';
        await _applyWalletOperationLocked(
          prefs,
          operationId: operationId,
          deltas: {accountId: _dailyGrant},
        );
        await prefs.setString(markerKey, today);
        await _completeWalletOperationLocked(prefs, operationId);
      }
    });
  }

  // ═══ 獎池（權重加總 = 100）═══

  static const List<_Prize> _pool = [
    _Prize('再來一張', 0, 35),
    _Prize('小確幸', 10, 25),
    _Prize('回本！', 30, 19),
    _Prize('不錯哦', 50, 10),
    _Prize('手氣真好', 100, 7),
    _Prize('🦦 大獎！', 500, 3),
    _Prize('🦦🦦🦦 頭獎！', 1000, 1),
  ];

  static List<ScratchResult> rollPrizes() {
    final first = _rollPrize(allowReplay: true);
    if (first.label != _replayLabel) return [first];
    return [first, _rollPrize(allowReplay: false)];
  }

  static ScratchResult _rollPrize({required bool allowReplay}) {
    final pool = allowReplay
        ? _pool
        : _pool.where((p) => p.label != _replayLabel).toList();
    final totalWeight = pool.fold<int>(0, (sum, p) => sum + p.weight);
    var roll = _rng.nextInt(totalWeight);
    for (final prize in pool) {
      roll -= prize.weight;
      if (roll < 0) {
        return ScratchResult(label: prize.label, coins: prize.coins);
      }
    }
    final fallback = pool.last;
    return ScratchResult(label: fallback.label, coins: fallback.coins);
  }

  // ═══ 遊戲幣 ═══

  static Future<int> getCoins(String characterId) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      await _recoverWalletLocked(prefs);
      return _readBalance(prefs, characterId);
    });
  }

  static Future<void> setCoins(String characterId, int value) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      await _recoverWalletLocked(prefs);
      await _writeBalance(prefs, characterId, value);
    });
  }

  static Future<bool> spend(String characterId, int amount) async {
    if (amount < 0) throw ArgumentError.value(amount, 'amount');
    final operationId = 'spend:${const Uuid().v4()}';
    final result = await applyWalletOperation(
      operationId: operationId,
      deltas: {characterId: -amount},
    );
    if (result == WalletOperationResult.insufficientFunds) return false;
    await completeWalletOperation(operationId);
    return true;
  }

  static Future<void> earn(String characterId, int amount) async {
    if (amount < 0) throw ArgumentError.value(amount, 'amount');
    final operationId = 'earn:${const Uuid().v4()}';
    await applyWalletOperation(
      operationId: operationId,
      deltas: {characterId: amount},
    );
    await completeWalletOperation(operationId);
  }

  static Future<int> getUserCoins() => getCoins(userAccountId);

  static Future<void> setUserCoins(int value) => setCoins(userAccountId, value);

  static Future<bool> spendUser(int amount) => spend(userAccountId, amount);

  static Future<void> earnUser(int amount) => earn(userAccountId, amount);

  // ═══ 刮刮樂數據持久化（按 messageId）═══

  static ScratchData? _readScratchData(
    SharedPreferences prefs,
    String messageId,
  ) {
    final raw = prefs.getString('scratch_$messageId');
    if (raw == null) return null;
    return ScratchData.fromJson(jsonDecode(raw));
  }

  static Future<void> _writeScratchData(
    SharedPreferences prefs,
    String messageId,
    ScratchData data,
  ) => prefs.setString('scratch_$messageId', jsonEncode(data.toJson()));

  static Future<ScratchData?> getData(String messageId) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      return _readScratchData(prefs, messageId);
    });
  }

  static Future<void> saveData(String messageId, ScratchData data) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      await _writeScratchData(prefs, messageId, data);
    });
  }

  /// Reveals and settles a card exactly once. `who=user` pays the user;
  /// every other value pays the supplied character account.
  static Future<ScratchClaimResult> claimScratch(
    String messageId, {
    required String characterId,
  }) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final data = _readScratchData(prefs, messageId);
      if (data == null) return const ScratchClaimResult.notFound();

      final operationId = 'scratch_claim:$messageId';
      if (data.scratched) {
        await _completeWalletOperationLocked(prefs, operationId);
        return ScratchClaimResult(
          data: data,
          settledNow: false,
          coins: data.prizes.fold(0, (sum, prize) => sum + prize.coins),
        );
      }

      final totalCoins = data.prizes.fold<int>(
        0,
        (sum, prize) => sum + prize.coins,
      );
      final recipient = data.who == 'user' ? userAccountId : characterId;
      await _applyWalletOperationLocked(
        prefs,
        operationId: operationId,
        deltas: {recipient: totalCoins},
      );

      final settled = data.copyWith(scratched: true);
      await _writeScratchData(prefs, messageId, settled);
      await _completeWalletOperationLocked(prefs, operationId);
      return ScratchClaimResult(
        data: settled,
        settledNow: true,
        coins: totalCoins,
      );
    });
  }
}

enum WalletOperationResult { applied, alreadyApplied, insufficientFunds }

class ScratchClaimResult {
  final ScratchData? data;
  final bool settledNow;
  final int coins;

  const ScratchClaimResult({
    required this.data,
    required this.settledNow,
    required this.coins,
  });

  const ScratchClaimResult.notFound()
    : data = null,
      settledNow = false,
      coins = 0;
}

class _Prize {
  final String label;
  final int coins;
  final int weight;
  const _Prize(this.label, this.coins, this.weight);
}

class ScratchResult {
  final String label;
  final int coins;
  const ScratchResult({required this.label, required this.coins});
}

class CharacterCoinsChanged {
  final String characterId;
  final int coins;

  const CharacterCoinsChanged({required this.characterId, required this.coins});
}

class ScratchData {
  final int cost;
  final String who;
  final List<ScratchResult> prizes;
  final bool scratched;

  const ScratchData({
    required this.cost,
    required this.who,
    required this.prizes,
    required this.scratched,
  });

  ScratchData copyWith({bool? scratched}) => ScratchData(
    cost: cost,
    who: who,
    prizes: prizes,
    scratched: scratched ?? this.scratched,
  );

  Map<String, dynamic> toJson() => {
    'cost': cost,
    'who': who,
    'prizes': prizes.map((p) => {'label': p.label, 'coins': p.coins}).toList(),
    'scratched': scratched,
  };

  factory ScratchData.fromJson(Map<String, dynamic> json) {
    List<ScratchResult> parsedPrizes = [];
    if (json.containsKey('prizes')) {
      parsedPrizes = (json['prizes'] as List)
          .map(
            (e) => ScratchResult(
              label: e['label'] as String,
              coins: e['coins'] as int,
            ),
          )
          .toList();
    } else {
      parsedPrizes = [
        ScratchResult(
          label: json['prize_label'] as String,
          coins: json['prize_coins'] as int,
        ),
      ];
    }
    return ScratchData(
      cost: json['cost'] as int,
      who: json['who'] as String,
      prizes: parsedPrizes,
      scratched: json['scratched'] as bool,
    );
  }
}
