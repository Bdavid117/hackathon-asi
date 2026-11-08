/// Un reloj que sólo avanza cuando se le ordena: permite simular horas de reintentos y
/// ventanas en milisegundos, y que el resultado dependa sólo de la semilla.
class VirtualClock {
  VirtualClock(DateTime start) : _now = start;

  DateTime _now;

  DateTime now() => _now;

  void advance(Duration d) {
    if (d.isNegative) throw ArgumentError.value(d, 'd', 'el tiempo no retrocede');
    _now = _now.add(d);
  }
}
