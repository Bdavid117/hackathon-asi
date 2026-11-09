#!/usr/bin/env python3
"""Genera TODOS los íconos de SARD a partir de la geometría única de la marca.

    python3 -I tool/brand/build_icons.py            # reescribe los íconos de Android, iOS y del tablero web

La marca (la «ruta SOS»: una S hecha de dos arcos con un hueco, un nodo en cada punta, dentro del botón rojo)
se dibuja una sola vez aquí, en una cuadrícula de 108 × 108 (la del ícono adaptativo de Android), y se
rasteriza con Chrome sin cabeza. Sólo biblioteca estándar + Chrome (variable CHROME si no está en la ruta usual).

Salidas:
  · Android: mipmap-*/ic_launcher.png (para < API 26), vectores del ícono adaptativo y del monocromo.
  · iOS: todos los tamaños de AppIcon.appiconset, SIN canal alfa (App Store lo rechaza).
  · Tablero web: favicon.png, Icon-192/512 y las versiones «maskable».
  · assets/brand/*.svg: las fuentes vectoriales (no se empaquetan: son el original).
"""
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
MOBILE = ROOT / 'apps/mobile'
DASH = ROOT / 'apps/dashboard'

BG = '#12161C'
RED = '#D23B2E'
RING = '#E5857C'
FG = '#EEF1F5'

# La S: dos arcos con un hueco en el centro (la conexión que se cae) y un nodo en cada punta exterior.
S_PATH = 'M66 40C60 32 42 33 42 43C42 48 46 50 50 51.4M58 56.6C62 58 66 60 66 65C66 75 48 76 42 68'
NODES = [(66, 40), (42, 68)]


def mark_group(detailed=True):
    """La marca sobre la cuadrícula 108 × 108, centrada en (54, 54). `detailed`: nodos con anillo (≥ 48 px);
    si no, nodos llenos y trazo algo más grueso (≤ 40 px)."""
    sw = 7 if detailed else 8
    g = [
        f'<circle cx="54" cy="54" r="31" fill="{RED}" stroke="{RING}" stroke-width="4"/>',
        f'<path d="{S_PATH}" fill="none" stroke="{FG}" stroke-width="{sw}" stroke-linecap="round"/>',
    ]
    for x, y in NODES:
        if detailed:
            g.append(f'<circle cx="{x}" cy="{y}" r="5.4" fill="{BG}"/><circle cx="{x}" cy="{y}" r="3" fill="{FG}"/>')
        else:
            g.append(f'<circle cx="{x}" cy="{y}" r="5.6" fill="{FG}"/>')
    return ''.join(g)


def svg(inner, w=108, h=108):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 108 108">{inner}</svg>'


def square_icon(scale=1.0, detailed=True, radius=0):
    """Cuadrado completo con fondo; la marca ampliada `scale` alrededor del centro."""
    bg = f'<rect width="108" height="108" fill="{BG}"' + (f' rx="{radius}"' if radius else '') + '/>'
    g = mark_group(detailed)
    if scale != 1.0:
        g = f'<g transform="translate(54 54) scale({scale}) translate(-54 -54)">{g}</g>'
    return svg(bg + g)


def chrome():
    for c in [os.environ.get('CHROME', ''), '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', 'google-chrome', 'chromium']:
        if c and (shutil.which(c) or os.path.exists(c)):
            return c
    sys.exit('No encuentro Chrome: defina CHROME=ruta')


def raster(svg_text, px, out, transparent=False, opaque=False):
    """Dibuja `svg_text` a px × px con Chrome sin cabeza y guarda el PNG en `out`."""
    with tempfile.TemporaryDirectory() as d:
        html = pathlib.Path(d) / 'i.html'
        html.write_text(f'<!doctype html><meta charset="utf-8"><style>html,body{{margin:0;background:{"transparent" if transparent else BG}}}svg{{display:block;width:{px}px;height:{px}px}}</style>{svg_text}')
        shot = pathlib.Path(d) / 's.png'
        cmd = [chrome(), '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1', f'--window-size={px},{px}', f'--screenshot={shot}']
        if transparent:
            cmd.append('--default-background-color=00000000')
        subprocess.run(cmd + [html.as_uri()], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        data = shot.read_bytes()
    if opaque:
        data = strip_alpha(data)
    out = pathlib.Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
    w, h = png_size(data)
    assert (w, h) == (px, px), f'{out}: salió de {w}×{h}, se pedía {px}×{px}'


def png_size(data):
    return struct.unpack('>II', data[16:24])


def chunk(t, d):
    c = struct.pack('>I', len(d)) + t + d
    return c + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)


