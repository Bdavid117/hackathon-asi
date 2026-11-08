import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sard-nodeproc-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'se niega a arrancar si algo ya responde /api/health en ese puerto, y no lo toca',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response
          ..statusCode = 200
          ..write(jsonEncode({'node': 'ajeno'}))
          ..close();
      });
      await expectLater(
        NodeProcess.start(id: 'A', port: server.port, dataDir: '${dir.path}/A'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('ya está en uso'),
          ),
        ),
      );
      // El servicio ajeno sigue vivo y respondiendo.
      final r = await http.get(
        Uri.parse('http://localhost:${server.port}/api/health'),
      );
      expect(r.statusCode, 200);
      expect(r.body, contains('ajeno'));
      await server.close(force: true);
    },
  );

  test(
    'arranca un nodo real, responde, y kill9 lo deja sin responder ni procesos',
    () async {
      final port = await freePort();
      final node = await NodeProcess.start(
        id: 'T',
        port: port,
        dataDir: '${dir.path}/T',
      );
      final ok = await http.get(node.url.resolve('/api/health'));
      expect(ok.statusCode, 200);
      expect(jsonDecode(ok.body)['node'], 'T');

      node.kill9();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await expectLater(
        http
            .get(node.url.resolve('/api/health'))
            .timeout(const Duration(seconds: 1)),
        throwsA(anything),
      );
      final left = Process.runSync('pgrep', [
        '-f',
        'sard_node.dart.*--port $port',
      ]);
      expect(
        '${left.stdout}'.trim(),
        isEmpty,
        reason: 'no debe quedar ningún proceso del nodo',
      );
    },
  );
}
