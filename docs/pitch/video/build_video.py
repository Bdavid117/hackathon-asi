#!/usr/bin/env python3
"""Video de presentación de SARD (≤ 60 s): narración, música y efectos sintetizados, rótulos y tomas REALES de la app y del tablero.

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

# ───────────────────────────── guion ─────────────────────────────
LINES = {
    'l1': 'Un sismo. Un apagón. Y alguien que necesita que su pedido de ayuda llegue.',
    'l2': 'SARD convierte un toque en un reporte que sobrevive. Se guarda sin red, pesa apenas treinta y tres bytes, y sale solo cuando vuelve la señal.',
    'l3': 'Cada reporte llega a una red de nodos sin jefe. Si uno cae, otro sigue; y al reunirse, vuelven a coincidir.',
    'l4': 'El tablero ordena lo urgente, explica por qué, y propone la acción. Nada se ejecuta sin la aprobación de una persona.',
    'l5': 'Y cuando una zona deja de reportar, el mapa lo marca. Porque el silencio no es seguridad.',
    'l6': 'SARD. Reportes que sobreviven. Decisiones que se pueden explicar.',
}
SUBS = {  # (texto, fracción de la narración en que entra)
    'l1': [('Un sismo. Un apagón.', 0.0), ('Y alguien que necesita que su pedido de ayuda llegue.', 0.36)],
    'l2': [('SARD convierte un toque en un reporte que sobrevive.', 0.0), ('Se guarda sin red, pesa apenas 33 bytes,', 0.34), ('y sale solo cuando vuelve la señal.', 0.72)],
    'l3': [('Cada reporte llega a una red de nodos sin jefe.', 0.0), ('Si uno cae, otro sigue;', 0.40), ('y al reunirse, vuelven a coincidir.', 0.66)],
    'l4': [('El tablero ordena lo urgente, explica por qué,', 0.0), ('y propone la acción.', 0.36), ('Nada se ejecuta sin la aprobación de una persona.', 0.55)],
    'l5': [('Y cuando una zona deja de reportar, el mapa lo marca.', 0.0), ('Porque el silencio no es seguridad.', 0.62)],
    'l6': [('SARD. Reportes que sobreviven.', 0.0), ('Decisiones que se pueden explicar.', 0.56)],
}
SCENES = [('hook', 5.4, 'l1'), ('phone', 11.0, 'l2'), ('red', 9.0, 'l3'), ('tablero', 11.0, 'l4'), ('silencio', 8.0, 'l5'), ('cierre', 7.0, 'l6')]
LEAD, TAIL, XFADE = 0.6, 0.9, 0.5  # la voz entra LEAD s después de empezar la escena; las escenas se solapan XFADE s (fundido cruzado)
PHONE_START, PHONE_LEN = 5.6, 11.0  # el toque en SOS cae ≈ 3,4 s después del inicio de la toma
# Posición de lo que se ve en la pantalla de la app (fracciones del ancho y alto de la captura; medidas sobre la grabación)
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
    """Inicio, fin y voz de cada escena a partir de lo que dura de verdad la narración. Las escenas se solapan XFADE s."""
    t, out = 0.0, []
    for name, minimum, line in SCENES:
        dur = len(wav_samples(WORK / 'voz' / f'{line}.wav')) / SR
        length = max(minimum, LEAD + dur + TAIL)
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


def background(tg=0.0):
    """Fondo con viñeta y una cuadrícula casi invisible que se desplaza despacio (movimiento de fondo, como en un video de producto)."""
    f = sprite('bg', _make_bg).copy()
    grid = sprite('grid', _make_grid)
    ox, oy = int(tg * 9) % 120, int(tg * 5) % 120
    f.alpha_composite(grid.crop((ox, oy, ox + W, oy + H)))
    return f


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


def chip(text, color, size=40):
    def make():
        f = font(size, 'Demi')
        tw = int(f.getlength(text))
        im = rounded((tw + 56, size + 40), (size + 40) // 2, (27, 34, 43, 240), color + (255,), 3)
        ImageDraw.Draw(im).text((28, 16), text, font=f, fill=TEXT + (255,))
        return im
    return sprite(('chip', text, color, size), make)


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
    """Onda que sale de un punto (clic, llegada de un paquete)."""
    if not 0 < p < 1: return
    d = int(30 + ease_out(p) * max_d)
    paste(f, ring(d, color, width), cx - d // 2, cy - d // 2, (1 - p) ** 1.4 * 0.9)


# ───────────────────────────── escena 0 · gancho ─────────────────────────────
def seismo_wave(t, x):
    """Un sismógrafo: se agita con el sismo, se queda plano con el apagón y deja pasar un pulso (el SOS)."""
    env = 0.0
    if 0.3 <= t < 1.2: env = math.exp(-(t - 0.3) * 0.9) * min(1.0, (t - 0.3) / 0.15)
    y = env * 95 * (math.sin(x * 0.045 + t * 31) * 0.6 + math.sin(x * 0.11 - t * 47) * 0.3 + math.sin(x * 0.021 + t * 13) * 0.4)
    if t >= 2.5:  # un pulso que cruza la pantalla
        c = (t - 2.5) * 900
        y += -170 * math.exp(-((x - c) / 26) ** 2) + 70 * math.exp(-((x - c + 60) / 22) ** 2)
    return y


def scene_hook(t, tg):
    f = background(tg)
    base_y = 930
    pts = [(x, base_y + seismo_wave(t, x)) for x in range(0, W + 8, 8)]
    lay = Image.new('RGBA', (W, 460), (0, 0, 0, 0))
    ImageDraw.Draw(lay).line([(x, y - (base_y - 230)) for x, y in pts], fill=RED + (255,), width=4, joint='curve')
    gl = lay.filter(ImageFilter.GaussianBlur(10))
    paste(f, gl, 0, base_y - 230, 0.9 * ease(seg(t, 0.1, 0.5)))
    paste(f, lay, 0, base_y - 230, 0.95 * ease(seg(t, 0.1, 0.5)))
    cx, cy = 1230, 440
    for k in range(4):
        p = ((t * 0.55) + k / 4) % 1.0
        size = int(80 + p * 900)
        paste(f, ring(size, RED, 5), cx - size // 2, cy - size // 2, (1 - p) ** 1.5 * 0.6)
    mark = sprite('mark', lambda: Image.open(ASSETS / 'sard-mark.png').convert('RGBA').crop((190, 190, 834, 834)).resize((440, 440), Image.LANCZOS))
    sc = lerp(0.9, 1.0, ease_out(seg(t, 0.2, 1.2)))
    m = mark.resize((int(440 * sc), int(440 * sc)), Image.LANCZOS)
    paste(f, m, cx - m.width // 2, cy - m.height // 2, ease(seg(t, 0.2, 0.9)))
    for txt, st, color, size, y in [('Sismo.', 0.35, TEXT, 150, 200), ('Apagón.', 1.2, TEXT, 150, 350), ('Un SOS que\ntiene que llegar.', 2.55, RED, 84, 540)]:
        p, dy = rise(t, st, 0.5)
        paste(f, sprite(('hook', txt), lambda txt=txt, size=size, color=color: text_layer(txt, size, 'Heavy', color)), 150, y + dy, p)
    return f


# ───────────────────────────── escena 1 · la app (toma real) ─────────────────────────────
PH_W, PH_H = 400, 840
SC_W, SC_H = 372, 812
PX, PY = 1260, 70


def phone_frame_image(i):
    src = WORK / 'phone_frames' / f'{i:05d}.png'
    if not src.exists(): src = sorted((WORK / 'phone_frames').glob('*.png'))[-1]
    return Image.open(src).convert('RGB').resize((SC_W, SC_H), Image.LANCZOS)


def scene_phone(t, tg):
    f = background(tg)
    py = PY + 7 * math.sin(t * 1.3)  # el teléfono «respira»
    on = ease(seg(t, 0, 0.6))
    gl = sprite('pgl', lambda: glow(RED, 900, 0.5))  # resplandor detrás: se enciende al tocar SOS
    paste(f, gl, PX + PH_W // 2 - 450, py + PH_H // 2 - 450, 0.35 * on + 0.55 * ease_out(seg(t, 3.3, 3.7)) * (1 - ease(seg(t, 3.7, 6.0))))
    sh = sprite('shadow', lambda: rounded((PH_W + 40, PH_H + 40), 80, (0, 0, 0, 150)).filter(ImageFilter.GaussianBlur(26)))
    paste(f, sh, PX - 20, py + 14, on)
    paste(f, sprite('bezel', lambda: rounded((PH_W, PH_H), 66, (10, 13, 17, 255), (62, 74, 92, 255), 3)), PX, py, on)
    idx = int(clamp(t, 0, PHONE_LEN - 0.034) * FPS)
    layer = Image.new('RGBA', (SC_W, SC_H), (0, 0, 0, 0))
    layer.paste(phone_frame_image(idx), (0, 0)); layer.putalpha(sprite('smask', lambda: rounded((SC_W, SC_H), 52, (255, 255, 255, 255)).getchannel('A')))
    sx, sy = PX + (PH_W - SC_W) // 2, py + (PH_H - SC_H) // 2
    paste(f, layer, sx, sy, on)
    pulse_ring(f, sx + SOS_BTN[0] * SC_W, sy + SOS_BTN[1] * SC_H, seg(t, 3.3, 4.1), RED, 190, 6)  # onda del toque en SOS
    items = [  # rótulos con una línea guía hasta lo que explican
        (3.2, (3.2, 4.0), '1', 'Un toque', RED, 'Se guarda al instante.', (0.30, SOS_BTN[1])),
        (4.0, (4.0, 7.0), '2', 'Sin red, no se pierde', AMBER, 'Queda en el teléfono: «Esperando señal».', (0.04, 0.46)),
        (7.0, (7.0, 11.0), '3', 'Sale sola al volver la señal', GREEN, '«Enviado a un nodo».', (0.04, 0.46)),
    ]
    for k, (a, (lo, hi), num, title, color, sub, target) in enumerate(items):
        p, dy = rise(t, a, 0.5)
        if p <= 0: continue
        y = 270 + k * 190 + dy
        paste(f, sprite(('num', num), lambda color=color: disc(86, color + (255,))), 120, y, p)
        paste(f, sprite(('numt', num), lambda num=num: text_layer(num, 54, 'Heavy', TEXT)), 151, y + 10, p)
        paste(f, sprite(('tt', title), lambda title=title: text_layer(title, 62, 'Heavy', TEXT)), 240, y - 6, p)
        paste(f, sprite(('ts', sub), lambda sub=sub: text_layer(sub, 36, 'Medium', MUTED)), 242, y + 68, p)
        pl = ease(seg(t, lo + 0.25, lo + 0.75)) * ((1 - ease(seg(t, hi - 0.4, hi))) if k < 2 else 1.0)
        if pl > 0:
            ax, ay = 1130, y + 44
            bx, by = sx + target[0] * SC_W, sy + target[1] * SC_H
            ex, ey = lerp(ax, bx, pl), lerp(ay, by, pl)
            ln = Image.new('RGBA', (W, H), (0, 0, 0, 0))
            ImageDraw.Draw(ln).line((ax, ay, ex, ey), fill=color + (200,), width=3)
            f.alpha_composite(ln)
            paste(f, sprite(('dot', color), lambda color=color: disc(18, color + (255,))), ex - 9, ey - 9, 1.0)
    p, dy = rise(t, 5.2, 0.5)
    outv = 1 - ease(seg(t, 7.0, 7.4))
    paste(f, sprite('33b', lambda: text_layer('33 B', 130, 'Heavy', BLUE)), 120, 800 + dy, p * outv)
    paste(f, sprite('33bs', lambda: text_layer('lo que pesa un SOS', 38, 'Medium', MUTED)), 126, 930 + dy, p * outv)
    return f


# ───────────────────────────── escena 2 · la red ─────────────────────────────
NODES = {'A': (1010, 390), 'B': (1010, 790), 'C': (1440, 590)}
PHONE_POS, BOARD_POS = (540, 590), (1720, 590)


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
    for k, a in ((3, 0.18), (2, 0.3), (1, 0.5)):  # estela
        x, y = along(p, q, ease(max(0.0, s - 0.035 * k)))
        paste(f, sprite(('pkt', color, r), lambda: disc(int(r * 1.5), color + (255,))), x - r * 0.75, y - r * 0.75, a)
    x, y = along(p, q, ease(s))
    paste(f, sprite(('pk', color, r), lambda: disc(r * 2, color + (255,))), x - r, y - r)
    paste(f, sprite(('pkg', color), lambda: glow(color, 130, 0.6)), x - 65, y - 65)


def scene_red(t, tg):
    f = background(tg)
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
    for k, (x, y) in NODES.items():
        paste(f, node_sprite(k, colors[k]), x - 75, y - 75, on)
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
        pulse_ring(f, pos[0], pos[1], seg(t, at, at + 0.7), col, 190, 4)  # ondas cuando llega algo
    if t >= back:
        for src in 'BC': packet(f, NODES[src], NODES['A'], seg(t, back, back + 0.7), BLUE)
        pulse_ring(f, *NODES['A'], seg(t, back + 0.7, back + 1.5), GREEN, 260, 5)
        p = ease(seg(t, back + 0.7, back + 1.2))
        for k, (x, y) in NODES.items():
            paste(f, sprite('hash', lambda: rounded((300, 60), 30, (27, 34, 43, 255), GREEN + (255,), 3)), x - 150, y + 92, p)
            paste(f, sprite('hasht', lambda: text_layer('huella fa1404d6', 30, 'Demi', GREEN)), x - 128, y + 100, p)
    p, dy = rise(t, 0.2)
    paste(f, sprite('t_red', lambda: text_layer('Sin nodo principal.', 84, 'Heavy', TEXT)), 120, 90 + dy, p)
    if t >= fall + 0.3:
        msg = ('Un nodo cae.', RED, fall + 0.3) if t < back else ('Vuelve y coincide.', GREEN, back + 0.5)
        p, dy = rise(t, msg[2], 0.4)
        paste(f, sprite(('m', msg[0]), lambda: text_layer(msg[0], 52, 'Demi', msg[1])), 124, 215 + dy, p)
    return f


# ───────────────────────────── escena 3 · el tablero ─────────────────────────────
WIN_X, WIN_Y, BAR = 240, 46, 44
CLICK_AT = 3.1
CARD1 = (330, 322)  # el primer P1 de la lista, en píxeles de la captura de 1440 × 900


def board_img(name): return sprite(('board', name), lambda: Image.open(ASSETS / name).convert('RGB'))


def view(t):
    """Zoom lento sobre la lista y, tras el clic, sobre el detalle. Devuelve (zoom, x0, y0) para convertir coordenadas de la captura."""
    if t < CLICK_AT + 0.35:
        z, cx, cy = lerp(1.0, 1.14, ease(seg(t, 0, CLICK_AT))), 0.0, 0.5
    else:
        z, cx, cy = lerp(1.18, 1.28, ease(seg(t, CLICK_AT + 0.35, 11.0))), 1.0, 0.3
    cw, ch = 1440 / z, 900 / z
    return z, (1440 - cw) * cx, (900 - ch) * cy


def crop_view(img, z, x0, y0):
    cw, ch = 1440 / z, 900 / z
    return img.crop((int(x0), int(y0), int(x0 + cw), int(y0 + ch))).resize((1440, 900), Image.BILINEAR)


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


def scene_tablero(t, tg):
    f = background(tg)
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
    paste(f, sprite('wsh', lambda: rounded((1500, 900 + BAR + 60), 26, (0, 0, 0, 175)).filter(ImageFilter.GaussianBlur(28))), WIN_X - 30, WIN_Y - 10, on)
    paste(f, full, WIN_X, WIN_Y + (1 - on) * 24, on)
    # cursor: llega al primer P1, hace clic y se abre su detalle
    zl, xl, yl = view(min(t, CLICK_AT))
    tx, ty = WIN_X + (CARD1[0] - xl) * zl, WIN_Y + BAR + (CARD1[1] - yl) * zl
    sx, sy = WIN_X + 1000, WIN_Y + BAR + 640
    pc = ease(seg(t, 1.5, CLICK_AT - 0.1))
    cxp, cyp = lerp(sx, tx, pc), lerp(sy, ty, pc) + 40 * math.sin(pc * math.pi)
    if t < CLICK_AT + 1.4:
        paste(f, cursor_sprite(), cxp, cyp, ease(seg(t, 1.2, 1.6)) * (1 - ease(seg(t, CLICK_AT + 0.9, CLICK_AT + 1.4))))
        pulse_ring(f, tx, ty, seg(t, CLICK_AT, CLICK_AT + 0.7), BLUE, 140, 4)
    chips = [
        (1.0, 3.0, 'Lo urgente, primero', RED, 120, 850),
        (2.0, 3.0, 'Llegó desde el teléfono', BLUE, 640, 850),
        (4.0, 11.0, 'Por qué tiene esa prioridad', AMBER, 120, 850),
        (5.6, 11.0, 'Es una propuesta', GREEN, 810, 850),
        (7.2, 11.0, 'Aprueba una persona', GREEN, 1250, 850),
    ]
    for a_, b_, text, color, x, y in chips:
        pp, dy = rise(t, a_, 0.45)
        out = 1 - ease(seg(t, b_ - 0.35, b_)) if b_ < 10.9 else 1.0
        paste(f, chip(text, color, 40), x, y + dy, pp * out)
    return f


# ───────────────────────────── escena 4 · el silencio ─────────────────────────────
ZONAS = [(448, 110), (380, 249), (239, 357), (490, 406)]  # centros de las zonas rayadas en el recorte de 655×680


def scene_silencio(t, tg):
    f = background(tg)
    crop = sprite('mapa', lambda: Image.open(ASSETS / 'expo-mapa-silencio-recorte.png').convert('RGB'))
    s = 1.3
    mw, mh = int(crop.width * s), int(crop.height * s)
    mx, my = 1030, 70
    p = ease(seg(t, 0, 0.6))
    img = sprite('mapa_s', lambda: crop.resize((mw, mh), Image.BILINEAR).convert('RGBA'))
    framed = img.copy(); framed.putalpha(sprite('mapa_m', lambda: rounded((mw, mh), 22, (255, 255, 255, 255)).getchannel('A')))
    paste(f, sprite('msh', lambda: rounded((mw + 30, mh + 30), 30, (0, 0, 0, 170)).filter(ImageFilter.GaussianBlur(24))), mx - 15, my + 5, p)
    paste(f, framed, mx, my, p)
    for k, (bx, by) in enumerate(ZONAS):
        on = ease(seg(t, 1.2 + 0.25 * k, 1.8 + 0.25 * k))
        for j in range(2):
            ph = ((t * 0.8) + j * 0.5 + k * 0.17) % 1.0
            size = int(60 + ph * 120)
            paste(f, ring(size, VIOLET, 4), mx + bx * s - size // 2, my + by * s - size // 2, (1 - ph) * 0.9 * on)
    pt, dy = rise(t, 0.25)
    paste(f, sprite('t_sil', lambda: text_layer('El silencio\nno es seguridad.', 92, 'Heavy', TEXT, line_gap=1.08)), 110, 150 + dy, pt)
    for k, (text, a) in enumerate([('Zonas que reportaron y callaron.', 2.2), ('Rayadas, bajo los incidentes.', 3.6), ('Una marca, no una conclusión.', 5.0)]):
        pp, dy = rise(t, a, 0.5)
        paste(f, sprite(('sl', text), lambda text=text: text_layer(text, 44, 'Medium', MUTED)), 116, 470 + k * 90 + dy, pp)
    return f


# ───────────────────────────── escena 5 · cierre ─────────────────────────────
def scene_cierre(t, tg):
    f = background(tg)
    mark = sprite('mark_big', lambda: Image.open(ASSETS / 'sard-mark.png').convert('RGBA').crop((190, 190, 834, 834)).resize((420, 420), Image.LANCZOS))
    p = ease_out(seg(t, 0.1, 0.9))
    for k in range(3):  # el SOS que se propaga, otra vez, tranquilo
        ph = ((t * 0.4) + k / 3) % 1.0
        size = int(420 + ph * 500)
        paste(f, ring(size, RED, 4), 250 + 210 - size // 2, 190 + 210 - size // 2, (1 - ph) ** 1.6 * 0.35 * p)
    paste(f, mark, 250, 190 + (1 - p) * 20, p)
    paste(f, sprite('sard', lambda: text_layer('SARD', 190, 'Heavy', TEXT)), 760, 190 + (1 - p) * 20, p)
    paste(f, sprite('sub', lambda: text_layer('Reportes que sobreviven.\nDecisiones que se pueden explicar.', 56, 'Demi', MUTED, line_gap=1.2)), 764, 410 + (1 - p) * 20, ease(seg(t, 0.6, 1.3)))
    for k, (big, small, color) in enumerate([('33 B', 'por SOS', BLUE), ('0', 'nodos principales', GREEN), ('2 069', 'pruebas automáticas', AMBER)]):
        pp, dy = rise(t, 1.5 + 0.25 * k, 0.5)
        x = 190 + k * 540
        paste(f, sprite(('st_c', k), lambda: rounded((500, 190), 28, (27, 34, 43, 255))), x, 640 + dy, pp)
        paste(f, sprite(('st_b', big), lambda big=big, color=color: text_layer(big, 84, 'Heavy', color)), x + 36, 664 + dy, pp)
        paste(f, sprite(('st_s', small), lambda small=small: text_layer(small, 36, 'Medium', MUTED)), x + 40, 770 + dy, pp)
    paste(f, sprite('credit', lambda: text_layer('Hackathon Expo ASI 2026 · Universidad Nacional de Colombia, Sede Manizales', 36, 'Medium', MUTED)), 190, 900, ease(seg(t, 2.6, 3.2)))
    return f


SCENE_FN = {'hook': scene_hook, 'phone': scene_phone, 'red': scene_red, 'tablero': scene_tablero, 'silencio': scene_silencio, 'cierre': scene_cierre}


# ───────────────────────────── subtítulos y fotograma ─────────────────────────────
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


def frame_at(t, tl, cues):
    active = [(i, sc) for i, sc in enumerate(tl) if sc['start'] <= t < sc['end']]
    if not active:
        return background(t).convert('RGB')
    n = len(tl)
    frames = []
    for i, sc in active:
        local = t - sc['start']
        length = sc['end'] - sc['start']
        fr = SCENE_FN[sc['name']](local, t).convert('RGB')
        win = ease(seg(local, 0, XFADE)) if i > 0 else ease(seg(local, 0, 0.5))
        wout = 1 - ease(seg(local, length - XFADE, length)) if i < n - 1 else 1 - ease(seg(local, length - 0.9, length))
        frames.append((fr, win, wout))
    if len(frames) == 2:  # fundido cruzado entre la que sale y la que entra
        out = Image.blend(frames[0][0], frames[1][0], frames[1][1])
    else:
        fr, win, wout = frames[0]
        w = min(win, wout)
        out = Image.blend(background(t).convert('RGB'), fr, w) if w < 1 else fr
    for a, b, text, name in cues:
        if name == 'cierre' or not (a <= t < b): continue
        alpha = ease(seg(t, a + 0.03, a + 0.18)) * (1 - ease(seg(t, b - 0.12, b)))  # sale antes de que entre el siguiente: nunca dos a la vez
        if alpha > 0:
            o = out.convert('RGBA'); draw_subtitle(o, text, alpha); out = o.convert('RGB')
    return out


# ───────────────────────────── audio ─────────────────────────────
def process_voice(raw):
    """Voz de estudio: filtro de graves (80 Hz), compresión suave y nivel parejo."""
    x = [v / 32768.0 for v in raw]
    n = len(x)
    rc = 1 / (2 * math.pi * 80)
    a = rc / (rc + 1 / SR)
    y, px, py = [0.0] * n, 0.0, 0.0
    for i in range(n):
        py = a * (py + x[i] - px); px = x[i]; y[i] = py
    thr, ratio = 0.10, 3.0  # compresor: umbral −20 dBFS, razón 3:1, ataque 5 ms, relajación 140 ms
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
    """Ruido con un filtro paso bajo cuya frecuencia sube de `lo` a `hi` (un «whoosh»)."""
    out, y = [0.0] * n, 0.0
    for i in range(n):
        fc = lo + (hi - lo) * (i / n) ** 2
        y += (1 - math.exp(-2 * math.pi * fc / SR)) * (rnd.uniform(-1, 1) - y)
        out[i] = y
    return out


def build_audio(tl, total):
    n = int((total + 0.8) * SR)
    voice = [0.0] * n
    for sc in tl:
        v = process_voice(wav_samples(WORK / 'voz' / f"{sc['line']}.wav"))
        off = int(sc['voice_start'] * SR)
        for i, s in enumerate(v):
            if off + i < n: voice[off + i] += s
    env, e = [0.0] * n, 0.0  # envolvente de la voz: la música baja cuando se habla
    ra, rr = math.exp(-1 / (0.02 * SR)), math.exp(-1 / (0.35 * SR))
    for i in range(n):
        v = abs(voice[i])
        e = ra * e + (1 - ra) * v if v > e else rr * e + (1 - rr) * v
        env[i] = e
    rnd = random.Random(7)
    music = [0.0] * n
    chords = [(220.0, 261.63, 329.63, 392.0), (174.61, 220.0, 261.63, 329.63), (261.63, 329.63, 392.0, 493.88), (196.0, 246.94, 293.66, 392.0)]
    roots = [55.0, 43.65, 65.41, 49.0]
    seg_len = total / len(chords)
    for i in range(n):
        t = i / SR
        k = min(int(t / seg_len), len(chords) - 1)
        tt = t - k * seg_len
        envc = min(1.0, tt / 2.5) * min(1.0, (seg_len - tt) / 2.5 + 0.2)
        v = 0.0
        for j, fr in enumerate(chords[k]):
            v += math.sin(2 * math.pi * fr * t + 0.3 * math.sin(2 * math.pi * 0.17 * t + j)) / (1 + j * 0.6)
        v *= 0.45 + 0.2 * math.sin(2 * math.pi * 0.11 * t + 1.0)
        v += 1.1 * math.sin(2 * math.pi * roots[k] * t)  # bajo suave
        music[i] = v * envc * 0.07
    beat = 60 / 96 / 2  # arpegio muy suave, corcheas a 96 pulsos por minuto
    for step in range(int(total / beat)):
        t0 = step * beat
        if t0 < 4.0: continue
        k = min(int(t0 / seg_len), len(chords) - 1)
        f0 = chords[k][step % 4] * 2
        o = int(t0 * SR)
        for i in range(int(0.5 * SR)):
            if o + i >= n: break
            tt = i / SR
            music[o + i] += (math.sin(2 * math.pi * f0 * tt) + 0.3 * math.sin(2 * math.pi * f0 * 2 * tt)) * math.exp(-7 * tt) * 0.012
    fx = [0.0] * n

    def add(at, samples, amp=1.0):
        o = int(at * SR)
        for i, s in enumerate(samples):
            if 0 <= o + i < n: fx[o + i] += s * amp

    def tone(freqs, dur, decay, amp):
        return [sum(math.sin(2 * math.pi * f * (i / SR)) for f in freqs) / len(freqs) * amp * math.exp(-decay * (i / SR)) for i in range(int(dur * SR))]

    by = {sc['name']: sc for sc in tl}
    rumble = noise_sweep(int(0.9 * SR), 40, 70, rnd)  # temblor, apagón y pulso del SOS
    add(by['hook']['start'] + 0.3, [r * math.exp(-2.2 * (i / SR)) * min(1.0, i / (0.08 * SR)) for i, r in enumerate(rumble)], 3.2)
    add(by['hook']['start'] + 2.5, tone((1200.0, 600.0), 0.5, 9.0, 0.16))
    for sc in tl[1:]:  # un «whoosh» en cada transición
        w = noise_sweep(int(0.7 * SR), 250, 5500, rnd)
        add(sc['start'] - 0.05, [x * math.sin(math.pi * i / len(w)) ** 2 for i, x in enumerate(w)], 0.28)
    add(by['phone']['start'] + 3.3, tone((2400.0, 1600.0), 0.12, 38.0, 0.35))      # toque en SOS
    add(by['phone']['start'] + 7.0, tone((659.25, 987.77, 1318.5), 0.9, 4.0, 0.16))  # «Enviado a un nodo»
    add(by['red']['start'] + 3.4, tone((82.4, 110.0), 0.9, 5.0, 0.35))              # cae un nodo
    add(by['red']['start'] + 5.7, tone((523.25, 783.99), 0.8, 5.0, 0.16))           # vuelve
    add(by['tablero']['start'] + 3.1, tone((2000.0, 1500.0), 0.1, 40.0, 0.3))        # clic
    add(by['cierre']['start'] + 0.25, tone((261.63, 392.0, 523.25), 1.8, 1.6, 0.14))
    left, right = [0.0] * n, [0.0] * n
    for i in range(n):
        t = i / SR
        duck = 1.0 - 0.6 * min(1.0, env[i] / 0.10)
        fade = min(1.0, t / 0.8) * min(1.0, (total + 0.7 - t) / 1.2)
        m = (music[i] * duck * 1.4 + fx[i]) * fade
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
