import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SpiderWebNodePosition {
  final double x;
  final double y;

  const SpiderWebNodePosition(this.x, this.y);

  List<double> toJson() => [x, y];
}

class SpiderWebCurationJob {
  final List<int> memoryIds;
  final String status;
  final DateTime updatedAt;
  final String error;

  const SpiderWebCurationJob({
    required this.memoryIds,
    required this.status,
    required this.updatedAt,
    this.error = '',
  });

  bool get canResume => status == 'running' || status == 'failed';

  Map<String, Object?> toJson() => {
    'memory_ids': memoryIds,
    'status': status,
    'updated_at': updatedAt.toIso8601String(),
    'error': error,
  };
}

/// Small, portable UI state for the memory graph.
///
/// Positions are stored in web-local coordinates, so changing viewport size,
/// layer count, or a web's canvas transform does not move a saved node away
/// from its silk. Curation jobs store ids only; memory text never enters
/// SharedPreferences.
class SpiderWebStateService {
  static const String _positionPrefix = 'spider_web_node_positions_v1_';
  static const String _jobPrefix = 'spider_web_curation_job_v1_';
  static final Map<String, Future<void>> _positionWrites = {};

  static String _scope(String characterId) {
    final trimmed = characterId.trim();
    return trimmed.isEmpty ? 'default' : trimmed;
  }

  static Future<Map<int, SpiderWebNodePosition>> loadPositions(
    String characterId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_positionPrefix${_scope(characterId)}');
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <int, SpiderWebNodePosition>{};
      for (final entry in decoded.entries) {
        final id = int.tryParse(entry.key.toString());
        final coordinates = entry.value;
        if (id == null || coordinates is! List || coordinates.length != 2) {
          continue;
        }
        final x = coordinates[0];
        final y = coordinates[1];
        if (x is! num || y is! num || !x.isFinite || !y.isFinite) continue;
        result[id] = SpiderWebNodePosition(x.toDouble(), y.toDouble());
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  static Future<void> savePositions(
    String characterId,
    Map<int, SpiderWebNodePosition> positions,
  ) {
    final scope = _scope(characterId);
    final snapshot = <String, Object?>{
      for (final entry in positions.entries)
        entry.key.toString(): entry.value.toJson(),
    };
    final previous = _positionWrites[scope] ?? Future<void>.value();
    final write = previous.catchError((_) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_positionPrefix$scope', jsonEncode(snapshot));
    });
    _positionWrites[scope] = write;
    return write.whenComplete(() {
      if (identical(_positionWrites[scope], write)) {
        _positionWrites.remove(scope);
      }
    });
  }

  static Future<SpiderWebCurationJob?> loadCurationJob(
    String characterId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_jobPrefix${_scope(characterId)}');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final ids = (decoded['memory_ids'] as List? ?? const [])
          .map((value) => value is num ? value.toInt() : int.tryParse('$value'))
          .whereType<int>()
          .toSet()
          .toList(growable: false);
      final updatedAt = DateTime.tryParse(
        decoded['updated_at']?.toString() ?? '',
      );
      if (ids.length < 2 || updatedAt == null) return null;
      return SpiderWebCurationJob(
        memoryIds: ids,
        status: decoded['status']?.toString() ?? 'failed',
        updatedAt: updatedAt,
        error: decoded['error']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveCurationJob(
    String characterId,
    SpiderWebCurationJob job,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_jobPrefix${_scope(characterId)}',
      jsonEncode(job.toJson()),
    );
  }

  static Future<void> clearCurationJob(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_jobPrefix${_scope(characterId)}');
  }

  static Future<void> clearCharacterState(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    final scope = _scope(characterId);
    await Future.wait([
      prefs.remove('$_positionPrefix$scope'),
      prefs.remove('$_jobPrefix$scope'),
    ]);
  }
}
