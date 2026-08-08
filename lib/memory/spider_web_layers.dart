import 'dart:math';

import '../models/memory.dart';

/// A render-time web inside one memory plane. The shape is still produced by
/// SpiderWebGraphView; this planner only decides which memories share a web.
class SpiderWebClusterPlan {
  final String id;
  final bool isSmall;
  final List<Memory> memories;

  const SpiderWebClusterPlan({
    required this.id,
    required this.isSmall,
    required this.memories,
  });
}

/// One selectable plane. A plane may contain several webs, but never renders
/// more than [SpiderWebLayerPlanner.maxNodesPerLayer] memory nodes.
class SpiderWebLayerPlan {
  final String id;
  final String mode;
  final String label;
  final List<SpiderWebClusterPlan> webs;
  final List<Map<String, dynamic>> links;
  final List<Map<String, dynamic>> crossLayerLinks;
  final int crossLayerLinkCount;

  const SpiderWebLayerPlan({
    required this.id,
    required this.mode,
    required this.label,
    required this.webs,
    required this.links,
    required this.crossLayerLinks,
    required this.crossLayerLinkCount,
  });

  List<Memory> get memories => [for (final web in webs) ...web.memories];
}

/// Deterministic, non-destructive planner for existing memories.
///
/// Existing links form compact overlap webs (up to 20 nodes). Unlinked items
/// are grouped by mode/category into large webs (up to 50 nodes). Several webs
/// may share a plane, while a plane itself is capped at 50 rendered nodes.
class SpiderWebLayerPlanner {
  static const int largeWebCapacity = 50;
  static const int smallWebCapacity = 20;
  static const int maxNodesPerLayer = 50;
  static const int maxWebsPerLayer = 4;

