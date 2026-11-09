import 'dart:io';

import 'package:flutter/services.dart';

/// Carga Roboto (la fuente real de Android) desde el SDK de Flutter.
///
/// Por omisión las pruebas de widgets dibujan con «Ahem», donde cada letra mide un cuadrado entero: los textos
/// salen mucho más anchos que en un teléfono y una prueba de «¿cabe?» mide algo falso. Con Roboto las medidas son
/// las de un Android de verdad. Cárguese en `setUpAll` de un archivo que sólo mida textos (la fuente queda
/// cargada para todo el archivo).
Future<void> loadRealFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) throw StateError('FLUTTER_ROOT no está definida: no encuentro las fuentes del SDK');
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    final file = File('$dir/$f');
    if (!file.existsSync()) throw StateError('falta $dir/$f');
    loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await loader.load();
}
