#!/usr/bin/env python3
"""Video de presentación de SARD (≤ 60 s): narración, música con pulso y efectos sintetizados, texto cinético y tomas REALES de la app y del tablero.

No necesita ffmpeg: usa `say`/`afconvert` de macOS, Pillow y el codificador de AVFoundation (`encode.swift`).

    python3 -I docs/pitch/video/build_video.py prepare              # compila el codificador, sintetiza la voz y extrae los fotogramas de la app
    python3 -I docs/pitch/video/build_video.py still 12.5           # un fotograma suelto (para revisar el diseño) → work/still.png
    python3 -I docs/pitch/video/build_video.py render               # video + subtítulos + póster → work/salida/

Entradas (no versionadas): `phone.mov` en `SARD_VIDEO_WORK` (grabación del simulador con `xcrun simctl io … recordVideo` mientras corre
`apps/mobile/integration_test/marketing_flow.dart`). Las capturas del tablero están en `assets/`. **Voz propia:** si `SARD_VOICE_DIR` apunta a una carpeta
con `l1`…`l6` (`.wav`, `.aiff`, `.m4a`…), se usa esa grabación en lugar de la voz del sistema; el resto (tiempos, música, rótulos) se ajusta solo.
Salida: `*.mp4` NO se versiona ni se sube a ningún servicio sin decidirlo; `guion.srt` (los subtítulos) sí.
"""
import array, math, os, pathlib, random, shutil, subprocess, sys, wave
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent
WORK = pathlib.Path(os.environ.get('SARD_VIDEO_WORK', ROOT / 'work'))
ASSETS = ROOT / 'assets'
W, H, FPS = 1920, 1080, 30
BG = (18, 22, 28)
RED, GREEN, BLUE, AMBER, VIOLET = (210, 59, 46), (76, 195, 138), (79, 163, 209), (242, 181, 68), (167, 139, 250)
TEXT, MUTED, SURF, LINE = (238, 241, 245), (169, 180, 194), (27, 34, 43), (44, 54, 68)
FONT_FILE = '/System/Library/Fonts/Avenir Next.ttc'
STYLE = {'Bold': 0, 'Demi': 2, 'Medium': 5, 'Regular': 7, 'Heavy': 8}
VOICE, RATE = 'Paulina', '175'
SR = 44100
BPM = 100
BEAT = 60 / BPM

# ───────────────────────────── guion ─────────────────────────────
LINES = {
    'l1': 'Un sismo. Un apagón. Y alguien que necesita que su pedido de ayuda llegue.',
    'l2': 'SARD convierte un toque en un reporte que sobrevive. Se guarda sin red, pesa apenas treinta y tres bytes, y sale solo cuando vuelve la señal.',
    'l3': 'Cada reporte llega a una red de nodos sin jefe. Si uno cae, otro sigue; y al reunirse, vuelven a coincidir.',
    'l4': 'El tablero ordena lo urgente, explica por qué, y propone la acción. Nada se ejecuta sin la aprobación de una persona.',
    'l5': 'Y cuando una zona deja de reportar, el mapa lo marca. Porque el silencio no es seguridad.',
    'l6': 'SARD. Reportes que sobreviven. Decisiones que se pueden explicar.',
}
SUBS = {
    'l1': [('Un sismo. Un apagón.', 0.0), ('Y alguien que necesita que su pedido de ayuda llegue.', 0.36)],
    'l2': [('SARD convierte un toque en un reporte que sobrevive.', 0.0), ('Se guarda sin red, pesa apenas 33 bytes,', 0.34), ('y sale solo cuando vuelve la señal.', 0.72)],
    'l3': [('Cada reporte llega a una red de nodos sin jefe.', 0.0), ('Si uno cae, otro sigue;', 0.40), ('y al reunirse, vuelven a coincidir.', 0.66)],
    'l4': [('El tablero ordena lo urgente, explica por qué,', 0.0), ('y propone la acción.', 0.36), ('Nada se ejecuta sin la aprobación de una persona.', 0.55)],
    'l5': [('Y cuando una zona deja de reportar, el mapa lo marca.', 0.0), ('Porque el silencio no es seguridad.', 0.62)],
    'l6': [('SARD. Reportes que sobreviven.', 0.0), ('Decisiones que se pueden explicar.', 0.56)],
}
SCENES = [('hook', 6.6, 'l1'), ('phone', 11.4, 'l2'), ('red', 9.6, 'l3'), ('tablero', 10.2, 'l4'), ('silencio', 7.8, 'l5'), ('cierre', 7.2, 'l6')]
LEAD, TAIL, XFADE = 0.6, 0.9, 0.6  # las escenas duran un número entero de tiempos (0,6 s a 100 ppm) y se solapan un tiempo: cada corte cae en el pulso
PHONE_START, PHONE_LEN = 5.6, 11.0
SOS_BTN = (0.499, 0.229)

_fonts = {}
def font(size, style='Bold'):
    k = (size, style)
    if k not in _fonts:
        _fonts[k] = ImageFont.truetype(FONT_FILE, size, index=STYLE[style])
    return _fonts[k]


def clamp(x, a=0.0, b=1.0): return max(a, min(b, x))
def ease(x): x = clamp(x); return x * x * (3 - 2 * x)
def ease_out(x): x = clamp(x); return 1 - (1 - x) ** 3
def ease_in(x): x = clamp(x); return x * x * x
def back_out(x):
    x = clamp(x); c1 = 1.70158; c3 = c1 + 1
    return 1 + c3 * (x - 1) ** 3 + c1 * (x - 1) ** 2
def quint(x): x = clamp(x); return 16 * x ** 5 if x < 0.5 else 1 - (-2 * x + 2) ** 5 / 2
def lerp(a, b, t): return a + (b - a) * t
def seg(t, a, b): return clamp((t - a) / (b - a))


# ───────────────────────────── voz ─────────────────────────────
def synth_voice():
    (WORK / 'voz').mkdir(parents=True, exist_ok=True)
    custom = os.environ.get('SARD_VOICE_DIR')
    for k, text in LINES.items():
        wav = WORK / 'voz' / f'{k}.wav'
        if wav.exists(): continue
        src = None
        if custom:
            cands = sorted(pathlib.Path(custom).glob(f'{k}.*'))
            src = cands[0] if cands else None
        if src is None:
            src = WORK / 'voz' / f'{k}.aiff'
            subprocess.run(['say', '-v', VOICE, '-r', RATE, '-o', str(src), text], check=True)
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@44100', '-c', '1', str(src), str(wav)], check=True)


def wav_samples(path):
    with wave.open(str(path)) as w:
        assert w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2
        a = array.array('h'); a.frombytes(w.readframes(w.getnframes()))
    return a


def timeline():
    t, out = 0.0, []
    for name, minimum, line in SCENES:
        dur = len(wav_samples(WORK / 'voz' / f'{line}.wav')) / SR
        length = max(minimum, LEAD + dur + TAIL)
        length = math.ceil(length / BEAT - 1e-9) * BEAT
        out.append({'name': name, 'start': t, 'end': t + length, 'line': line, 'voice_start': t + LEAD, 'voice_len': dur})
        t += length - XFADE
    return out


# ───────────────────────────── sprites y utilidades ─────────────────────────────
def rounded(size, radius, fill, outline=None, width=0, ss=3):
    w, h = size
    im = Image.new('RGBA', (w * ss, h * ss), (0, 0, 0, 0))
    ImageDraw.Draw(im).rounded_rectangle((0, 0, w * ss - 1, h * ss - 1), radius * ss, fill=fill, outline=outline, width=width * ss)
    return im.resize((w, h), Image.LANCZOS)


def disc(d, fill, outline=None, width=0, ss=3):
    im = Image.new('RGBA', (d * ss, d * ss), (0, 0, 0, 0))
    ImageDraw.Draw(im).ellipse((0, 0, d * ss - 1, d * ss - 1), fill=fill, outline=outline, width=width * ss)
    return im.resize((d, d), Image.LANCZOS)


