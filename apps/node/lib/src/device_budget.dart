/// Presupuesto de trabajo caro **por dispositivo**: una cubeta de fichas.
///
/// **Degrada, no rechaza.** La clave de la etiqueta de integridad es compartida y pública: cualquiera
/// puede fabricar tramas con el identificador de OTRO dispositivo, así que un rechazo por dispositivo
/// sería una forma de bloquear el SOS de una víctima (y `HttpChannel` trata cualquier respuesta distinta
/// de 200 como fallo y reintenta con espera creciente). Por eso una trama de un dispositivo pasado de
/// presupuesto **se guarda y se acusa igual**; sólo se le quita lo caro (la consulta al modelo).
///
/// Sólo se gasta una ficha por trama **nueva ya guardada**: los reintentos de lo ya guardado no cuentan.
/// Los valores por omisión (300 de capacidad, 5 por segundo) están muy por encima de un teléfono con
/// atraso (la ventana de 8 tramas cada 3 s da 160 por minuto) y muy por debajo de un abuso.
class DeviceBudget {
  DeviceBudget({this.capacity = 300, this.refillPerSecond = 5, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final int capacity;
  final double refillPerSecond;
  final DateTime Function() _clock;

  final Map<String, _Bucket> _buckets = {};
  int _taken = 0;
  int _degraded = 0;

  /// Gasta una ficha de [deviceId]. `false` = se pasó del presupuesto (hay que omitir lo caro).
  bool take(String deviceId) {
    final now = _clock();
    final b = _buckets.putIfAbsent(deviceId, () => _Bucket(capacity.toDouble(), now));
    final elapsed = now.difference(b.at).inMilliseconds;
    if (elapsed > 0) {
      // un reloj que retrocede no regala ni quita fichas
      b.tokens = (b.tokens + elapsed / 1000 * refillPerSecond).clamp(0, capacity.toDouble());
      b.at = now;
    } else if (elapsed < 0) {
      b.at = now;
    }
    _taken++;
    if (b.tokens >= 1) {
      b.tokens -= 1;
      return true;
    }
    _degraded++;
    return false;
  }

  /// Cuántas tramas nuevas se contaron (para comprobar que los reintentos no gastan).
  int get takenTotal => _taken;

  /// Cuántas tramas se degradaron (se pasaron del presupuesto).
  int get degraded => _degraded;

  /// Cuántos dispositivos están ahora mismo sin fichas.
  int get devicesOverBudget => _buckets.values.where((b) => b.tokens < 1).length;

  Map<String, Object?> toJson() => {'degraded': degraded, 'devicesOverBudget': devicesOverBudget};
}

class _Bucket {
  _Bucket(this.tokens, this.at);
  double tokens;
  DateTime at;
}
