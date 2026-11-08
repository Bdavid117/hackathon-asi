import 'dart:typed_data';

/// Un canal por el que el cliente envía tramas a un nodo.
///
/// [send] devuelve los bytes de la respuesta (un ACK) o `null` si no hubo respuesta
/// (trama perdida, respuesta perdida, plazo vencido o nodo caído).
abstract interface class Channel {
  Future<Uint8List?> send(Uint8List frame);
}
