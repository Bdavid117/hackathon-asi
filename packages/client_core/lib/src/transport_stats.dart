/// Contadores del transporte, para medir el costo real de confirmar un reporte (T02).
class TransportStats {
  /// Tramas enviadas, contando cada reintento.
  int framesSent = 0;

  /// Bytes enviados (cabeceras y etiqueta incluidas), reintentos incluidos.
  int bytesOut = 0;

  /// Bytes recibidos como respuesta, sean o no válidos.
  int bytesIn = 0;

  /// Tramas acusadas.
  int acked = 0;

  /// Intentos sin respuesta válida que cubra la trama.
  int failed = 0;

  /// Bytes totales (ida + vuelta) por trama acusada; `null` si aún no hay ninguna.
  double? get bytesPerAcked => acked == 0 ? null : (bytesOut + bytesIn) / acked;
}
