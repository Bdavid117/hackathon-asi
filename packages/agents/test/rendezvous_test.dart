import 'package:sard_agents/sard_agents.dart';
import 'package:test/test.dart';

void main() {
  group('peso: SHA-256 de «nodo|reporte», primeros 8 bytes (valores de oro calculados aparte, en Python)', () {
    test('los valores de oro no cambian', () {
      expect(rendezvousWeight('A', 'a1b2c3d4e5f60718-1'), '6085e6a2b85ca3ca');
      expect(rendezvousWeight('B', 'a1b2c3d4e5f60718-1'), 'b06dc765391884a5');
      expect(rendezvousWeight('C', 'a1b2c3d4e5f60718-1'), '118f42f79f418e49');
      expect(rendezvousWeight('A', '0000000000000001-7'), '51990c6554f4d877');
      expect(rendezvousWeight('B', '0000000000000001-7'), 'f17fc9fb6ea5ed24');
      expect(rendezvousWeight('C', '0000000000000001-7'), '3a25e91d5e4c8ce4');
    });

    test('vacíos y no ASCII se codifican en UTF-8', () {
      expect(rendezvousWeight('A', ''), '0bcdb101896e0552');
      expect(rendezvousWeight('nodo-ñ', 'reporte-ü'), 'cabcb0f07e0ff379');
    });

    test('es de 16 caracteres hexadecimales en minúscula', () {
      expect(rendezvousWeight('X', 'y'), matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('el separador no es ambiguo: («A|B», «k») y («A», «B|k») son entradas distintas pero comparables', () {
      // «nodo|reporte» se concatena tal cual: se documenta que un identificador no debe contener «|»
      expect(rendezvousWeight('A|B', 'k'), rendezvousWeight('A', 'B|k'), reason: 'la especificación es la concatenación literal');
    });
  });

  group('rendezvousOwner', () {
    const key = 'a1b2c3d4e5f60718-1';

    test('es el nodo de mayor peso: con A, B y C gana B (valor de oro)', () {
      expect(rendezvousOwner(key, ['A', 'B', 'C']), 'B');
      expect(rendezvousOwner('0000000000000001-7', ['A', 'B', 'C']), 'B');
    });

    test('un solo nodo es siempre el dueño; ninguno vivo no tiene dueño', () {
      expect(rendezvousOwner(key, ['A']), 'A');
      expect(rendezvousOwner(key, const []), isNull);
    });

    test('no depende del orden en que se den los nodos ni de repetidos', () {
      expect(rendezvousOwner(key, ['C', 'A', 'B']), 'B');
      expect(rendezvousOwner(key, ['B', 'B', 'A', 'A', 'C']), 'B');
    });

    test('al quitar un nodo que NO es el dueño, el dueño no cambia (estabilidad)', () {
      expect(rendezvousOwner(key, ['A', 'B']), 'B');
      expect(rendezvousOwner(key, ['B', 'C']), 'B');
    });

    test('al quitar el dueño, pasa al SIGUIENTE en el orden de relevo', () {
      expect(rendezvousOwner(key, ['A', 'C']), 'A');
      expect(rendezvousOrder(key, ['A', 'B', 'C']), ['B', 'A', 'C']);
    });

    test('estabilidad en general: quitar un nodo ajeno nunca cambia el dueño (2 000 reportes, 5 nodos)', () {
      const nodes = ['A', 'B', 'C', 'D', 'E'];
      for (var i = 0; i < 2000; i++) {
        final k = 'dev${i % 37}-$i';
        final owner = rendezvousOwner(k, nodes)!;
        for (final gone in nodes) {
          if (gone == owner) continue;
          expect(rendezvousOwner(k, nodes.where((n) => n != gone)), owner, reason: '$k sin $gone');
        }
      }
    });

    test('reparto equilibrado entre 3 nodos (10 000 reportes: cada uno entre el 30 % y el 37 %)', () {
      final counts = {'A': 0, 'B': 0, 'C': 0};
      for (var i = 0; i < 10000; i++) {
        counts.update(rendezvousOwner('d${i * 7919 % 977}-$i', ['A', 'B', 'C'])!, (n) => n + 1);
      }
      for (final e in counts.entries) {
        expect(e.value, inInclusiveRange(3000, 3700), reason: '${e.key}: ${e.value}');
      }
    });

    test('al quitar un nodo, sólo cambian de dueño los reportes que eran suyos (≈ 1/3), no todos', () {
      var moved = 0;
      for (var i = 0; i < 6000; i++) {
        final k = 'd${i % 101}-$i';
        if (rendezvousOwner(k, ['A', 'B', 'C']) != rendezvousOwner(k, ['A', 'B'])) moved++;
      }
      expect(moved, inInclusiveRange(1600, 2400), reason: 'cambian los de C: ≈ 2 000 de 6 000; un hash módulo-n movería ≈ 4 000');
    });
  });

  group('rendezvousOrder: el orden de relevo', () {
    test('devuelve todos los nodos sin repetir, el dueño primero', () {
      final o = rendezvousOrder('k-1', ['A', 'B', 'C', 'B']);
      expect(o, hasLength(3));
      expect(o.first, rendezvousOwner('k-1', ['A', 'B', 'C']));
      expect(o.toSet(), {'A', 'B', 'C'});
    });

    test('un empate de pesos (imposible en la práctica) se rompe por el identificador más pequeño', () {
      expect(rendezvousOrder('k', ['A', 'A']), ['A']);
    });

    test('rank da la posición de un nodo en el relevo; null si no está', () {
      expect(rendezvousRank('a1b2c3d4e5f60718-1', 'B', ['A', 'B', 'C']), 0);
      expect(rendezvousRank('a1b2c3d4e5f60718-1', 'A', ['A', 'B', 'C']), 1);
      expect(rendezvousRank('a1b2c3d4e5f60718-1', 'C', ['A', 'B', 'C']), 2);
      expect(rendezvousRank('a1b2c3d4e5f60718-1', 'Z', ['A', 'B', 'C']), isNull);
    });
  });
}
