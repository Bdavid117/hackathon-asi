import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sard_client_core/sard_client_core.dart';

import 'app.dart';
import 'location_geolocator.dart';

/// Nodos a los que enviar, separados por comas. En el emulador de Android `10.0.2.2` es el
/// equipo anfitrión: `--dart-define=NODES=http://10.0.2.2:8081,http://10.0.2.2:8082`.
const String _nodes = String.fromEnvironment(
  'NODES',
  defaultValue: 'http://10.0.2.2:8081',
);
const String _keyText = String.fromEnvironment(
  'KEY',
  defaultValue: 'clave-de-ejemplo',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  final key = Uint8List.fromList(utf8.encode(_keyText));
  final outbox = Outbox.open(p.join(dir.path, 'outbox.db'), key: key);
  final client = http.Client();
  final scheduler = SendScheduler(
    outbox: outbox,
    channel: FailoverChannel([
      for (final u in _nodes.split(',')) HttpChannel(Uri.parse(u), client),
    ]),
    key: key,
  );
  // Un único punto decide cuándo enviar: al volver la red (libera las esperas de reintento) y
  // cada 3 s mientras haya red. Sin red no se intenta nada.
  final trigger = PumpTrigger(
    pump: scheduler.pump,
    releaseBackoff: outbox.releaseBackoff,
  );
  Timer.periodic(
    const Duration(seconds: 3),
    (_) => unawaited(trigger.onEvent()),
  );
  bool hasNetwork(List<ConnectivityResult> r) =>
      r.any((x) => x != ConnectivityResult.none);
  // La pantalla avisa cuando no hay red: «tu SOS se guarda y saldrá solo».
  final online = ValueNotifier<bool>(true);
  void onNetwork(List<ConnectivityResult> r) {
    online.value = hasNetwork(r);
    unawaited(trigger.onConnectivity(online.value));
  }

  final connectivity = Connectivity();
  connectivity.onConnectivityChanged.listen(onNetwork);
  unawaited(connectivity.checkConnectivity().then(onNetwork));
  runApp(
    SardApp(
      outbox: outbox,
      scheduler: scheduler,
      battery: () => Battery().batteryLevel,
      location: GeolocatorLocationProvider(),
      onNewReport: trigger.onNewReport,
      online: online,
    ),
  );
  // El permiso se pide DESPUÉS de pintar la primera pantalla: el botón SOS nunca espera a un
  // diálogo, y el cuadro del sistema no aparece sobre una pantalla en blanco.
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(GeolocatorLocationProvider.requestPermissionOnce()),
  );
}
