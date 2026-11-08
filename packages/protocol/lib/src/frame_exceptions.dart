/// Error al decodificar una trama. Los subtipos permiten reaccionar de forma distinta
/// (p. ej. un nodo no acusa una trama con etiqueta inválida).
class FrameException implements Exception {
  const FrameException(this.message);
  final String message;
  @override
  String toString() => '$runtimeType: $message';
}

/// La trama es más corta de lo que su cabecera anuncia.
class TruncatedFrame extends FrameException {
  const TruncatedFrame(super.message);
}

/// La etiqueta de integridad no coincide.
class BadTag extends FrameException {
  const BadTag(super.message);
}

/// La versión del protocolo no es la 0.
class UnsupportedVersion extends FrameException {
  const UnsupportedVersion(super.message);
}

/// La trama usa una función no implementada en v0 (p. ej. fragmentación).
class UnsupportedFeature extends FrameException {
  const UnsupportedFeature(super.message);
}

/// El tipo de mensaje no es el esperado por el decodificador.
class WrongType extends FrameException {
  const WrongType(super.message);
}
