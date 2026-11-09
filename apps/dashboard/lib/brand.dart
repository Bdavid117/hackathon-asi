import 'package:flutter/material.dart';

import 'theme.dart';

/// La marca de SARD, la «ruta SOS»: una S hecha de **dos arcos con un hueco** (la conexión que se cae y
/// que el sistema tolera: el mensaje se guarda en un nodo y sigue en el siguiente), con un nodo en cada
/// punta exterior, dentro del botón rojo del SOS.
///
/// COPIA de `apps/mobile/lib/brand.dart` (la app y el tablero son paquetes distintos); misma cuadrícula de
/// 108 × 108 que `tool/brand/build_icons.py`. Si cambia la marca, cambia en los tres sitios; las pruebas de
/// píxeles de ambos lados fallan si se separan. Hasta 40 px
/// se usa la versión de **nodos llenos** (con anillo se empastarían); desde 48 px, la completa.
class SardMark extends StatelessWidget {
  const SardMark({super.key, this.size = 28, this.detailed});

  final double size;

  /// `null` = según el tamaño: completa desde 48 px, de nodos llenos por debajo.
  final bool? detailed;

  bool get useDetailed => detailed ?? size >= 48;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'SARD',
    image: true,
    child: ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _MarkPainter(useDetailed)),
      ),
    ),
  );
}

const Color _kRing = Color(0xFFE5857C);

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.detailed);
  final bool detailed;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 108;
    canvas.save();
    canvas.scale(k);
    const center = Offset(54, 54);
    canvas.drawCircle(center, 31, Paint()..color = DashColors.sos);
    canvas.drawCircle(center, 31, Paint()..color = _kRing..style = PaintingStyle.stroke..strokeWidth = 4);
    final s = Path()
      ..moveTo(66, 40)
      ..cubicTo(60, 32, 42, 33, 42, 43)
      ..cubicTo(42, 48, 46, 50, 50, 51.4)
      ..moveTo(58, 56.6)
      ..cubicTo(62, 58, 66, 60, 66, 65)
      ..cubicTo(66, 75, 48, 76, 42, 68);
    canvas.drawPath(
      s,
      Paint()
        ..color = DashColors.text
        ..style = PaintingStyle.stroke
        ..strokeWidth = detailed ? 7 : 8
        ..strokeCap = StrokeCap.round,
    );
    for (final n in const [Offset(66, 40), Offset(42, 68)]) {
      if (detailed) {
        canvas.drawCircle(n, 5.4, Paint()..color = DashColors.bg);
        canvas.drawCircle(n, 3, Paint()..color = DashColors.text);
      } else {
        canvas.drawCircle(n, 5.6, Paint()..color = DashColors.text);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.detailed != detailed;
}
