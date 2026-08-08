import 'package:flutter_test/flutter_test.dart';
import 'package:project_yanci/memory/spider_web_layers.dart';
import 'package:project_yanci/models/memory.dart';

Memory memory(int id, {String mode = 'romance', String category = '事件'}) {
  return Memory(
    id: id,
    characterId: 'char',
    mode: mode,
    category: category,
    content: 'memory $id',
    mentionCount: id % 7,
  );
}

Map<String, dynamic> link(int left, int right) => {
  'memory_id_1': left,
  'memory_id_2': right,
};

void main() {
  group('SpiderWebLayerPlanner', () {
    test('keeps every old memory while capping each plane at 50', () {
      final memories = [for (var id = 1; id <= 117; id++) memory(id)];
      final layers = SpiderWebLayerPlanner.build(memories: memories, links: []);

      expect(layers.expand((layer) => layer.memories).length, 117);
      expect(
        layers.every(
          (layer) =>
              layer.memories.length <= SpiderWebLayerPlanner.maxNodesPerLayer,
        ),
        isTrue,
      );
      expect(
        layers
            .expand((layer) => layer.memories)
            .map((memory) => memory.id)
            .toSet(),
        {for (var id = 1; id <= 117; id++) id},
      );
    });

    test('turns a highly linked group of at most 20 into a small web', () {
      final memories = [for (var id = 1; id <= 8; id++) memory(id)];
      final links = [for (var id = 2; id <= 8; id++) link(1, id)];

      final layers = SpiderWebLayerPlanner.build(
        memories: memories,
        links: links,
      );

      expect(layers.single.webs.single.isSmall, isTrue);
      expect(layers.single.webs.single.memories.length, 8);
      expect(layers.single.links.length, 7);
    });

    test('extends oversized linked groups as multiple 20-node small webs', () {
      final memories = [for (var id = 1; id <= 45; id++) memory(id)];
      final links = [for (var id = 2; id <= 45; id++) link(1, id)];

      final layers = SpiderWebLayerPlanner.build(
        memories: memories,
        links: links,
      );
      final webs = layers.expand((layer) => layer.webs).toList();

      expect(webs.map((web) => web.memories.length), [20, 20, 5]);
      expect(webs.every((web) => web.isSmall), isTrue);
    });

    test('keeps a cross-mode edge visible as a cross-layer relation', () {
      final layers = SpiderWebLayerPlanner.build(
        memories: [
          memory(1),
          memory(2, mode: 'story'),
        ],
        links: [link(1, 2)],
      );

      expect(layers, hasLength(2));
      expect(layers.every((layer) => layer.links.isEmpty), isTrue);
      expect(layers.every((layer) => layer.crossLayerLinkCount == 1), isTrue);
      expect(
        layers.every(
          (layer) => layer.crossLayerLinks.single['memory_id_1'] == 1,
        ),
        isTrue,
      );
    });
  });
}
