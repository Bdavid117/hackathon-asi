import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sard_client_core/sard_client_core.dart';

import 'app.dart';

/// Nodos a los que enviar, separados por comas. En el emulador de Android `10.0.2.2` es el
/// equipo anfitrión: `--dart-define=NODES=http://10.0.2.2:8081,http://10.0.2.2:8082`.
const String _nodes = String.fromEnvironment('NODES', defaultValue: 'http://10.0.2.2:8081');
const String _keyText = String.fromEnvironment('KEY', defaultValue: 'clave-de-ejemplo');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  final key = Uint8List.fromList(utf8.encode(_keyText));
  final outbox = Outbox.open(p.join(dir.path, 'outbox.db'), key: key);
  final client = http.Client();
  final scheduler = SendScheduler(
    outbox: outbox,
    channel: FailoverChannel([for (final u in _nodes.split(',')) HttpChannel(Uri.parse(u), client)]),
    key: key,
  );
  var pumping = false;
  Timer.periodic(const Duration(seconds: 3), (_) async {
    if (pumping) return;
    pumping = true;
    try {
      await scheduler.pump();
    } finally {
      pumping = false;
    }
  });
  runApp(SardApp(outbox: outbox, scheduler: scheduler, battery: () => Battery().batteryLevel));
}