  static List<SpiderWebLayerPlan> build({
    required List<Memory> memories,
    required List<Map<String, dynamic>> links,
  }) {
    final byId = <int, Memory>{
      for (final memory in memories)
        if (memory.id != null) memory.id!: memory,
    };
    if (byId.isEmpty) return const [];

    final parent = <int, int>{for (final id in byId.keys) id: id};

    int find(int id) {
      var root = id;
      while (parent[root] != root) {
        root = parent[root]!;
      }
      var current = id;
      while (parent[current] != current) {
        final next = parent[current]!;
        parent[current] = root;
        current = next;
      }
      return root;
    }

    void union(int left, int right) {
      final leftRoot = find(left);
      final rightRoot = find(right);
      if (leftRoot == rightRoot) return;
      parent[rightRoot] = leftRoot;
    }

    // A cross-mode edge remains a cross-plane portal. Same-mode edges keep
    // old linked memories together so they can no longer disappear silently.
    for (final link in links) {
      final left = _asInt(link['memory_id_1']);
      final right = _asInt(link['memory_id_2']);
      final leftMemory = left == null ? null : byId[left];
      final rightMemory = right == null ? null : byId[right];
      if (leftMemory == null || rightMemory == null) continue;
      if (leftMemory.mode != rightMemory.mode) continue;
      union(left!, right!);
    }

    final linkedGroups = <String, List<Memory>>{};
    final linkedIds = <int>{};
    for (final memory in memories) {
      final id = memory.id;
      if (id == null) continue;
      final root = find(id);
      final hasRealNeighbor = links.any((link) {
        final left = _asInt(link['memory_id_1']);
        final right = _asInt(link['memory_id_2']);
        if (left != id && right != id) return false;
        final other = left == id ? right : left;
        return other != null &&
            byId[other] != null &&
            byId[other]!.mode == memory.mode;
      });
      if (!hasRealNeighbor) continue;
      linkedIds.add(id);
      linkedGroups.putIfAbsent('${memory.mode}:$root', () => []).add(memory);
    }

    final clusters = <_MutableCluster>[];
    for (final entry in linkedGroups.entries) {
      final sorted = [...entry.value]..sort(_compareMemoryImportance);
      if (sorted.length <= smallWebCapacity) {
        clusters.add(
          _MutableCluster(
            id: 'linked:${entry.key}',
            mode: sorted.first.mode,
            category: sorted.first.category,
            isSmall: true,
            memories: sorted,
          ),
        );
      } else {
        // Highly connected components stay on the compact 20-node variant.
        // Oversized groups extend into another compact web instead of
        // silently changing their visual meaning to a large loose web.
        for (
          var offset = 0;
          offset < sorted.length;
          offset += smallWebCapacity
        ) {
          final end = min(offset + smallWebCapacity, sorted.length);
          clusters.add(
            _MutableCluster(
              id: 'linked:${entry.key}:${offset ~/ smallWebCapacity}',
              mode: sorted.first.mode,
              category: sorted.first.category,
              isSmall: true,
              memories: sorted.sublist(offset, end),
            ),
          );
        }
      }
    }

    final looseGroups = <String, List<Memory>>{};
    for (final memory in memories) {
      final id = memory.id;
      if (id == null || linkedIds.contains(id)) continue;
      final category = memory.category.trim().isEmpty
          ? 'memory'
          : memory.category.trim();
      looseGroups.putIfAbsent('${memory.mode}:$category', () => []).add(memory);
    }
    for (final entry in looseGroups.entries) {
      final sorted = [...entry.value]..sort(_compareMemoryImportance);
      for (var offset = 0; offset < sorted.length; offset += largeWebCapacity) {
        final end = min(offset + largeWebCapacity, sorted.length);
        final slice = sorted.sublist(offset, end);
        clusters.add(
          _MutableCluster(
            id: 'loose:${entry.key}:${offset ~/ largeWebCapacity}',
            mode: slice.first.mode,
            category: slice.first.category,
            isSmall: false,
            memories: slice,
          ),
        );
      }
    }

    clusters.sort((left, right) {
      final byMode = left.mode.compareTo(right.mode);
      if (byMode != 0) return byMode;
      if (left.isSmall != right.isSmall) return left.isSmall ? -1 : 1;
      final byCategory = left.category.compareTo(right.category);
      if (byCategory != 0) return byCategory;
      return left.id.compareTo(right.id);
    });

    final mutableLayers = <_MutableLayer>[];
    for (final cluster in clusters) {
      _MutableLayer? target;
      for (final layer in mutableLayers.reversed) {
        if (layer.mode != cluster.mode) continue;
        if (layer.webs.length >= maxWebsPerLayer) continue;
        if (layer.nodeCount + cluster.memories.length > maxNodesPerLayer) {
          continue;
        }
        target = layer;
        break;
      }
      target ??= _MutableLayer(
        id: '${cluster.mode}:${mutableLayers.where((l) => l.mode == cluster.mode).length}',
        mode: cluster.mode,
      );
      if (!mutableLayers.contains(target)) mutableLayers.add(target);
      target.webs.add(cluster);
    }

    final layerByMemoryId = <int, int>{};
    for (var layerIndex = 0; layerIndex < mutableLayers.length; layerIndex++) {
      for (final web in mutableLayers[layerIndex].webs) {
        for (final memory in web.memories) {
          if (memory.id != null) layerByMemoryId[memory.id!] = layerIndex;
        }
      }
    }

    final internalLinks = <int, List<Map<String, dynamic>>>{};
    final crossLinks = <int, List<Map<String, dynamic>>>{};
    for (final link in links) {
      final left = _asInt(link['memory_id_1']);
      final right = _asInt(link['memory_id_2']);
      if (left == null || right == null) continue;
      final leftLayer = layerByMemoryId[left];
      final rightLayer = layerByMemoryId[right];
      if (leftLayer == null || rightLayer == null) continue;
      if (leftLayer == rightLayer) {
        internalLinks.putIfAbsent(leftLayer, () => []).add(link);
      } else {
        crossLinks.putIfAbsent(leftLayer, () => []).add(link);
        crossLinks.putIfAbsent(rightLayer, () => []).add(link);
      }
    }

    return [
      for (var index = 0; index < mutableLayers.length; index++)
        SpiderWebLayerPlan(
          id: mutableLayers[index].id,
          mode: mutableLayers[index].mode,
          label: _layerLabel(mutableLayers[index], index),
          webs: [
            for (final web in mutableLayers[index].webs)
              SpiderWebClusterPlan(
                id: web.id,
                isSmall: web.isSmall,
                memories: List<Memory>.unmodifiable(web.memories),
              ),
          ],
          links: List<Map<String, dynamic>>.unmodifiable(
            internalLinks[index] ?? const [],
          ),
          crossLayerLinks: List<Map<String, dynamic>>.unmodifiable(
            crossLinks[index] ?? const [],
          ),
          crossLayerLinkCount: crossLinks[index]?.length ?? 0,
        ),
    ];
  }

  static int _compareMemoryImportance(Memory left, Memory right) {
    if (left.isPermanent != right.isPermanent) {
      return left.isPermanent ? -1 : 1;
    }
    final byMentions = right.mentionCount.compareTo(left.mentionCount);
    if (byMentions != 0) return byMentions;
    final byUpdated = right.updatedAt.compareTo(left.updatedAt);
    if (byUpdated != 0) return byUpdated;
    return (left.id ?? 0).compareTo(right.id ?? 0);
  }

  static String _layerLabel(_MutableLayer layer, int fallbackIndex) {
    final categories = <String, int>{};
    for (final web in layer.webs) {
      for (final memory in web.memories) {
        final key = memory.category.trim();
        if (key.isEmpty) continue;
        categories[key] = (categories[key] ?? 0) + 1;
      }
    }
    if (categories.isEmpty) return '${layer.mode} ${fallbackIndex + 1}';
    final sorted = categories.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}

class _MutableCluster {
  final String id;
  final String mode;
  final String category;
  final bool isSmall;
  final List<Memory> memories;

  _MutableCluster({
    required this.id,
    required this.mode,
    required this.category,
    required this.isSmall,
    required this.memories,
  });
}

class _MutableLayer {
  final String id;
  final String mode;
  final List<_MutableCluster> webs = [];

  _MutableLayer({required this.id, required this.mode});

  int get nodeCount =>
      webs.fold(0, (total, web) => total + web.memories.length);
}
