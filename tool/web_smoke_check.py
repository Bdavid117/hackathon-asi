#!/usr/bin/env python3
"""Comprueba la captura del tablero compilado: los segmentos de la barra de triaje (P1 rojo, P2 ámbar,
P3 azul) tienen que estar pintados y con anchos que sigan los contadores del escenario (1, 1, 6).
Sólo biblioteca estándar. Uso: web_smoke_check.py captura.png"""
import struct
import sys
import zlib


def read_png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'no es un PNG'
    pos, idat, w, h, bd, ct = 8, b'', 0, 0, 0, 0
    while pos < len(d):
        n, t = struct.unpack('>I4s', d[pos:pos + 8])
        c = d[pos + 8:pos + 8 + n]
        pos += 12 + n
        if t == b'IHDR':
            w, h = struct.unpack('>II', c[:8])
            bd, ct = c[8], c[9]
        elif t == b'IDAT':
            idat += c
    assert bd == 8 and ct in (2, 6), f'formato no soportado (bits={bd}, tipo={ct})'
    raw = zlib.decompress(idat)
    bpp = {2: 3, 6: 4}[ct]
    stride = w * bpp
    img, prev, p = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        img.append(line)
        prev = line
    return w, h, bpp, img


def count(img, w, bpp, rgb, tol=6):
    n = 0
    for row in img:
        for x in range(w):
            if all(abs(row[x * bpp + k] - rgb[k]) <= tol for k in range(3)):
                n += 1
    return n


w, h, bpp, img = read_png(sys.argv[1])
red = count(img, w, bpp, (0xD2, 0x3B, 0x2E))
amber = count(img, w, bpp, (0xF2, 0xB5, 0x44))
blue = count(img, w, bpp, (0x4F, 0xA3, 0xD1))
print(f'{w}x{h}  P1 rojo={red}  P2 ámbar={amber}  P3 azul={blue}')
problems = []
if red < 3000:
    problems.append('no se pintó el segmento P1')
if amber < 3000:
    problems.append('no se pintó el segmento P2')
if blue < 2 * red:
    problems.append('el segmento P3 (6 incidentes) debería ser bastante más ancho que el P1 (1 incidente)')
if problems:
    print('FALLÓ: ' + '; '.join(problems))
    sys.exit(1)
print('OK: el tablero compilado pintó los contadores del nodo en vivo')
