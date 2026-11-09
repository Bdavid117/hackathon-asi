import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_mobile/app.dart';
import 'package:sard_mobile/brand.dart';

/// Dibuja [child] a 1 px lógico = 1 px y devuelve los píxeles RGBA.
Future<(ByteData, int)> pixels(WidgetTester tester, Widget child, {required int size}) async {
  final key = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(size.toDouble() + 20, size.toDouble() + 20);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: Align(alignment: Alignment.topLeft, child: RepaintBoundary(key: key, child: child))));
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final img = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
  final data = await tester.runAsync(() => img!.toByteData(format: ui.ImageByteFormat.rawRgba));
  return (data!, img!.width);
}

({int r, int g, int b, int a}) at((ByteData, int) px, int x, int y) {
  final (data, w) = px;
  final i = (y * w + x) * 4;
  return (r: data.getUint8(i), g: data.getUint8(i + 1), b: data.getUint8(i + 2), a: data.getUint8(i + 3));
}

void expectColor(({int r, int g, int b, int a}) p, int rgb, {String? reason, int tol = 6}) {
  final r = (rgb >> 16) & 255, g = (rgb >> 8) & 255, b = rgb & 255;
  expect((p.r - r).abs() <= tol && (p.g - g).abs() <= tol && (p.b - b).abs() <= tol && p.a > 240, isTrue, reason: '${reason ?? ''} esperaba #${rgb.toRadixString(16)}, hay (${p.r},${p.g},${p.b},a=${p.a})');
}