def ring(d, color, width, ss=3):
    im = Image.new('RGBA', (d * ss, d * ss), (0, 0, 0, 0))
    ImageDraw.Draw(im).ellipse((width * ss // 2, width * ss // 2, d * ss - 1 - width * ss // 2, d * ss - 1 - width * ss // 2), outline=color, width=width * ss)
    return im.resize((d, d), Image.LANCZOS)


def text_layer(text, size, style='Bold', color=TEXT, anchor_w=None, align='left', line_gap=1.12):
    f = font(size, style)
    lines = text.split('\n')
    widths = [int(f.getlength(l)) for l in lines]
    w = anchor_w or max(widths)
    lh = int(size * line_gap)
    im = Image.new('RGBA', (w + 8, lh * len(lines) + 12), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for i, l in enumerate(lines):
        x = 4 if align == 'left' else (w - widths[i]) // 2 + 4 if align == 'center' else w - widths[i] + 4
        d.text((x, 2 + i * lh), l, font=f, fill=color + (255,) if len(color) == 3 else color)
    return im


def with_alpha(im, a):
    if a >= 0.999: return im
    if a <= 0.0: return None
    out = im.copy()
    out.putalpha(ImageChops.multiply(im.getchannel('A'), Image.new('L', im.size, int(255 * a))))
    return out


def paste(base, layer, x, y, a=1.0):
    if layer is None: return
    l = with_alpha(layer, a)
    if l is None: return
    x, y = int(round(x)), int(round(y))
    if 0 <= x and 0 <= y and x + l.width <= base.width and y + l.height <= base.height:
        base.alpha_composite(l, (x, y))
        return
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(base.width, x + l.width), min(base.height, y + l.height)
    if x1 > x0 and y1 > y0:
        base.alpha_composite(l.crop((x0 - x, y0 - y, x1 - x, y1 - y)), (x0, y0))


def rise(t, start, dur=0.45, dy=26):
    p = ease_out(seg(t, start, start + dur))
    return p, (1 - p) * dy


_sprites = {}
def sprite(key, make):
    if key not in _sprites: _sprites[key] = make()
    return _sprites[key]


def glow(color, size, strength=0.55):
    im = Image.new('RGBA', (size, size), color + (0,))
    px = im.load()
    c = size / 2
    for y in range(size):
        for x in range(size):
            r = math.hypot(x - c, y - c) / c
            if r < 1: px[x, y] = color + (int(255 * strength * (1 - r) ** 2),)
    return im


def kinetic(f, text, x, y, size, style, color, t, start, stagger=0.09, dur=0.5, dy=46):
    """Texto cinético: cada palabra entra por su cuenta, subiendo y apareciendo."""
    fnt = font(size, style)
    cx = x
    for i, w in enumerate(text.split(' ')):
        p, d = rise(t, start + i * stagger, dur, dy)
        paste(f, sprite(('kw', w, size, style, color), lambda w=w: text_layer(w, size, style, color)), cx, y + d, p)
        cx += fnt.getlength(w + ' ')


def zoom_frame(img, z, cx=0.5, cy=0.5):
    """Movimiento de cámara: recorta un encuadre `z` veces más pequeño centrado en (cx, cy) y lo devuelve al tamaño completo."""
    if z <= 1.0001 and cx == 0.5 and cy == 0.5: return img
    w, h = img.size
    cw, ch = w / z, h / z
    x0, y0 = (w - cw) * cx, (h - ch) * cy
    return img.crop((int(x0), int(y0), int(x0 + cw), int(y0 + ch))).resize((w, h), Image.BILINEAR)


# ───────────────────────────── fondo vivo ─────────────────────────────
def _make_bg():
    im = Image.new('RGB', (W, H), BG)
    v = Image.new('L', (W, H), 0)
    ImageDraw.Draw(v).ellipse((-300, -300, W + 300, H + 300), fill=255)
    v = v.filter(ImageFilter.GaussianBlur(220))
    return Image.composite(im, Image.new('RGB', (W, H), (8, 10, 13)), v).convert('RGBA')


def _make_grid():
    g = Image.new('RGBA', (W + 120, H + 120), (0, 0, 0, 0))
    d = ImageDraw.Draw(g)
    for x in range(0, W + 120, 120): d.line((x, 0, x, H + 120), fill=(255, 255, 255, 9), width=1)
    for y in range(0, H + 120, 120): d.line((0, y, W + 120, y), fill=(255, 255, 255, 9), width=1)
    return g


PARTICLES = [(random.Random(11 + i).random(), random.Random(23 + i).random(), 2 + (i % 4), 0.12 + 0.25 * random.Random(37 + i).random(), 6 + 14 * random.Random(41 + i).random()) for i in range(64)]


def background(tg=0.0, accent=RED, energy=1.0):
    """Viñeta + cuadrícula que se desplaza + dos auroras de color que respiran + partículas que suben. `energy` escala el movimiento."""
    f = sprite('bg', _make_bg).copy()
    grid = sprite('grid', _make_grid)
    ox, oy = int(tg * 9) % 120, int(tg * 5) % 120
    f.alpha_composite(grid.crop((ox, oy, ox + W, oy + H)))
    a1 = sprite(('aur', accent), lambda: glow(accent, 1100, 0.22))
    a2 = sprite(('aur', BLUE), lambda: glow(BLUE, 900, 0.16))
    paste(f, a1, 1250 + 160 * math.sin(tg * 0.21) - 550, 300 + 120 * math.cos(tg * 0.17) - 550, 0.9)
    paste(f, a2, 350 + 140 * math.cos(tg * 0.15) - 450, 700 + 90 * math.sin(tg * 0.19) - 450, 0.9)
    for px, py, sz, al, speed in PARTICLES:
        x = (px * W + 25 * math.sin(tg * 0.3 + py * 9)) % W
        y = (py * H - tg * speed * energy) % H
        paste(f, sprite(('part', sz), lambda sz=sz: disc(sz * 2, (238, 241, 245, 255))), x, y, al * (0.6 + 0.4 * math.sin(tg * 1.7 + px * 20)))
    return f


def chip(text, color, size=40):
    def make():
        f = font(size, 'Demi')
        tw = int(f.getlength(text))
        im = rounded((tw + 56, size + 40), (size + 40) // 2, (27, 34, 43, 240), color + (255,), 3)
        ImageDraw.Draw(im).text((28, 16), text, font=f, fill=TEXT + (255,))
        return im
    return sprite(('chip', text, color, size), make)


def eyebrow(f, text, t, start=0.3, a=1.0):
    """Antetítulo editorial arriba a la derecha: «01 — EL REPORTE»."""
    lay = sprite(('eb', text), lambda: text_layer(text, 26, 'Demi', MUTED))
    p, dy = rise(t, start, 0.5, 14)
    paste(f, lay, W - 120 - lay.width, 66 + dy, p * a)


def centered(f, text, y, size, style, color, t, start, kin=True, stagger=0.09, dur=0.5, dy=46):
    """Titular centrado horizontalmente (cinético si `kin`)."""
    fnt = font(size, style)
    x = (W - fnt.getlength(text)) / 2
    if kin: kinetic(f, text, x, y, size, style, color, t, start, stagger, dur, dy)
    else:
        p, d = rise(t, start, dur, dy)
        paste(f, sprite(('ct', text, size, style, color), lambda: text_layer(text, size, style, color)), x, y + d, p)


def brand(f, a=1.0):
    """Marca pequeña arriba a la izquierda (en las escenas de producto)."""
    m = sprite('mark_s', lambda: Image.open(ASSETS / 'sard-mark.png').convert('RGBA').crop((190, 190, 834, 834)).resize((54, 54), Image.LANCZOS))
    paste(f, m, 120, 58, a)
    paste(f, sprite('brand_t', lambda: text_layer('SARD', 34, 'Heavy', TEXT)), 186, 62, a)


def make_x(size=96, width=14, ss=3):
    im = Image.new('RGBA', (size * ss, size * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    m = size * ss // 5
    d.line((m, m, size * ss - m, size * ss - m), fill=RED + (255,), width=width * ss)
    d.line((size * ss - m, m, m, size * ss - m), fill=RED + (255,), width=width * ss)
    return im.resize((size, size), Image.LANCZOS)


def cursor_sprite():
    def make(ss=4, sc=1.5):
        pts = [(0, 0), (0, 29), (7, 23), (12, 35), (17, 33), (12.5, 21.5), (21, 21)]
        pts = [(x * sc * ss + 4, y * sc * ss + 4) for x, y in pts]
        im = Image.new('RGBA', (int(34 * sc * ss) + 8, int(46 * sc * ss) + 8), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        d.polygon([(x + 3 * ss, y + 4 * ss) for x, y in pts], fill=(0, 0, 0, 90))
        d.polygon(pts, fill=(255, 255, 255, 255), outline=(20, 24, 30, 255))
        return im.resize((im.width // ss, im.height // ss), Image.LANCZOS)
    return sprite('cursor', make)


def pulse_ring(f, cx, cy, p, color=RED, max_d=220, width=5):
    if not 0 < p < 1: return
    d = int(30 + ease_out(p) * max_d)
    paste(f, ring(d, color, width), cx - d // 2, cy - d // 2, (1 - p) ** 1.4 * 0.9)


def counter(f, value, suffix, x, y, size, color, a=1.0):
    lay = text_layer(f'{value:,}'.replace(',', ' ') + suffix, size, 'Heavy', color)
    paste(f, lay, x, y, a)


# ───────────────────────────── escena 0 · gancho ─────────────────────────────
def seismo_wave(t, x):
    env = 0.0
    if 0.3 <= t < 1.25: env = math.exp(-(t - 0.3) * 0.9) * min(1.0, (t - 0.3) / 0.12)
    y = env * 110 * (math.sin(x * 0.045 + t * 31) * 0.6 + math.sin(x * 0.11 - t * 47) * 0.3 + math.sin(x * 0.021 + t * 13) * 0.4)
    if t >= 2.5:
        c = (t - 2.5) * 900
        y += -180 * math.exp(-((x - c) / 26) ** 2) + 70 * math.exp(-((x - c + 60) / 22) ** 2)
    return y


def scene_hook(t, tg):
    f = background(tg, RED, 1.6)
    cx, cy = 960, 330
    for k in range(4):
        p = ((t * 0.55) + k / 4) % 1.0
        size = int(80 + p * 1100)
        paste(f, ring(size, RED, 5), cx - size // 2, cy - size // 2, (1 - p) ** 1.5 * 0.5)
    mark = sprite('mark', lambda: Image.open(ASSETS / 'sard-mark.png').convert('RGBA').crop((190, 190, 834, 834)).resize((520, 520), Image.LANCZOS))
    sc = 0.5 + 0.5 * back_out(seg(t, 0.1, 0.9))
    m = mark.resize((max(2, int(340 * sc)), max(2, int(340 * sc))), Image.LANCZOS)
    paste(f, m, cx - m.width // 2, cy - m.height // 2, ease(seg(t, 0.1, 0.5)))
    # «Sismo.» y «Apagón.» en una sola línea centrada, palabra a palabra
    fnt = font(150, 'Heavy')
    total_w = fnt.getlength('Sismo.  Apagón.')
    x0 = (W - total_w) / 2
    kinetic(f, 'Sismo.', x0, 500, 150, 'Heavy', TEXT, t, 0.35, dur=0.45, dy=60)
    kinetic(f, 'Apagón.', x0 + fnt.getlength('Sismo.  '), 500, 150, 'Heavy', TEXT, t, 1.2, dur=0.45, dy=60)
    centered(f, 'Un SOS que tiene que llegar.', 700, 76, 'Heavy', RED, t, 2.55, stagger=0.08)
    # sismógrafo bajo el titular
    base_y = 880
    pts = [(x, base_y + seismo_wave(t, x) * 0.6) for x in range(0, W + 8, 8)]
    lay = Image.new('RGBA', (W, 300), (0, 0, 0, 0))
    ImageDraw.Draw(lay).line([(x, y - (base_y - 150)) for x, y in pts], fill=RED + (255,), width=4, joint='curve')
    on = ease(seg(t, 0.1, 0.5))
    paste(f, lay.filter(ImageFilter.GaussianBlur(10)), 0, base_y - 150, 0.9 * on)
    paste(f, lay, 0, base_y - 150, 0.95 * on)
    if 0.3 <= t < 1.25:
        amp = 9 * math.exp(-(t - 0.3) * 2.2)
        rnd = random.Random(int(t * 60))
        f = zoom_frame(f, 1.03, 0.5 + rnd.uniform(-amp, amp) / 100, 0.5 + rnd.uniform(-amp, amp) / 100)
    dark = ease(seg(t, 1.2, 1.3)) * (1 - ease(seg(t, 1.38, 1.9)))
    if dark > 0:
        f = Image.blend(f, Image.new('RGBA', (W, H), (4, 5, 7, 255)), 0.92 * dark)
    return f


# ───────────────────────────── escena 1 · la app (toma real) ─────────────────────────────
PH_W, PH_H = 400, 840
SC_W, SC_H = 372, 812
PX, PY = 1300, 120


def phone_frame_image(i):
    src = WORK / 'phone_frames' / f'{i:05d}.png'
    if not src.exists(): src = sorted((WORK / 'phone_frames').glob('*.png'))[-1]
    return Image.open(src).convert('RGB').resize((SC_W, SC_H), Image.LANCZOS)


def scene_phone(t, tg):
    f = background(tg, RED, 1.0)
    brand(f, ease(seg(t, 0.4, 0.9)))
    eyebrow(f, '01 — EL REPORTE', t)
    enter = quint(seg(t, 0.0, 1.0))
    px = lerp(PX + 420, PX, enter)
    py = PY + 7 * math.sin(t * 1.3)
    on = ease(seg(t, 0, 0.5))
    gl = sprite('pgl', lambda: glow(RED, 900, 0.5))
    paste(f, gl, px + PH_W // 2 - 450, py + PH_H // 2 - 450, 0.3 * on + 0.6 * ease_out(seg(t, 3.3, 3.7)) * (1 - ease(seg(t, 3.7, 6.0))))
    sh = sprite('shadow', lambda: rounded((PH_W + 40, PH_H + 40), 80, (0, 0, 0, 150)).filter(ImageFilter.GaussianBlur(26)))
    paste(f, sh, px - 20, py + 14, on)
    paste(f, sprite('bezel', lambda: rounded((PH_W, PH_H), 66, (10, 13, 17, 255), (62, 74, 92, 255), 3)), px, py, on)
    idx = int(clamp(t, 0, PHONE_LEN - 0.034) * FPS)
    layer = Image.new('RGBA', (SC_W, SC_H), (0, 0, 0, 0))
    layer.paste(phone_frame_image(idx), (0, 0)); layer.putalpha(sprite('smask', lambda: rounded((SC_W, SC_H), 52, (255, 255, 255, 255)).getchannel('A')))
    sx, sy = px + (PH_W - SC_W) // 2, py + (PH_H - SC_H) // 2
    paste(f, layer, sx, sy, on)
    pulse_ring(f, sx + SOS_BTN[0] * SC_W, sy + SOS_BTN[1] * SC_H, seg(t, 3.3, 4.1), RED, 190, 6)
    items = [
        (3.2, (3.2, 4.0), '1', 'Un toque', RED, 'Se guarda al instante.', (0.30, SOS_BTN[1])),
        (4.0, (4.0, 7.0), '2', 'Sin red, no se pierde', AMBER, 'Queda en el teléfono: «Esperando señal».', (0.04, 0.46)),
        (7.0, (7.0, 11.0), '3', 'Sale sola al volver la señal', GREEN, '«Enviado a un nodo».', (0.04, 0.46)),
    ]
    for k, (a, (lo, hi), num, title, color, sub, target) in enumerate(items):
        p, dy = rise(t, a, 0.5, 40)
        if p <= 0: continue
        y = 270 + k * 190 + dy
        scd = 0.6 + 0.4 * back_out(seg(t, a, a + 0.5))
        dsc = sprite(('num', num), lambda color=color: disc(86, color + (255,)))
        d2 = dsc.resize((max(2, int(86 * scd)), max(2, int(86 * scd))), Image.LANCZOS)
        paste(f, d2, 163 - d2.width // 2, y + 43 - d2.height // 2, p)
        paste(f, sprite(('numt', num), lambda num=num: text_layer(num, 54, 'Heavy', TEXT)), 151, y + 10, p * ease(seg(t, a + 0.2, a + 0.4)))
        kinetic(f, title, 240, y - 6, 62, 'Heavy', TEXT, t, a + 0.05, stagger=0.06, dur=0.4, dy=24)
        paste(f, sprite(('ts', sub), lambda sub=sub: text_layer(sub, 36, 'Medium', MUTED)), 242, y + 68, ease(seg(t, a + 0.3, a + 0.6)))
        pl = ease(seg(t, lo + 0.25, lo + 0.75)) * ((1 - ease(seg(t, hi - 0.4, hi))) if k < 2 else 1.0)
        if pl > 0:
            ax, ay = 1130, y + 44
            bx, by = sx + target[0] * SC_W, sy + target[1] * SC_H
            ex, ey = lerp(ax, bx, pl), lerp(ay, by, pl)
            ln = Image.new('RGBA', (W, H), (0, 0, 0, 0))
            ImageDraw.Draw(ln).line((ax, ay, ex, ey), fill=color + (200,), width=3)
            f.alpha_composite(ln)
            paste(f, sprite(('dot', color), lambda color=color: disc(18, color + (255,))), ex - 9, ey - 9, 1.0)
    # 239 B (JSON) → 33 B: contador que baja
    p, dy = rise(t, 5.2, 0.5)
    outv = 1 - ease(seg(t, 7.0, 7.4))
    if p * outv > 0:
        v = int(round(lerp(239, 33, ease(seg(t, 5.3, 6.2)))))
        counter(f, v, ' B', 120, 820 + dy, 110, BLUE if v == 33 else MUTED, p * outv)
        paste(f, sprite('33bs', lambda: text_layer('lo que pesa un SOS · en JSON serían 239 B', 32, 'Medium', MUTED)), 126, 940 + dy, p * outv)
    return f


# ───────────────────────────── escena 2 · la red ─────────────────────────────
NODES = {'A': (880, 420), 'B': (880, 820), 'C': (1300, 620)}
PHONE_POS, BOARD_POS = (380, 620), (1560, 620)


def node_sprite(label, color, size=150):
    def make():
        im = disc(size, (27, 34, 43, 255), color + (255,), 6)
        d = ImageDraw.Draw(im)
        f = font(int(size * 0.5), 'Heavy')
        d.text(((size - f.getlength(label)) / 2, size * 0.18), label, font=f, fill=TEXT + (255,))
        return im
    return sprite(('node', label, color, size), make)


def along(p, q, s): return (lerp(p[0], q[0], s), lerp(p[1], q[1], s))


def packet(f, p, q, s, color=AMBER, r=22):
    if not 0 < s < 1: return
    for k, a in ((3, 0.18), (2, 0.3), (1, 0.5)):
        x, y = along(p, q, ease(max(0.0, s - 0.035 * k)))
        paste(f, sprite(('pkt', color, r), lambda: disc(int(r * 1.5), color + (255,))), x - r * 0.75, y - r * 0.75, a)
    x, y = along(p, q, ease(s))
    paste(f, sprite(('pk', color, r), lambda: disc(r * 2, color + (255,))), x - r, y - r)
    paste(f, sprite(('pkg', color), lambda: glow(color, 130, 0.6)), x - 65, y - 65)


def scene_red(t, tg):
    f = background(tg, BLUE, 1.2)
    brand(f, 1.0)
    eyebrow(f, '02 — LA RED', t)
    dr = ImageDraw.Draw(f)
    fall, back = 3.4, 5.7
    a_alive = not (fall <= t < back)
    dim = (58, 70, 86)

    def link(p, q, color, w=5, dashed=False):
        if dashed:
            n = int(math.dist(p, q) // 26)
            for i in range(n):
                dr.line([along(p, q, i / n), along(p, q, (i + 0.55) / n)], fill=color + (255,), width=w)
        else:
            dr.line([p, q], fill=color + (255,), width=w)

    on = ease(seg(t, 0, 0.5))
    link(PHONE_POS, NODES['A'], BLUE if a_alive else dim, 6, not a_alive)
    link(PHONE_POS, NODES['B'], dim if a_alive else BLUE, 6, True)
    for a, b in [('A', 'B'), ('A', 'C'), ('B', 'C')]:
        alive = a_alive or 'A' not in (a, b)
        link(NODES[a], NODES[b], (110, 124, 142) if alive else dim, 5, not alive)
    link(NODES['C'], BOARD_POS, GREEN, 6)
    paste(f, sprite('ph_icon', lambda: rounded((150, 250), 30, (27, 34, 43, 255), BLUE + (255,), 5)), PHONE_POS[0] - 75, PHONE_POS[1] - 125, on)
    paste(f, sprite('ph_s', lambda: text_layer('SOS', 44, 'Heavy', RED)), PHONE_POS[0] - 44, PHONE_POS[1] - 30, on)
    paste(f, sprite('bd_icon', lambda: rounded((250, 170), 22, (27, 34, 43, 255), GREEN + (255,), 5)), BOARD_POS[0] - 125, BOARD_POS[1] - 85, on)
    paste(f, sprite('bd_s', lambda: text_layer('Tablero', 40, 'Heavy', TEXT)), BOARD_POS[0] - 72, BOARD_POS[1] - 28, on)
    colors = {'A': RED if not a_alive else GREEN, 'B': GREEN, 'C': GREEN}
    for i, (k, (x, y)) in enumerate(NODES.items()):
        beat = 1 + 0.04 * max(0.0, math.sin((t - i * 0.2) * 2 * math.pi / BEAT)) ** 6  # latido al compás
        ns = node_sprite(k, colors[k])
        if beat > 1.001:
            ns = ns.resize((int(150 * beat), int(150 * beat)), Image.LANCZOS)
        paste(f, ns, x - ns.width // 2, y - ns.height // 2, on * (0.6 + 0.4 * back_out(seg(t, 0.1 + i * 0.12, 0.7 + i * 0.12))))
    if not a_alive:
        paste(f, sprite('x', make_x), NODES['A'][0] - 48, NODES['A'][1] - 48, ease(seg(t, fall, fall + 0.2)))
        paste(f, sprite('kill', lambda: text_layer('kill -9', 40, 'Heavy', RED)), NODES['A'][0] - 62, NODES['A'][1] - 140, ease(seg(t, fall, fall + 0.3)))
        pulse_ring(f, *NODES['A'], seg(t, fall, fall + 0.9), RED, 300, 6)
    packet(f, PHONE_POS, NODES['A'], seg(t, 0.5, 1.3))
    packet(f, NODES['A'], NODES['B'], seg(t, 1.3, 2.0), BLUE)
    packet(f, NODES['A'], NODES['C'], seg(t, 1.3, 2.0), BLUE)
    packet(f, NODES['C'], BOARD_POS, seg(t, 2.0, 2.6), GREEN)
    packet(f, PHONE_POS, NODES['B'], seg(t, 4.0, 4.8))
    packet(f, NODES['B'], NODES['C'], seg(t, 4.8, 5.4), BLUE)
    packet(f, NODES['C'], BOARD_POS, seg(t, 5.4, 5.9), GREEN)
    for at, pos, col in [(1.3, NODES['A'], BLUE), (2.0, NODES['B'], BLUE), (2.0, NODES['C'], BLUE), (2.6, BOARD_POS, GREEN), (4.8, NODES['B'], BLUE), (5.4, NODES['C'], BLUE), (5.9, BOARD_POS, GREEN)]:
        pulse_ring(f, pos[0], pos[1], seg(t, at, at + 0.7), col, 190, 4)
    if t >= back:
        for src in 'BC': packet(f, NODES[src], NODES['A'], seg(t, back, back + 0.7), BLUE)
        pulse_ring(f, *NODES['A'], seg(t, back + 0.7, back + 1.5), GREEN, 260, 5)
        p = ease(seg(t, back + 0.7, back + 1.2))
        for k, (x, y) in NODES.items():
            paste(f, sprite('hash', lambda: rounded((300, 60), 30, (27, 34, 43, 255), GREEN + (255,), 3)), x - 150, y + 92, p)
            paste(f, sprite('hasht', lambda: text_layer('huella fa1404d6', 30, 'Demi', GREEN)), x - 128, y + 100, p)
    centered(f, 'Sin nodo principal.', 130, 84, 'Heavy', TEXT, t, 0.2)
    if t >= fall + 0.3:
        msg = ('Un nodo cae.', RED, fall + 0.3) if t < back else ('Vuelve y coincide.', GREEN, back + 0.5)
        centered(f, msg[0], 240, 52, 'Demi', msg[1], t, msg[2], stagger=0.07, dur=0.35, dy=20)
    # cámara: zoom lento y, al caer A, un golpe
    z = 1.0 + 0.04 * ease(seg(t, 0, 9)) + 0.03 * (1 - ease(seg(t, fall, fall + 0.5))) * (t >= fall)
    return zoom_frame(f, z, 0.5, 0.52)


# ───────────────────────────── escena 3 · el tablero ─────────────────────────────
WIN_X, WIN_Y, BAR = 240, 46, 44
CLICK_AT = 3.1
CARD1 = (330, 322)
WHY, REC = (671, 293, 1424, 528), (671, 718, 1424, 900)  # tarjetas del detalle en la captura de 1440 × 900


def board_img(name): return sprite(('board', name), lambda: Image.open(ASSETS / name).convert('RGB'))


def view(t):
    if t < CLICK_AT + 0.35:
        z, cx, cy = lerp(1.0, 1.14, ease(seg(t, 0, CLICK_AT))), 0.0, 0.5
    else:
        z, cx, cy = lerp(1.18, 1.3, ease(seg(t, CLICK_AT + 0.35, 11.0))), 1.0, lerp(0.15, 0.55, ease(seg(t, 5.0, 9.0)))
    cw, ch = 1440 / z, 900 / z
    return z, (1440 - cw) * cx, (900 - ch) * cy


def crop_view(img, z, x0, y0):
    cw, ch = 1440 / z, 900 / z
    return img.crop((int(x0), int(y0), int(x0 + cw), int(y0 + ch))).resize((1440, 900), Image.BILINEAR)


def to_screen(px, py, z, x0, y0, wy): return WIN_X + (px - x0) * z, wy + BAR + (py - y0) * z


def window_bar():
    def make():
        im = rounded((1440, BAR + 30), 18, (27, 34, 43, 255))
        d = ImageDraw.Draw(im)
        for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            d.ellipse((24 + i * 30, 14, 24 + i * 30 + 16, 30), fill=c)
        im.alpha_composite(rounded((420, 28), 14, (18, 22, 28, 255)), (510, 8))
        d.text((600, 11), 'localhost:8081 · SARD', font=font(19, 'Medium'), fill=MUTED + (255,))
        return im.crop((0, 0, 1440, BAR))
    return sprite('wbar', make)


def outline(f, x0, y0, x1, y1, color, a, width=4):
    if a <= 0 or x1 - x0 < 10 or y1 - y0 < 10: return
    box = rounded((int(x1 - x0), int(y1 - y0)), 14, (0, 0, 0, 0), color + (255,), width)
    paste(f, box, x0, y0, a)


def scene_tablero(t, tg):
    f = background(tg, BLUE, 0.8)
    lista, det = board_img('tablero-lista.png'), board_img('tablero-detalle.png')
    mix = ease(seg(t, CLICK_AT + 0.08, CLICK_AT + 0.33))
    a = crop_view(lista, *view(min(t, CLICK_AT)))
    b = crop_view(det, *view(max(t, CLICK_AT + 0.35)))
    content = Image.blend(a, b, mix).convert('RGBA')
    full = Image.new('RGBA', (1440, 900 + BAR), (0, 0, 0, 0))
    full.alpha_composite(window_bar(), (0, 0))
    full.alpha_composite(content, (0, BAR))
    full.putalpha(sprite('wmask', lambda: rounded((1440, 900 + BAR), 18, (255, 255, 255, 255)).getchannel('A')))
    on = ease(seg(t, 0, 0.6))
    wy = WIN_Y + (1 - quint(seg(t, 0, 1.0))) * 120
    paste(f, sprite('wsh', lambda: rounded((1500, 900 + BAR + 60), 26, (0, 0, 0, 175)).filter(ImageFilter.GaussianBlur(28))), WIN_X - 30, wy - 10, on)
    paste(f, full, WIN_X, wy, on)
    # (sin antetítulo: la ventana ocupa el ancho y lo pisaría)
    # cursor → clic en el primer P1
    zl, xl, yl = view(min(t, CLICK_AT))
    tx, ty = to_screen(CARD1[0], CARD1[1], zl, xl, yl, wy)
    sx, sy = WIN_X + 1000, wy + BAR + 640
    pc = ease(seg(t, 1.5, CLICK_AT - 0.1))
    cxp, cyp = lerp(sx, tx, pc), lerp(sy, ty, pc) + 40 * math.sin(pc * math.pi)
    if t < CLICK_AT + 1.4:
        paste(f, cursor_sprite(), cxp, cyp, ease(seg(t, 1.2, 1.6)) * (1 - ease(seg(t, CLICK_AT + 0.9, CLICK_AT + 1.4))))
        pulse_ring(f, tx, ty, seg(t, CLICK_AT, CLICK_AT + 0.7), BLUE, 140, 4)
    # resaltes sobre lo que explican los rótulos
    if t >= CLICK_AT + 0.35:
        z, x0, y0 = view(t)
        for (bx0, by0, bx1, by1), color, a0, a1 in [(WHY, AMBER, 4.0, 7.0), (REC, GREEN, 5.6, 11.0)]:
            al = ease(seg(t, a0, a0 + 0.5)) * (1 - ease(seg(t, a1 - 0.4, a1))) * (0.75 + 0.25 * math.sin(t * 5))
            px0, py0 = to_screen(bx0, by0, z, x0, y0, wy)
            px1, py1 = to_screen(bx1, by1, z, x0, y0, wy)
            px0, py0, px1, py1 = max(px0, WIN_X + 6), max(py0, wy + BAR + 6), min(px1, WIN_X + 1434), min(py1, wy + 900 + BAR - 6)
            outline(f, px0, py0, px1, py1, color, al)
    groups = [[(1.0, 'Lo urgente, primero', RED), (2.0, 'Llegó desde el teléfono', BLUE)], [(4.0, 'Explica el porqué', AMBER), (5.6, 'Propone, no ejecuta', GREEN), (7.2, 'Decide una persona', GREEN)]]
    for gi, group in enumerate(groups):
        out = (1 - ease(seg(t, 2.65, 3.0))) if gi == 0 else 1.0
        if out <= 0: continue
        chips_ = [chip(text, color, 40) for _, text, color in group]
        total_w = sum(c.width for c in chips_) + 28 * (len(chips_) - 1)
        x = (W - total_w) / 2
        for (a_, text, color), c in zip(group, chips_):
            pp, dy = rise(t, a_, 0.45, 40)
            paste(f, c, x, 985 - c.height - 10 + dy, pp * out)
            x += c.width + 28
    return f


# ───────────────────────────── escena 4 · el silencio ─────────────────────────────
ZONAS = [(448, 110), (380, 249), (239, 357), (490, 406)]


def scene_silencio(t, tg):
    f = background(tg, VIOLET, 0.6)
    brand(f, 1.0)
    eyebrow(f, '04 — EL MAPA', t)
    crop = sprite('mapa', lambda: Image.open(ASSETS / 'expo-mapa-silencio-recorte.png').convert('RGB'))
    s = 1.3
    mw, mh = int(crop.width * s), int(crop.height * s)
    mx, my = 1000 + 10 * math.sin(t * 0.5), (H - mh) / 2 + 6 * math.cos(t * 0.4)
    p = ease(seg(t, 0, 0.6))
    img = sprite('mapa_s', lambda: crop.resize((mw, mh), Image.BILINEAR).convert('RGBA'))
    framed = img.copy(); framed.putalpha(sprite('mapa_m', lambda: rounded((mw, mh), 22, (255, 255, 255, 255)).getchannel('A')))
    paste(f, sprite('msh', lambda: rounded((mw + 30, mh + 30), 30, (0, 0, 0, 170)).filter(ImageFilter.GaussianBlur(24))), mx - 15, my + 5, p)
    paste(f, framed, mx + (1 - quint(seg(t, 0, 1.0))) * 260, my, p)
    # un barrido de radar que cruza el mapa y «enciende» las zonas
    sweep = (t * 0.25) % 1.0
    sw = Image.new('RGBA', (mw, mh), (0, 0, 0, 0))
    sx = int(sweep * mw)
    ImageDraw.Draw(sw).rectangle((sx - 60, 0, sx, mh), fill=VIOLET + (36,))
    ImageDraw.Draw(sw).line((sx, 0, sx, mh), fill=VIOLET + (150,), width=2)
    sw.putalpha(ImageChops.multiply(sw.getchannel('A'), sprite('mapa_m', lambda: rounded((mw, mh), 22, (255, 255, 255, 255)).getchannel('A'))))
    paste(f, sw, mx, my, p * ease(seg(t, 1.0, 1.6)))
    for k, (bx, by) in enumerate(ZONAS):
        on = ease(seg(t, 1.2 + 0.25 * k, 1.8 + 0.25 * k))
        for j in range(2):
            ph = ((t * 0.8) + j * 0.5 + k * 0.17) % 1.0
            size = int(60 + ph * 120)
            paste(f, ring(size, VIOLET, 4), mx + bx * s - size // 2, my + by * s - size // 2, (1 - ph) * 0.9 * on)
    kinetic(f, 'El silencio', 120, 300, 92, 'Heavy', TEXT, t, 0.25)
    kinetic(f, 'no es seguridad.', 120, 402, 92, 'Heavy', TEXT, t, 0.45)
    for k, (text, a) in enumerate([('Zonas que reportaron y callaron.', 2.2), ('Rayadas, bajo los incidentes.', 3.6), ('Una marca, no una conclusión.', 5.0)]):
        kinetic(f, text, 124, 560 + k * 80, 40, 'Medium', MUTED, t, a, stagger=0.05, dur=0.4, dy=20)
    return zoom_frame(f, 1.0 + 0.035 * ease(seg(t, 0, 8)), 0.55, 0.5)


# ───────────────────────────── escena 5 · cierre ─────────────────────────────
def scene_cierre(t, tg):
    f = background(tg, RED, 0.8)
    mark = sprite('mark_big', lambda: Image.open(ASSETS / 'sard-mark.png').convert('RGBA').crop((190, 190, 834, 834)).resize((520, 520), Image.LANCZOS))
    cx, cy = 960, 250
    p = ease_out(seg(t, 0.1, 0.9))
    sc = 0.5 + 0.5 * back_out(seg(t, 0.1, 0.9))
    m = mark.resize((max(2, int(300 * sc)), max(2, int(300 * sc))), Image.LANCZOS)
    for k in range(3):
        ph = ((t * 0.4) + k / 3) % 1.0
        size = int(300 + ph * 600)
        paste(f, ring(size, RED, 4), cx - size // 2, cy - size // 2, (1 - ph) ** 1.6 * 0.35 * p)
    pulse_ring(f, cx, cy, seg(t, 0.15, 1.1), RED, 800, 6)
    paste(f, m, cx - m.width // 2, cy - m.height // 2, p)
    centered(f, 'SARD', 410, 170, 'Heavy', TEXT, t, 0.3, dur=0.6, dy=60)
    centered(f, 'Reportes que sobreviven. Decisiones que se pueden explicar.', 620, 50, 'Demi', MUTED, t, 0.8, stagger=0.05)
    cards = [(33, ' B', 'por SOS', BLUE), (0, '', 'nodos principales', GREEN), (2069, '', 'pruebas automáticas', AMBER)]
    cw, gap = 440, 40
    x0 = (W - (cw * 3 + gap * 2)) / 2
    for k, (target, suffix, small, color) in enumerate(cards):
        a0 = 1.5 + 0.2 * k
        pp, dy = rise(t, a0, 0.5, 40)
        x = x0 + k * (cw + gap)
        paste(f, sprite(('st_c', cw), lambda: rounded((cw, 170), 28, (27, 34, 43, 255))), x, 730 + dy, pp)
        v = int(round(target * ease_out(seg(t, a0 + 0.2, a0 + 1.3)))) if target else 0
        counter(f, v, suffix, x + 32, 748 + dy, 72, color, pp)
        paste(f, sprite(('st_s', small), lambda small=small: text_layer(small, 32, 'Medium', MUTED)), x + 36, 840 + dy, pp)
    centered(f, 'github.com/Bdavid117/hackathon-asi  ·  se reproduce con un comando', 950, 32, 'Demi', TEXT, t, 2.6, kin=False)
    centered(f, 'Hackathon Expo ASI 2026 · Universidad Nacional de Colombia, Sede Manizales', 1000, 26, 'Medium', MUTED, t, 2.9, kin=False)
    return f


SCENE_FN = {'hook': scene_hook, 'phone': scene_phone, 'red': scene_red, 'tablero': scene_tablero, 'silencio': scene_silencio, 'cierre': scene_cierre}


# ───────────────────────────── subtítulos, progreso y fotograma ─────────────────────────────
def subtitle_cues(tl):
    cues = []
    for sc in tl:
        items = SUBS[sc['line']]
        for i, (text, frac) in enumerate(items):
            a = sc['voice_start'] + frac * sc['voice_len']
            b = sc['voice_start'] + (items[i + 1][1] * sc['voice_len'] if i + 1 < len(items) else sc['voice_len'] + 0.25)
            cues.append((a, b, text, sc['name']))
    return cues


def draw_subtitle(f, text, a):
    lay = sprite(('sub', text), lambda: text_layer(text, 46, 'Demi', TEXT))
    plate = sprite(('plate', text), lambda: rounded((lay.width + 60, lay.height + 24), 22, (10, 13, 17, 215)))
    x = (W - plate.width) // 2
    paste(f, plate, x, 968, a)
    paste(f, lay, x + 30, 968 + 8, a)


def slide_blur(img, dx, blur):
    if abs(dx) >= 1: img = img.transform(img.size, Image.AFFINE, (1, 0, -dx, 0, 1, 0), fillcolor=(10, 13, 17))
    if blur >= 0.4: img = img.filter(ImageFilter.GaussianBlur(blur))
    return img


def frame_at(t, tl, cues):
    active = [(i, sc) for i, sc in enumerate(tl) if sc['start'] <= t < sc['end']]
    total = tl[-1]['end']
    if not active:
        return background(t).convert('RGB')
    n = len(tl)
    frames = []
    for i, sc in active:
        local = t - sc['start']
        length = sc['end'] - sc['start']
        fr = SCENE_FN[sc['name']](local, t)
        win = quint(seg(local, 0, XFADE)) if i > 0 else ease(seg(local, 0, 0.5))
        wout = 1 - quint(seg(local, length - XFADE, length)) if i < n - 1 else 1 - ease(seg(local, length - 0.9, length))
        # la cámara se asienta al entrar en cada plano (llega un poco más cerca y se abre)
        if i > 0: fr = zoom_frame(fr, 1.0 + 0.05 * (1 - quint(seg(local, 0, 1.1))))
        frames.append((fr.convert('RGB'), win, wout))
    if len(frames) == 2:  # transición: la que sale se desliza a la izquierda y se desenfoca; la que entra llega desde la derecha y se enfoca
        fa, fb, p = frames[0][0], frames[1][0], frames[1][1]
        fa = slide_blur(fa, -110 * ease_in(p), 9 * p)
        fb = slide_blur(fb, 110 * (1 - p), 9 * (1 - p))
        out = Image.blend(fa, fb, p)
    else:
        fr, win, wout = frames[0]
        w = min(win, wout)
        out = Image.blend(background(t).convert('RGB'), fr, w) if w < 1 else fr
    o = out.convert('RGBA')
    for a, b, text, name in cues:
        if name == 'cierre' or not (a <= t < b): continue
        alpha = ease(seg(t, a + 0.03, a + 0.18)) * (1 - ease(seg(t, b - 0.12, b)))
        if alpha > 0: draw_subtitle(o, text, alpha)
    # barra de progreso, fina, abajo
    ImageDraw.Draw(o).rectangle((0, H - 5, int(W * t / total), H), fill=RED + (230,))
    return o.convert('RGB')


# ───────────────────────────── audio ─────────────────────────────
def process_voice(raw):
    x = [v / 32768.0 for v in raw]
    n = len(x)
    rc = 1 / (2 * math.pi * 80)
    a = rc / (rc + 1 / SR)
    y, px, py = [0.0] * n, 0.0, 0.0
    for i in range(n):
        py = a * (py + x[i] - px); px = x[i]; y[i] = py
    thr, ratio = 0.10, 3.0
    att, rel = math.exp(-1 / (0.005 * SR)), math.exp(-1 / (0.14 * SR))
    env = 0.0
    out = [0.0] * n
    for i in range(n):
        v = abs(y[i])
        env = att * env + (1 - att) * v if v > env else rel * env + (1 - rel) * v
        out[i] = y[i] * (1.0 if env <= thr else (thr / env) ** (1 - 1 / ratio))
    peak = max(abs(v) for v in out) or 1.0
    return [v * 0.80 / peak for v in out]


def noise_sweep(n, lo, hi, rnd):
    out, y = [0.0] * n, 0.0
    for i in range(n):
        fc = lo + (hi - lo) * (i / n) ** 2
        y += (1 - math.exp(-2 * math.pi * fc / SR)) * (rnd.uniform(-1, 1) - y)
        out[i] = y
    return out


def kick(amp=1.0):
    n = int(0.38 * SR); out = []
    ph = 0.0
    for i in range(n):
        tt = i / SR
        fr = 42 + 140 * math.exp(-tt * 28)
        ph += 2 * math.pi * fr / SR
        out.append(math.sin(ph) * math.exp(-tt * 9) * amp + (0.3 * math.sin(2 * math.pi * 1800 * tt) * math.exp(-tt * 120)) * amp)
    return out


def hat(rnd, amp=0.12, dur=0.05):
    n = int(dur * SR); out, prev = [], 0.0
    for i in range(n):
        v = rnd.uniform(-1, 1)
        out.append((v - prev) * math.exp(-i / SR * 70) * amp); prev = v
    return out


def snare(rnd, amp=0.5):
    n = int(0.18 * SR); out, y = [], 0.0
    for i in range(n):
        tt = i / SR
        y += 0.35 * (rnd.uniform(-1, 1) - y)
        out.append((y * 1.6 + 0.5 * math.sin(2 * math.pi * 190 * tt) * math.exp(-tt * 30)) * math.exp(-tt * 18) * amp)
    return out


def build_music(n, total, tl):
    """Pista con pulso a 100 ppm: pad, bajo, batería y arpegio; sube y baja según la escena (y calla un instante cuando cae el nodo)."""
    rnd = random.Random(7)
    by = {sc['name']: sc for sc in tl}
    chords = [(220.0, 261.63, 329.63, 392.0), (174.61, 220.0, 261.63, 329.63), (261.63, 329.63, 392.0, 493.88), (196.0, 246.94, 293.66, 392.0)]
    roots = [55.0, 43.65, 65.41, 49.0]
    bar = BEAT * 4
    music = [0.0] * n

    def energy(t):  # cuánta «batería» hay en cada momento (0..1)
        if t < by['phone']['start'] - 0.4: return 0.0
        if t < by['red']['start']: return 0.55
        if by['red']['start'] + 3.4 <= t < by['red']['start'] + 5.7: return 0.1  # cae un nodo: la música se retira
        if t < by['tablero']['end'] - 0.5: return 1.0
        if t < by['cierre']['start'] - BEAT: return 0.35
        if t < by['cierre']['start']: return 0.0  # un tiempo de silencio antes del golpe final
        if t < by['cierre']['end'] - 2.5: return 0.7
        return 0.0

    def add(at, samples, amp=1.0):
        o = int(at * SR)
        for i, s in enumerate(samples):
            if 0 <= o + i < n: music[o + i] += s * amp

    # pad + bajo (continuo)
    for i in range(0, n):
        t = i / SR
        k = int(t / bar) % len(chords)
        tt = (t % bar)
        envc = min(1.0, tt / 0.6 + 0.3)
        v = 0.0
        for j, fr in enumerate(chords[k]):
            v += math.sin(2 * math.pi * fr * t + 0.25 * math.sin(2 * math.pi * 0.13 * t + j)) / (1 + j * 0.6)
        music[i] = v * 0.05 * envc * min(1.0, t / 1.5) * (0.5 + 0.5 * (1 - 0.6 * energy(t)))
    # batería, bajo y arpegio por eventos
    k_s, hat_s, sn_s = kick(), None, None
    step = BEAT / 4
    for s in range(int(total / step) + 1):
        t0 = s * step
        e = energy(t0)
        k = int(t0 / bar) % len(chords)
        beat_in_bar = (s // 4) % 4
        sub16 = s % 4
        if e <= 0.05: continue
        if sub16 == 0 and beat_in_bar in (0, 2): add(t0, k_s, 0.55 * e)
        if sub16 == 0 and beat_in_bar == 2 and e >= 0.9: add(t0, snare(rnd, 0.28), 1.0)
        if sub16 in (0, 2): add(t0, hat(rnd, 0.09 if sub16 == 0 else 0.05, 0.05), e)
        if sub16 == 0 or (sub16 == 2 and e >= 0.9):  # bajo
            f0 = roots[k] * (1 if sub16 == 0 else 1.5)
            add(t0, [(math.sin(2 * math.pi * f0 * (i / SR)) + 0.25 * math.sin(2 * math.pi * 2 * f0 * (i / SR))) * math.exp(-5 * i / SR) * 0.22 for i in range(int(0.35 * SR))], e)
        if e >= 0.5 and sub16 in (1, 3):  # arpegio en contratiempo
            f0 = chords[k][(s // 2) % 4] * 2
            add(t0, [(math.sin(2 * math.pi * f0 * (i / SR)) + 0.3 * math.sin(2 * math.pi * 2 * f0 * (i / SR))) * math.exp(-9 * i / SR) * 0.07 for i in range(int(0.3 * SR))], e)
    # risers: un ascenso de ruido en el último compás antes de cada escena de producto
    for name in ('phone', 'red', 'tablero', 'cierre'):
        st = by[name]['start']
        w = noise_sweep(int(1.4 * SR), 200, 7000, rnd)
        add(st - 1.4, [x * (i / len(w)) ** 2 for i, x in enumerate(w)], 0.22)
        add(st, kick(1.0), 0.8)  # golpe en la entrada
    return music


def build_audio(tl, total):
    n = int((total + 0.8) * SR)
    voice = [0.0] * n
    for sc in tl:
        v = process_voice(wav_samples(WORK / 'voz' / f"{sc['line']}.wav"))
        off = int(sc['voice_start'] * SR)
        for i, s in enumerate(v):
            if off + i < n: voice[off + i] += s
    env, e = [0.0] * n, 0.0
    ra, rr = math.exp(-1 / (0.02 * SR)), math.exp(-1 / (0.35 * SR))
    for i in range(n):
        v = abs(voice[i])
        e = ra * e + (1 - ra) * v if v > e else rr * e + (1 - rr) * v
        env[i] = e
    rnd = random.Random(9)
    music = build_music(n, total, tl)
    fx = [0.0] * n

    def add(at, samples, amp=1.0):
        o = int(at * SR)
        for i, s in enumerate(samples):
            if 0 <= o + i < n: fx[o + i] += s * amp

    def tone(freqs, dur, decay, amp):
        return [sum(math.sin(2 * math.pi * f * (i / SR)) for f in freqs) / len(freqs) * amp * math.exp(-decay * (i / SR)) for i in range(int(dur * SR))]

    by = {sc['name']: sc for sc in tl}
    rumble = noise_sweep(int(1.0 * SR), 40, 70, rnd)
    add(by['hook']['start'] + 0.3, [r * math.exp(-2.0 * (i / SR)) * min(1.0, i / (0.06 * SR)) for i, r in enumerate(rumble)], 3.6)
    add(by['hook']['start'] + 1.2, [-(math.sin(2 * math.pi * 60 * (i / SR))) * math.exp(-6 * i / SR) * 0.5 for i in range(int(0.5 * SR))])  # el apagón: un golpe sordo
    add(by['hook']['start'] + 2.5, tone((1200.0, 600.0), 0.5, 9.0, 0.16))
    for sc in tl[1:]:
        w = noise_sweep(int(0.7 * SR), 250, 5500, rnd)
        add(sc['start'] - 0.05, [x * math.sin(math.pi * i / len(w)) ** 2 for i, x in enumerate(w)], 0.26)
    add(by['phone']['start'] + 3.3, tone((2400.0, 1600.0), 0.12, 38.0, 0.35))
    add(by['phone']['start'] + 7.0, tone((659.25, 987.77, 1318.5), 0.9, 4.0, 0.16))
    add(by['red']['start'] + 3.4, kick(1.0), 1.1)
    add(by['red']['start'] + 3.4, tone((82.4, 110.0), 0.9, 5.0, 0.3))
    add(by['red']['start'] + 5.7, tone((523.25, 783.99), 0.8, 5.0, 0.16))
    add(by['tablero']['start'] + 3.1, tone((2000.0, 1500.0), 0.1, 40.0, 0.3))
    add(by['cierre']['start'] + 0.25, tone((261.63, 392.0, 523.25), 2.2, 1.4, 0.16))
    left, right = [0.0] * n, [0.0] * n
    for i in range(n):
        t = i / SR
        duck = 1.0 - 0.55 * min(1.0, env[i] / 0.10)
        fade = min(1.0, t / 0.8) * min(1.0, (total + 0.7 - t) / 1.4)
        m = (music[i] * duck * 1.1 + fx[i]) * fade
        v = voice[i]
        left[i] = math.tanh((v + m) * 1.05) * 0.93
        right[i] = math.tanh((v + m * 0.94) * 1.05) * 0.93
    out = array.array('h')
    for a, b in zip(left, right):
        out.append(int(a * 32767)); out.append(int(b * 32767))
    path = WORK / 'audio.wav'
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(out.tobytes())
    subprocess.run(['afconvert', '-f', 'm4af', '-d', 'aac', '-b', '192000', str(path), str(WORK / 'audio.m4a')], check=True)
    pk = max(abs(x) for x in left)
    voiced = [left[i] for i in range(0, n, 5) if abs(voice[i]) > 0.02]
    rms = math.sqrt(sum(x * x for x in voiced) / max(1, len(voiced)))
    print(f'  audio: pico {20 * math.log10(pk):.1f} dBFS, nivel de la voz {20 * math.log10(rms):.1f} dBFS (RMS)')
    return WORK / 'audio.m4a'


def write_srt(cues, path):
    def ts(s):
        ms = int(round(s * 1000)); h, ms = divmod(ms, 3600000); m, ms = divmod(ms, 60000); sec, ms = divmod(ms, 1000)
        return f'{h:02d}:{m:02d}:{sec:02d},{ms:03d}'
    lines = []
    for i, (a, b, text, _) in enumerate(cues, 1):
        lines += [str(i), f'{ts(a)} --> {ts(b)}', text, '']
    pathlib.Path(path).write_text('\n'.join(lines), encoding='utf-8')


# ───────────────────────────── órdenes ─────────────────────────────
def encoder():
    exe = WORK / 'sard_encode'
    if not exe.exists() or exe.stat().st_mtime < (ROOT / 'encode.swift').stat().st_mtime:
        WORK.mkdir(parents=True, exist_ok=True)
        subprocess.run(['swiftc', '-O', str(ROOT / 'encode.swift'), '-o', str(exe)], check=True, stderr=subprocess.DEVNULL)
    return exe


def prepare():
    WORK.mkdir(parents=True, exist_ok=True)
    exe = encoder()
    synth_voice()
    mov = WORK / 'phone.mov'
    if not mov.exists(): sys.exit(f'falta la grabación del simulador: {mov}')
    fdir = WORK / 'phone_frames'
    if fdir.exists(): shutil.rmtree(fdir)
    subprocess.run([str(exe), 'extract', str(mov), str(FPS), str(fdir), str(PHONE_START), str(PHONE_START + PHONE_LEN)], check=True)
    tl = timeline()
    total = tl[-1]['end']
    print('escenas:', [(s['name'], round(s['start'], 2), round(s['end'], 2)) for s in tl], 'total', round(total, 2), 's')
    if total > 60: sys.exit(f'dura {total:.1f} s: pasa de 60 s')


def still(t):
    tl = timeline()
    out = WORK / 'still.png'
    frame_at(t, tl, subtitle_cues(tl)).save(out)
    print(out)


def render():
    tl = timeline()
    total = tl[-1]['end']
    if total > 60: sys.exit(f'dura {total:.1f} s: pasa de 60 s')
    cues = subtitle_cues(tl)
    exe = encoder()
    fr = WORK / 'frames'
    if fr.exists(): shutil.rmtree(fr)
    fr.mkdir()
    nframes = int(total * FPS)
    for i in range(nframes):
        frame_at(i / FPS, tl, cues).save(fr / f'{i:05d}.png', compress_level=1)
        if i % 150 == 0: print(f'  cuadro {i}/{nframes}', flush=True)
    out = WORK / 'salida'
    out.mkdir(exist_ok=True)
    subprocess.run([str(exe), 'frames', str(fr), str(FPS), str(WORK / 'video-sin-audio.mp4')], check=True)
    audio = build_audio(tl, total)
    subprocess.run([str(exe), 'mux', str(WORK / 'video-sin-audio.mp4'), str(audio), str(out / 'SARD-video.mp4')], check=True)
    write_srt([c for c in cues if c[3] != 'cierre'] + [c for c in cues if c[3] == 'cierre'], ROOT / 'guion.srt')
    ph = next(s for s in tl if s['name'] == 'phone')
    frame_at(ph['start'] + 8.0, tl, cues).save(out / 'SARD-video-poster.png')
    print('listo:', out / 'SARD-video.mp4', f'({total:.1f} s)', '· subtítulos:', ROOT / 'guion.srt')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'prepare': prepare()
    elif cmd == 'still': still(float(sys.argv[2]))
    elif cmd == 'render': render()
    else: sys.exit(__doc__)
