/// Potencias de dos hasta 2^32, calculadas por multiplicación: en Dart compilado a Web
/// `1 << 32` se trunca a 32 bits.
final List<int> kPow2 = () {
  final t = <int>[1];
  for (var i = 1; i <= 32; i++) {
    t.add(t.last * 2);
  }
  return List<int>.unmodifiable(t);
}();
