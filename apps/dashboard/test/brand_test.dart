import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/brand.dart';
import 'package:sard_dashboard/dashboard_screen.dart';

import 'fake_api.dart';

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
  group('SardMark del tablero: la MISMA marca que la app (cuadrícula de 108)', () {
    testWidgets('disco rojo del SOS, anillo claro, esquinas transparentes', (tester) async {
      final px = await pixels(tester, const SardMark(size: 108, detailed: true), size: 108);
      expectColor(at(px, 54, 28), 0xD23B2E, reason: 'disco');
      expectColor(at(px, 54, 23), 0xE5857C, reason: 'anillo');
      expect(at(px, 2, 2).a, 0);
      expect(at(px, 105, 105).a, 0);
    });

    testWidgets('la S tiene el hueco del centro (se ve el disco) y es clara en sus arcos', (tester) async {
      final px = await pixels(tester, const SardMark(size: 108, detailed: true), size: 108);
      expectColor(at(px, 54, 54), 0xD23B2E, reason: 'hueco central');
      expectColor(at(px, 42, 41), 0xEEF1F5, reason: 'arco superior');
      expectColor(at(px, 66, 63), 0xEEF1F5, reason: 'arco inferior');
    });

    testWidgets('nodos: con anillo oscuro en la versión completa, llenos en la pequeña', (tester) async {
      final big = await pixels(tester, const SardMark(size: 108, detailed: true), size: 108);
      expectColor(at(big, 66, 40), 0xEEF1F5);
      expectColor(at(big, 70, 40), 0x12161C, reason: 'anillo del nodo');
      final small = await pixels(tester, const SardMark(size: 108, detailed: false), size: 108);
      expectColor(at(small, 70, 40), 0xEEF1F5, reason: 'nodo lleno');
    });

    testWidgets('completa desde 48 px, llena por debajo; el lector de pantalla la nombra', (tester) async {
      expect(const SardMark(size: 48).useDetailed, isTrue);
      expect(const SardMark(size: 40).useDetailed, isFalse);
      await tester.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: SardMark(size: 30)));
      expect(tester.getSemantics(find.byType(SardMark)).label, 'SARD');
    });
  });

  group('en la pantalla del tablero', () {
    testWidgets('la barra de arriba lleva la marca delante del título', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: FakeApi(), every: null, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
      await tester.pumpAndSettle();
      final mark = tester.getRect(find.byKey(const Key('brand_mark')));
      final title = tester.getRect(find.text('SARD · Tablero del coordinador'));
      expect(mark.right, lessThanOrEqualTo(title.left));
      expect(mark.height, lessThanOrEqualTo(40));
    });
  });

  group('en pantallas estrechas', () {
    for (final w in [320.0, 360.0, 420.0]) {
      testWidgets('a $w px de ancho la barra no se desborda: el título se recorta con puntos suspensivos y la marca se ve entera', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(w, 800);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: FakeApi(), every: null, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'sin «RenderFlex overflowed»');
        final mark = tester.getRect(find.byKey(const Key('brand_mark')));
        expect(mark.width, 30);
        expect(mark.left, greaterThanOrEqualTo(0));
        final title = tester.widget<Text>(find.text('SARD · Tablero del coordinador'));
        expect(title.overflow, TextOverflow.ellipsis);
      });
    }
  });

  group('instalación como app web (PWA)', () {
    final manifest = jsonDecode(File('web/manifest.json').readAsStringSync()) as Map<String, dynamic>;
    test('el manifiesto usa los colores de SARD, no el azul por omisión de Flutter', () {
      expect((manifest['background_color'] as String).toLowerCase(), '#12161c');
      expect((manifest['theme_color'] as String).toLowerCase(), '#12161c');
    });
    test('el nombre que ve quien lo instala es «SARD Tablero», no «sard_dashboard»', () {
      expect(manifest['name'], 'SARD · Tablero del coordinador');
      expect(manifest['short_name'], 'SARD Tablero');
    });
    test('los cuatro íconos declarados existen', () {
      for (final i in manifest['icons'] as List) {
        expect(File('web/${(i as Map)['src']}').existsSync(), isTrue, reason: '${i['src']}');
      }
    });
  });
}
