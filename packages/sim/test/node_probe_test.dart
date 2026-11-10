import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

void main() {
  group('NodeProbe.uniqueById', () {
    test('un evento que traen varios nodos cuenta UNA vez y se conserva el orden de la primera aparición', () {
      final a = {'id': 'A:000001', 'origin': 'A'}, b = {'id': 'B:000001', 'origin': 'B'};
      final fromNodeA = [a, b], fromNodeB = [b, a], fromNodeC = [a];
      final all = NodeProbe.uniqueById([...fromNodeA, ...fromNodeB, ...fromNodeC]);
      expect([for (final e in all) e['id']], ['A:000001', 'B:000001']);
    });

    test('contar por origen con y sin deduplicar muestra el error: sin ella, 3 nodos triplican el reparto', () {
      final events = [for (var i = 1; i <= 4; i++) {'id': 'A:00000$i', 'origin': 'A'}];
      final threeNodes = [...events, ...events, ...events];
      expect(threeNodes.length, 12);
      expect(NodeProbe.uniqueById(threeNodes).length, 4);
    });

    test('un evento sin identificador no se descarta ni se confunde con otro', () {
      final x = {'origin': 'A'}, y = {'origin': 'B'};
      expect(NodeProbe.uniqueById([x, y, x]).length, 3, reason: 'sin id no se puede saber: se conserva cada uno');
    });
  });
}