def strip_alpha(data):
    """PNG RGBA → RGB (App Store rechaza íconos con canal alfa). Sólo biblioteca estándar."""
    pos, idat, w, h, ct = 8, b'', 0, 0, 0
    while pos < len(data):
        n, t = struct.unpack('>I4s', data[pos:pos + 8])
        c = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if t == b'IHDR':
            w, h = struct.unpack('>II', c[:8])
            ct = c[9]
        elif t == b'IDAT':
            idat += c
    if ct == 2:
        return data
    assert ct == 6, f'tipo de color no soportado: {ct}'
    raw, bpp, stride, p, prev, rows = zlib.decompress(idat), 4, w * 4, 0, bytearray(w * 4), []
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
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        rows.append(line)
        prev = line
    body = b''.join(b'\x00' + bytes(r[i] for i in range(stride) if i % 4 != 3) for r in rows)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(body, 9)) + chunk(b'IEND', b'')


def circle_path(cx, cy, r):
    return f'M{cx},{cy}m-{r},0a{r},{r} 0 1,0 {2 * r},0a{r},{r} 0 1,0 -{2 * r},0'


def android_vectors():
    res = MOBILE / 'android/app/src/main/res'
    s_android = S_PATH.replace('M', 'M').replace(' ', ',', 0)
    fg = f'''<?xml version="1.0" encoding="utf-8"?>
<!-- Capa de marca del ícono adaptativo (se dibuja con make_icons: tool/brand/build_icons.py). Todo dentro del
     círculo de 66 dp que el sistema garantiza: el anillo termina en el radio 33. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path android:fillColor="{RED}" android:pathData="{circle_path(54, 54, 31)}"/>
    <path android:strokeColor="{RING}" android:strokeWidth="4" android:pathData="{circle_path(54, 54, 31)}"/>
    <path android:strokeColor="{FG}" android:strokeWidth="7" android:strokeLineCap="round" android:pathData="{S_PATH}"/>
''' + ''.join(f'''    <path android:fillColor="{BG}" android:pathData="{circle_path(x, y, 5.4)}"/>
    <path android:fillColor="{FG}" android:pathData="{circle_path(x, y, 3)}"/>
''' for x, y in NODES) + '</vector>\n'
    mono = f'''<?xml version="1.0" encoding="utf-8"?>
<!-- Ícono temático (Android 13+): una sola tinta, el sistema la colorea. Anillo, S y nodos; sin relleno de disco. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path android:strokeColor="#FF000000" android:strokeWidth="3.5" android:pathData="{circle_path(54, 54, 31)}"/>
    <path android:strokeColor="#FF000000" android:strokeWidth="7" android:strokeLineCap="round" android:pathData="{S_PATH}"/>
''' + ''.join(f'    <path android:fillColor="#FF000000" android:pathData="{circle_path(x, y, 5.6)}"/>\n' for x, y in NODES) + '</vector>\n'
    adaptive = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>
</adaptive-icon>
'''
    colors = f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">{BG}</color>
</resources>
'''
    for rel, text in [('drawable/ic_launcher_foreground.xml', fg), ('drawable/ic_launcher_monochrome.xml', mono), ('mipmap-anydpi-v26/ic_launcher.xml', adaptive), ('values/ic_launcher_colors.xml', colors)]:
        p = res / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding='utf-8')
    # Antes de Android 8: PNG cuadrado redondeado (sin capas)
    for d, px in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
        raster(square_icon(scale=1.05, detailed=px >= 96, radius=22), px, res / f'mipmap-{d}/ic_launcher.png', transparent=True)


def ios_icons():
    d = MOBILE / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    contents = json.loads((d / 'Contents.json').read_text(encoding='utf-8'))
    done = set()
    for img in contents['images']:
        size = float(img['size'].split('x')[0])
        scale = int(img['scale'].rstrip('x'))
        px = int(round(size * scale))
        if (img['filename'], px) in done:
            continue
        done.add((img['filename'], px))
        # cuadrado completo, marca 30 % mayor (iOS sólo redondea las esquinas); nodos llenos a ≤ 80 px
        raster(square_icon(scale=1.3, detailed=px > 80), px, d / img['filename'], opaque=True)


def web_icons():
    w = DASH / 'web'
    raster(square_icon(scale=1.15, detailed=False), 48, w / 'favicon.png')
    for px in (192, 512):
        raster(square_icon(scale=1.15), px, w / f'icons/Icon-{px}.png')
        # maskable: contenido dentro del 80 % central; la marca ya ocupa ≈ 61 % del ancho
        raster(square_icon(scale=1.0), px, w / f'icons/Icon-maskable-{px}.png')


def sources():
    a = MOBILE / 'assets/brand'
    a.mkdir(parents=True, exist_ok=True)
    (a / 'sard_mark.svg').write_text(svg(mark_group(True)) + '\n', encoding='utf-8')
    (a / 'sard_mark_small.svg').write_text(svg(mark_group(False)) + '\n', encoding='utf-8')
    (a / 'sard_icon.svg').write_text(square_icon(scale=1.3) + '\n', encoding='utf-8')


if __name__ == '__main__':
    sources()
    android_vectors()
    ios_icons()
    web_icons()
    print('Íconos de SARD generados (Android, iOS, tablero web) y fuentes en apps/mobile/assets/brand/')
