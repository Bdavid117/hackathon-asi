#!/usr/bin/env python3
"""Medición de referencia del tamaño de la trama SARD-WIRE v0 (ver docs, sección 7).

No es código de la app: es una calculadora que empaqueta un reporte de ejemplo con el
diseño de trama propuesto y lo compara con un JSON equivalente. Sirve para que las cifras
del documento de arquitectura salgan de una medición y no de una estimación.

Uso:  python3 frame_size.py            (imprime una tabla)
      python3 frame_size.py --json     (salida máquina-legible)
"""
import hashlib
import hmac
import json
import pathlib
import struct
import sys

# --- Diseño de trama (debe coincidir con docs/src/parts/07-protocolo.html) -------------
VERSION = 0
TYPE_REPORT = 1


class BitWriter:
    def __init__(self):
        self.value = 0
        self.nbits = 0

    def put(self, value, bits):
        assert 0 <= value < (1 << bits), (value, bits)
        self.value = (self.value << bits) | value
        self.nbits += bits

    def to_bytes(self):
        pad = (-self.nbits) % 8
        return (self.value << pad).to_bytes((self.nbits + pad) // 8, "big")


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def quantize_lat(lat):  # 24 bits sobre [-90, 90]  (~1,2 m)
    return round((lat + 90.0) / 180.0 * ((1 << 24) - 1))


def quantize_lon(lon):  # 25 bits sobre [-180, 180] (~1,2 m en el ecuador)
    return round((lon + 180.0) / 360.0 * ((1 << 25) - 1))


def encode_report(r, key=b"clave-de-ejemplo"):
    # Payload bit a bit
    w = BitWriter()
    w.put(r["incident_type"], 4)
    w.put(r["flags"], 8)
    w.put(r["people_bucket"], 3)
    w.put(r["loc_quality"], 3)
    if 1 <= r["loc_quality"] <= 5:
        w.put(quantize_lat(r["lat"]), 24)
        w.put(quantize_lon(r["lon"]), 25)
    w.put(r["captured_at"], 32)
    w.put(r["battery_q"], 4)
    text = r.get("text", "").encode("utf-8")
    w.put(1 if text else 0, 1)
    payload = w.to_bytes()
    if text:
        payload += varint(len(text)) + text

    # flags: bit7 FRAG, bit6 ACKREQ, bit5 FIRMADA, bits4-3 PRIO, bit2 REV (lleva ref_seq)
    flags = 0b01100000  # ACKREQ + FIRMADA
    flags |= (r["prio_hint"] & 0b11) << 3
    if r["rev"] > 0:
        flags |= 0b00000100  # REV
    header = bytes([(VERSION << 4) | TYPE_REPORT, flags])
    # seq = contador de TRAMAS del dispositivo: cada trama (reporte nuevo o revisión) consume uno;
    # así el ACK selectivo distingue cada revisión.
    header += r["device_id"].to_bytes(8, "big") + r["seq"].to_bytes(4, "big")
    header += bytes([r["rev"]])
    if r["rev"] > 0:  # referencia al reporte original: seq de su trama rev 0
        header += r["ref_seq"].to_bytes(4, "big")
    header += varint(len(payload))
    tag = hmac.new(key, header + payload, hashlib.sha256).digest()[:4]
    return header + payload + tag


def json_equivalent(r, short=False):
    """Línea base JSON. short=False: claves descriptivas y hora ISO 8601 (lo habitual en una API).
    short=True: claves de una letra, hora en epoch y banderas como entero (un JSON ya optimizado)."""
    ref = r.get("ref_seq", r["seq"])
    if short:
        obj = {"d": f'{r["device_id"]:016x}', "s": r["seq"], "v": r["rev"], "k": r["incident_type"],
               "f": r["flags"], "p": r["people_bucket"], "l": [r["lat"], r["lon"], 20],
               "t": r["captured_at"], "b": 17}
        if r["rev"] > 0:
            obj["r"] = ref
        if r.get("text"):
            obj["x"] = r["text"]
    else:
        obj = {
            "reportId": f'{r["device_id"]:016x}-{ref}',
            "frameSeq": r["seq"],
            "rev": r["rev"],
            "type": "atrapado",
            "flags": ["atrapado", "herido"],
            "people": "2-3",
            "location": {"lat": r["lat"], "lon": r["lon"], "accuracyM": 20, "source": "gps"},
            "capturedAt": "2026-08-10T14:07:31Z",
            "battery": 17,
        }
        if r.get("text"):
            obj["text"] = r["text"]
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


SOS = dict(incident_type=3, flags=0b11000000, people_bucket=2, loc_quality=2,
           lat=5.0703, lon=-75.5138, captured_at=1786370851, battery_q=1,
           device_id=0x9A3C51E07B2D44F1, seq=17, rev=0, prio_hint=0)
TEXT = "Edificio colapsado en la esquina, hay una persona atrapada bajo la losa y otra herida"
REV_SIN_TEXTO = dict(SOS, rev=1, seq=18, ref_seq=17)
REV_CON_TEXTO = dict(SOS, rev=1, seq=18, ref_seq=17, text=TEXT)
ACK_BYTES = 1 + 1 + 8 + 4 + 4 + 4  # ver|tipo, flags, device_id, ack_seq, bitmap, etiqueta


def encode_ack(device_id: bytes, ack_seq: int, bitmap: int, key: bytes = b"clave-de-ejemplo") -> bytes:
    """ACK selectivo con ventana hacia atrás: 22 B. El bit i del bitmap = el nodo guarda la trama ack_seq-1-i."""
    body = bytes([(VERSION << 4) | 2, 0]) + device_id + ack_seq.to_bytes(4, "big") + bitmap.to_bytes(4, "big")
    return body + hmac.new(key, body, hashlib.sha256).digest()[:4]


def _report_input(r):
    """Entrada serializable de un reporte (la misma que consume el decodificador de Dart)."""
    return {
        "device_id": r["device_id"].to_bytes(8, "big").hex(), "seq": r["seq"], "rev": r["rev"],
        "ref_seq": r.get("ref_seq") if r["rev"] > 0 else None, "prio_hint": r["prio_hint"],
        "incident_type": r["incident_type"], "flags": r["flags"], "people_bucket": r["people_bucket"],
        "loc_quality": r["loc_quality"], "lat": r.get("lat") if 1 <= r["loc_quality"] <= 5 else None,
        "lon": r.get("lon") if 1 <= r["loc_quality"] <= 5 else None,
        "captured_at": r["captured_at"], "battery_q": r["battery_q"], "text": r.get("text"),
    }


def export_vectors(out_dir):
    """Escribe vectors.json y vectors.g.dart (los tests de Chrome no pueden leer archivos con dart:io)."""
    key = b"clave-de-ejemplo"
    cases = {
        "sos_min": SOS,
        "rev_no_text": REV_SIN_TEXTO,
        "rev_with_text": REV_CON_TEXTO,
        "no_location": dict(SOS, seq=20, loc_quality=0, lat=None, lon=None),
        "high_bit_device": dict(SOS, device_id=0xFFFFFFFFFFFFFFFF, seq=0xFFFFFFFF, captured_at=0xFFFFFFFF),
        "text_accents_140": dict(SOS, seq=21, text="\u00e1" * 70),
    }
    vectors = []
    for name, r in cases.items():
        vectors.append({"name": name, "kind": "report", "key": key.decode(), "input": _report_input(r),
                        "hex": encode_report(r, key).hex()})
    dev = SOS["device_id"].to_bytes(8, "big")
    vectors.append({"name": "ack_basic", "kind": "ack", "key": key.decode(),
                    "input": {"device_id": dev.hex(), "ack_seq": 17, "bitmap": 5},
                    "hex": encode_ack(dev, 17, 5, key).hex()})
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    text = json.dumps(vectors, ensure_ascii=False, indent=2)
    (out / "vectors.json").write_text(text + "\n", encoding="utf-8")
    (out / "vectors.g.dart").write_text(
        "// GENERADO por docs/src/tools/frame_size.py --export-vectors. No editar a mano.\n"
        "const kVectorsJson = r'''" + text + "''';\n", encoding="utf-8")
    print(f"{len(vectors)} vectores escritos en {out}")


def main():
    if "--export-vectors" in sys.argv:
        export_vectors(sys.argv[sys.argv.index("--export-vectors") + 1])
        return
    casos = (("SOS mínimo (rev 0)", SOS), ("Revisión sin texto (rev 1)", REV_SIN_TEXTO),
             ("Revisión con texto de %d car." % len(TEXT), REV_CON_TEXTO))
    rows = []
    for nombre, r in casos:
        b = encode_report(r)
        rows.append((nombre, len(b), len(json_equivalent(r)), len(json_equivalent(r, short=True))))
    if "--json" in sys.argv:
        print(json.dumps([dict(caso=n, binario=b, json_descriptivo=jl, json_corto=jc) for n, b, jl, jc in rows] + [dict(caso="ACK", binario=ACK_BYTES)], ensure_ascii=False))
        return
    print(f"{'Caso':36} {'Binario':>8} {'JSON desc.':>11} {'x':>5} {'JSON corto':>11} {'x':>5}")
    for n, b, jl, jc in rows:
        print(f"{n:36} {b:>7}B {jl:>10}B {jl / b:>4.1f}x {jc:>10}B {jc / b:>4.1f}x")
    print(f"{'ACK selectivo con ventana':36} {ACK_BYTES:>7}B")
    print("\nSOS mínimo: cabecera 16 B + carga 13 B + etiqueta 4 B; las revisiones añaden ref_seq (4 B)")
    print("Vector de ejemplo (clave de prueba 'clave-de-ejemplo'):", encode_report(SOS).hex())
    assert len(encode_report(SOS)) == 33, len(encode_report(SOS))
    assert ACK_BYTES == 22


if __name__ == "__main__":
    main()