void main() {
  group('SardMark: la marca dibujada en la cuadrícula de 108 (valores medidos en píxeles)', () {
    testWidgets('el disco es el rojo del botón SOS y el anillo es el rojo claro, pegado al disco', (tester) async {
      final px = await pixels(tester, const SardMark(size: 108, detailed: true), size: 108);
      expectColor(at(px, 54, 28), 0xD23B2E, reason: 'disco');
      expectColor(at(px, 54, 23), 0xE5857C, reason: 'anillo (centro del trazo, radio 31)');
    });

    testWidgets('fuera de la marca no hay nada: las esquinas son transparentes', (tester) async {
      final px = await pixels(tester, const SardMark(size: 108, detailed: true), size: 108);
      for (final (x, y) in [(2, 2), (105, 2), (2, 105), (105, 105)]) {
        expect(at(px, x, y).a, 0, reason: '($x,$y)');
      }
    });

    testWidgets('el HUECO de la S es de verdad un hueco: en el centro se ve el rojo del disco (la conexión que se cae)', (tester) async {
      final px = await pixels(tester, const SardMark(size: 108, detailed: true), size: 108);
      expectColor(at(px, 54, 54), 0xD23B2E, reason: 'centro');
    });

    testWidgets('la S es clara: un punto sobre el arco superior es el blanco del texto', (tester) async {
      final px = await pixels(tester, const SardMark(size: 108, detailed: true), size: 108);
      expectColor(at(px, 42, 41), 0xEEF1F5, reason: 'arco superior, tramo izquierdo');
      expectColor(at(px, 66, 63), 0xEEF1F5, reason: 'arco inferior, tramo derecho');
    });

    testWidgets('versión detallada: cada nodo tiene centro claro y anillo oscuro', (tester) async {
      final px = await pixels(tester, const SardMark(size: 108, detailed: true), size: 108);
      expectColor(at(px, 66, 40), 0xEEF1F5, reason: 'centro del nodo superior');
      expectColor(at(px, 70, 40), 0x12161C, reason: 'anillo del nodo superior');
      expectColor(at(px, 42, 68), 0xEEF1F5, reason: 'centro del nodo inferior');
      expectColor(at(px, 38, 68), 0x12161C, reason: 'anillo del nodo inferior');
    });

    testWidgets('versión pequeña: nodos LLENOS (sin anillo oscuro) para que no se empasten', (tester) async {
      final px = await pixels(tester, const SardMark(size: 108, detailed: false), size: 108);
      expectColor(at(px, 66, 40), 0xEEF1F5);
      expectColor(at(px, 70, 40), 0xEEF1F5, reason: 'donde la detallada tiene el anillo');
    });

    testWidgets('versión pequeña: el trazo es algo más grueso (8 frente a 7) para que aguante a 24 px', (tester) async {
      // a 216 px (el doble) un píxel cae a 7,7 del eje del arco: fuera de un trazo de radio 7, dentro de uno de radio 8
      final big = await pixels(tester, const SardMark(size: 216, detailed: true), size: 216);
      final small = await pixels(tester, const SardMark(size: 216, detailed: false), size: 216);
      // el borde del trazo cae dentro del píxel: se compara «casi blanco» frente a «rojo», no un color exacto
      expect(at(big, 76, 84).g, lessThan(90), reason: 'detallada: fuera del trazo de 7 (rojo)');
      expect(at(small, 76, 84).g, greaterThan(190), reason: 'pequeña: dentro del trazo de 8 (casi blanco)');
    });

    testWidgets('«detailed» por omisión: completa desde 48 px y llena por debajo', (tester) async {
      expect(const SardMark(size: 48).useDetailed, isTrue);
      expect(const SardMark(size: 96).useDetailed, isTrue);
      expect(const SardMark(size: 40).useDetailed, isFalse);
      expect(const SardMark(size: 28).useDetailed, isFalse);
      expect(const SardMark(size: 28, detailed: true).useDetailed, isTrue);
    });

    testWidgets('escala: a 54 px el disco sigue en el mismo sitio relativo', (tester) async {
      final px = await pixels(tester, const SardMark(size: 54, detailed: true), size: 54);
      expectColor(at(px, 27, 14), 0xD23B2E, reason: 'disco a mitad de tamaño');
      expect(at(px, 1, 1).a, 0);
    });

    testWidgets('para el lector de pantalla es una imagen con nombre', (tester) async {
      await tester.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: SardMark(size: 40)));
      final sem = tester.getSemantics(find.byType(SardMark));
      expect(sem.label, 'SARD');
    });
  });

  group('la marca en la pantalla principal', () {
    testWidgets('la barra de arriba lleva la marca y el nombre; no estorba al SOS', (tester) async {
      final outbox = Outbox.open(':memory:', key: Uint8List.fromList(List.filled(16, 1)));
      addTearDown(outbox.close);
      tester.view.devicePixelRatio = 2.625;
      tester.view.physicalSize = const Size(411 * 2.625, 914 * 2.625);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SardApp(outbox: outbox, refreshEvery: null));
      await tester.pump();
      expect(find.byKey(const Key('brand_mark')), findsOneWidget);
      expect(find.text('SARD'), findsOneWidget);
      final mark = tester.getRect(find.byKey(const Key('brand_mark')));
      expect(mark.height, lessThanOrEqualTo(40));
      expect(mark.top, greaterThanOrEqualTo(0));
      // el SOS sigue en su sitio: la marca no empuja nada
      expect(tester.getTopLeft(find.byKey(const Key('sos_button'))).dy, greaterThan(mark.bottom));
    });
  });

  group('lo que ve quien instala la app', () {
    test('Android: el nombre bajo el ícono es «SARD», no el del paquete', () {
      final m = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(RegExp(r'android:label="([^"]*)"').firstMatch(m)!.group(1), 'SARD');
    });
    test('Android: el ícono es adaptativo, con capa de marca, de fondo y monocromo (Android 13)', () {
      final a = File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml').readAsStringSync();
      expect(a, contains('<background android:drawable="@color/ic_launcher_background"/>'));
      expect(a, contains('<foreground android:drawable="@drawable/ic_launcher_foreground"/>'));
      expect(a, contains('<monochrome android:drawable="@drawable/ic_launcher_monochrome"/>'));
      expect(File('android/app/src/main/res/drawable/ic_launcher_foreground.xml').existsSync(), isTrue);
      expect(File('android/app/src/main/res/drawable/ic_launcher_monochrome.xml').existsSync(), isTrue);
      expect(File('android/app/src/main/res/values/ic_launcher_colors.xml').readAsStringSync(), contains('#12161C'));
    });
    test('Android: la capa de marca queda dentro del círculo seguro de 66 dp (radio 33 sobre 108)', () {
      final fg = File('android/app/src/main/res/drawable/ic_launcher_foreground.xml').readAsStringSync();
      expect(fg, contains('android:viewportWidth="108"'));
      // disco r=31 + medio trazo del anillo (2) = 33: justo en el borde de la zona segura
      expect(fg, contains('M54,54m-31,0a31,31'));
      expect(fg, isNot(contains('m-35,0')), reason: 'nada más grande que la zona segura');
    });
    test('iOS: el nombre bajo el ícono es «SARD»', () {
      final p = File('ios/Runner/Info.plist').readAsStringSync();
      expect(RegExp(r'<key>CFBundleDisplayName</key>\s*<string>([^<]*)</string>').firstMatch(p)!.group(1), 'SARD');
      expect(RegExp(r'<key>CFBundleName</key>\s*<string>([^<]*)</string>').firstMatch(p)!.group(1), 'SARD');
    });
    test('iOS: ningún ícono lleva canal alfa (la App Store lo rechaza) y todos tienen el tamaño que declaran', () {
      final dir = Directory('ios/Runner/Assets.xcassets/AppIcon.appiconset');
      final contents = jsonDecode(File('${dir.path}/Contents.json').readAsStringSync()) as Map<String, dynamic>;
      for (final i in contents['images'] as List) {
        final img = i as Map<String, dynamic>;
        final bytes = File('${dir.path}/${img['filename']}').readAsBytesSync();
        final bd = ByteData.sublistView(Uint8List.fromList(bytes));
        final w = bd.getUint32(16), h = bd.getUint32(20), colorType = bytes[25];
        final px = (double.parse((img['size'] as String).split('x').first) * int.parse((img['scale'] as String).replaceAll('x', ''))).round();
        expect(w, px, reason: '${img['filename']} ancho');
        expect(h, px, reason: '${img['filename']} alto');
        expect(colorType, 2, reason: '${img['filename']}: RGB sin alfa');
      }
    });
    test('iOS: el ícono de 1024 existe (el de la tienda)', () {
      expect(File('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png').lengthSync(), greaterThan(5000));
    });
  });
}
