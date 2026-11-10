#!/usr/bin/env python3
"""Video de presentación de SARD (≤ 60 s): narración con la voz del sistema, música sintetizada, rótulos y tomas REALES de la app y del tablero.

No necesita ffmpeg: usa `say`/`afconvert` de macOS, Pillow y el codificador de AVFoundation (`encode.swift`).

    python3 -I docs/pitch/video/build_video.py prepare              # compila el codificador, sintetiza la voz y extrae los fotogramas de la app
    python3 -I docs/pitch/video/build_video.py still 12.5           # un fotograma suelto (para revisar el diseño) → work/still.png
    python3 -I docs/pitch/video/build_video.py render               # todos los fotogramas + audio + video final (work/sard-video.mp4)

Las entradas (no versionadas, ver .gitignore): la grabación del simulador (`phone.mov`, con `xcrun simctl io … recordVideo` mientras corre
`apps/mobile/integration_test/marketing_flow.dart`) en `SARD_VIDEO_WORK`. Las capturas del tablero están en `assets/`. El video resultante
(*.mp4) NO se versiona ni se sube a ningún servicio sin decidirlo.
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

# ───────────────────────────── guion ─────────────────────────────
LINES = {
    'l1': 'Un sismo. Un apagón. Y alguien que necesita que su pedido de ayuda llegue.',
    'l2': 'SARD convierte un toque en un reporte que sobrevive. Se guarda sin red, pesa apenas treinta y tres bytes, y sale solo cuando vuelve la señal.',
    'l3': 'Cada reporte llega a una red de nodos sin jefe. Si uno cae, otro sigue; y al reunirse, vuelven a coincidir.',
    'l4': 'El tablero ordena lo urgente, explica por qué, y propone la acción. Nada se ejecuta sin la aprobación de una persona.',
    'l5': 'Y cuando una zona deja de reportar, el mapa lo marca. Porque el silencio no es seguridad.',
    'l6': 'SARD. Reportes que sobreviven. Decisiones que se pueden explicar.',
}
SUBS = {  # los rótulos (se parten en dos frases que salen cuando se dicen: tiempos relativos al inicio de la narración, en fracción de su duración)
    'l1': [('Un sismo. Un apagón.', 0.0), ('Y alguien que necesita que su pedido de ayuda llegue.', 0.36)],
    'l2': [('SARD convierte un toque en un reporte que sobrevive.', 0.0), ('Se guarda sin red, pesa apenas 33 bytes,', 0.34), ('y sale solo cuando vuelve la señal.', 0.72)],
    'l3': [('Cada reporte llega a una red de nodos sin jefe.', 0.0), ('Si uno cae, otro sigue;', 0.40), ('y al reunirse, vuelven a coincidir.', 0.66)],
    'l4': [('El tablero ordena lo urgente, explica por qué,', 0.0), ('y propone la acción.', 0.36), ('Nada se ejecuta sin la aprobación de una persona.', 0.55)],
    'l5': [('Y cuando una zona deja de reportar, el mapa lo marca.', 0.0), ('Porque el silencio no es seguridad.', 0.62)],
    'l6': [('SARD. Reportes que sobreviven.', 0.0), ('Decisiones que se pueden explicar.', 0.56)],
}
SCENES = [('hook', 5.0, 'l1'), ('phone', 11.0, 'l2'), ('red', 9.0, 'l3'), ('tablero', 11.0, 'l4'), ('silencio', 8.0, 'l5'), ('cierre', 7.0, 'l6')]
LEAD, TAIL, FADE = 0.35, 0.9, 0.35  # la voz entra 0,35 s después de que empieza la escena; cola tras la voz; dip de transición
PHONE_START = 5.6  # segundo de phone.mov que corresponde al inicio de la escena del teléfono (el toque en SOS cae ≈ 3,4 s después)
PHONE_LEN = 11.0

_fonts = {}
def font(size, style='Bold'):
    k = (size, style)
    if k not in _fonts:
        _fonts[k] = ImageFont.truetype(FONT_FILE, size, index=STYLE[style])
    return _fonts[k]


def clamp(x, a=0.0, b=1.0): return max(a, min(b, x))
def ease(x): x = clamp(x); return x * x * (3 - 2 * x)
def lerp(a, b, t): return a + (b - a) * t
def seg(t, a, b): return clamp((t - a) / (b - a))  # 0..1 dentro del tramo [a,b]


# ───────────────────────────── audio: voz ─────────────────────────────
def synth_voice():
    (WORK / 'voz').mkdir(parents=True, exist_ok=True)
    for k, text in LINES.items():
        aiff, wav = WORK / 'voz' / f'{k}.aiff', WORK / 'voz' / f'{k}.wav'
        if not wav.exists():
            subprocess.run(['say', '-v', VOICE, '-r', RATE, '-o', str(aiff), text], check=True)
            subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@44100', '-c', '1', str(aiff), str(wav)], check=True)


def wav_samples(path):
    with wave.open(str(path)) as w:
        assert w.getframerate() == 44100 and w.getnchannels() == 1 and w.getsampwidth() == 2
        a = array.array('h'); a.frombytes(w.readframes(w.getnframes()))
    return a


def timeline():
    """Inicio, fin y voz de cada escena, a partir de lo que dura de verdad la narración."""
    t, out = 0.0, []
    for name, minimum, line in SCENES:
        dur = len(wav_samples(WORK / 'voz' / f'{line}.wav')) / 44100
        length = max(minimum, LEAD + dur + TAIL)
        out.append({'name': name, 'start': t, 'end': t + length, 'line': line, 'voice_start': t + LEAD, 'voice_len': dur})
        t += length
    return out


# ───────────────────────────── sprites y utilidades de dibujo ─────────────────────────────
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


def text_layer(text, size, style='Bold', color=TEXT, spacing=0, anchor_w=None, align='left', line_gap=1.12):
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
    base.alpha_composite(l, (int(x), int(y))) if (0 <= int(x) and 0 <= int(y) and int(x) + l.width <= base.width and int(y) + l.height <= base.height) else _paste_clipped(base, l, int(x), int(y))


def _paste_clipped(base, l, x, y):
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(base.width, x + l.width), min(base.height, y + l.height)
    if x1 <= x0 or y1 <= y0: return
    base.alpha_composite(l.crop((x0 - x, y0 - y, x1 - x, y1 - y)), (x0, y0))


def rise(layer, t, start, dur=0.45, dy=26):
    """Entrada de un rótulo: aparece y sube. Devuelve (alpha, desplazamiento)."""
    p = ease(seg(t, start, start + dur))
    return p, (1 - p) * dy


_bg_cache = {}
def background():
    if 'bg' not in _bg_cache:
        im = Image.new('RGB', (W, H), BG)
        v = Image.new('L', (W, H), 0)
        ImageDraw.Draw(v).ellipse((-300, -300, W + 300, H + 300), fill=255)
        v = v.filter(ImageFilter.GaussianBlur(220))
        dark = Image.new('RGB', (W, H), (8, 10, 13))
        _bg_cache['bg'] = Image.composite(im, dark, v).convert('RGBA')
    return _bg_cache['bg'].copy()


def glow(color, size, strength=0.55):
    im = Image.new('RGBA', (size, size), color + (0,))
    px = im.load()
    c = size / 2
    for y in range(size):
        for x in range(size):
            r = math.hypot(x - c, y - c) / c
            if r < 1: px[x, y] = color + (int(255 * strength * (1 - r) ** 2),)
    return im


_sprites = {}
def sprite(key, make):
    if key not in _sprites: _sprites[key] = make()
    return _sprites[key]


# ───────────────────────────── escena 0 · gancho ─────────────────────────────
def scene_hook(t, d):
    f = background()
    cx, cy = 1180, 520
    # anillos que salen del centro, como un SOS que se propaga
    for k in range(4):
        p = ((t * 0.55) + k / 4) % 1.0
        size = int(80 + p * 900)
        a = (1 - p) ** 1.5 * 0.65
        paste(f, ring(size, RED, 5), cx - size // 2, cy - size // 2, a)
    paste(f, sprite('mark', lambda: Image.open(ASSETS / 'sard-mark.png').convert('RGBA').crop((190, 190, 834, 834)).resize((440, 440), Image.LANCZOS)), cx - 220, cy - 220, ease(seg(t, 0.2, 0.9)))
    # texto
    for i, (txt, st, color, size) in enumerate([('Sismo.', 0.35, TEXT, 150), ('Apagón.', 1.15, TEXT, 150), ('Un SOS que\ntiene que llegar.', 2.6, RED, 84)]):
        p, dy = rise(None, t, st)
        layer = sprite(('hook', txt), lambda txt=txt, size=size, color=color: text_layer(txt, size, 'Heavy', color))
        y = [250, 400, 590][i]
        paste(f, layer, 150, y + dy, p)
    return f


# ───────────────────────────── escena 1 · la app (toma real) ─────────────────────────────
PH_W, PH_H = 400, 840  # bisel del teléfono
SC_W, SC_H = 372, 812


def phone_frame_image(i):
    src = WORK / 'phone_frames' / f'{i:05d}.png'
    if not src.exists(): src = sorted((WORK / 'phone_frames').glob('*.png'))[-1]
    return Image.open(src).convert('RGB').resize((SC_W, SC_H), Image.LANCZOS)


def phone_bezel():
    def make():
        im = rounded((PH_W, PH_H), 66, (10, 13, 17, 255), (62, 74, 92, 255), 3)
        return im
    return sprite('bezel', make)


def screen_mask():
    return sprite('smask', lambda: rounded((SC_W, SC_H), 52, (255, 255, 255, 255)).getchannel('A'))


def chip(text, color, size=40, icon=None):
    def make():
        f = font(size, 'Demi')
        tw = int(f.getlength(text)) + (60 if icon else 0)
        im = rounded((tw + 56, size + 40), (size + 40) // 2, (27, 34, 43, 240), color + (255,), 3)
        d = ImageDraw.Draw(im)
        x = 28
        if icon:
            d.ellipse((x, 20 + size // 2 - 14, x + 28, 20 + size // 2 + 14), fill=color + (255,))
            x += 46
        d.text((x, 16), text, font=f, fill=TEXT + (255,))
        return im
    return sprite(('chip', text, color, size, icon), make)


def scene_phone(t, d):
    f = background()
    px, py = 1260, 70
    # sombra y bisel
    sh = sprite('shadow', lambda: rounded((PH_W + 40, PH_H + 40), 80, (0, 0, 0, 150)).filter(ImageFilter.GaussianBlur(26)))
    paste(f, sh, px - 20, py + 10, ease(seg(t, 0, 0.5)))
    paste(f, phone_bezel(), px, py, ease(seg(t, 0, 0.5)))
    idx = int(clamp(t - 0.0, 0, PHONE_LEN - 0.034) * FPS)
    scr = phone_frame_image(idx)
    layer = Image.new('RGBA', (SC_W, SC_H), (0, 0, 0, 0))
    layer.paste(scr, (0, 0)); layer.putalpha(screen_mask())
    paste(f, layer, px + (PH_W - SC_W) // 2, py + (PH_H - SC_H) // 2, ease(seg(t, 0, 0.5)))
    # rótulos que acompañan lo que pasa en la pantalla
    items = [
        (3.2, 6.6, '1', 'Un toque', RED, 'Se guarda al instante.'),
        (4.0, 7.4, '2', 'Sin red, no se pierde', AMBER, 'Queda en el teléfono: «Esperando señal».'),
        (7.0, 11.0, '3', 'Sale sola al volver la señal', GREEN, '«Enviado a un nodo».'),
    ]
    y0 = 270
    for k, (a, b, num, title, color, sub) in enumerate(items):
        p, dy = rise(None, t, a, 0.5)
        out = 1.0
        if p * out <= 0: continue
        y = y0 + k * 190 + dy
        paste(f, sprite(('num', num), lambda num=num, color=color: disc(86, color + (255,))), 120, y, p * out)
        paste(f, sprite(('numt', num), lambda num=num: text_layer(num, 54, 'Heavy', TEXT)), 120 + 31, y + 10, p * out)
        paste(f, sprite(('tt', title), lambda title=title: text_layer(title, 62, 'Heavy', TEXT)), 240, y - 6, p * out)
        paste(f, sprite(('ts', sub), lambda sub=sub: text_layer(sub, 36, 'Medium', MUTED)), 242, y + 68, p * out)
    # 33 B
    p, dy = rise(None, t, 5.2, 0.5)
    paste(f, sprite('33b', lambda: text_layer('33 B', 130, 'Heavy', BLUE)), 120, 800 + dy, p * (1 - ease(seg(t, 7.0, 7.4))))
    paste(f, sprite('33bs', lambda: text_layer('lo que pesa un SOS', 38, 'Medium', MUTED)), 126, 930 + dy, p * (1 - ease(seg(t, 7.0, 7.4))))
    return f


# ───────────────────────────── escena 2 · la red ─────────────────────────────
NODES = {'A': (1010, 390), 'B': (1010, 790), 'C': (1440, 590)}
PHONE_POS, BOARD_POS = (540, 590), (1720, 590)


def node_sprite(label, color, size=150):
    def make():
        im = disc(size, (27, 34, 43, 255), color + (255,), 6)
        d = ImageDraw.Draw(im)
        f = font(int(size * 0.5), 'Heavy')
        w = f.getlength(label)
        d.text(((size - w) / 2, size * 0.18), label, font=f, fill=TEXT + (255,))
        return im
    return sprite(('node', label, color, size), make)


def make_x(size=96, width=14, ss=3):
    im = Image.new('RGBA', (size * ss, size * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    m = size * ss // 5
    d.line((m, m, size * ss - m, size * ss - m), fill=RED + (255,), width=width * ss)
    d.line((size * ss - m, m, m, size * ss - m), fill=RED + (255,), width=width * ss)
    return im.resize((size, size), Image.LANCZOS)


def along(p, q, s):
    return (lerp(p[0], q[0], s), lerp(p[1], q[1], s))


def packet(f, p, q, s, color=AMBER, r=22):
    if not 0 < s < 1: return
    x, y = along(p, q, ease(s))
    paste(f, sprite(('pk', color, r), lambda: disc(r * 2, color + (255,))), x - r, y - r)
    paste(f, sprite(('pkg', color), lambda: glow(color, 130, 0.6)), x - 65, y - 65)


def scene_red(t, d):
    f = background()
    dr = ImageDraw.Draw(f)
    fall, back = 3.4, 5.7  # A cae / A vuelve
    a_alive = not (fall <= t < back)

    def link(p, q, color, w=5, dashed=False):
        if dashed:
            n = int(math.dist(p, q) // 26)
            for i in range(n):
                s0, s1 = i / n, (i + 0.55) / n
                dr.line([along(p, q, s0), along(p, q, s1)], fill=color + (255,), width=w)
        else:
            dr.line([p, q], fill=color + (255,), width=w)

    dim = (58, 70, 86)
    on = ease(seg(t, 0, 0.5))
    # enlaces
    link(PHONE_POS, NODES['A'], BLUE if a_alive else dim, 6, not a_alive)
    link(PHONE_POS, NODES['B'], dim if a_alive else BLUE, 6, True)
    for a, b in [('A', 'B'), ('A', 'C'), ('B', 'C')]:
        alive = (a_alive or 'A' not in (a, b))
        link(NODES[a], NODES[b], (110, 124, 142) if alive else dim, 5, not alive)
    link(NODES['C'], BOARD_POS, GREEN, 6)
    # teléfono y tablero
    ph = sprite('ph_icon', lambda: rounded((150, 250), 30, (27, 34, 43, 255), BLUE + (255,), 5))
    paste(f, ph, PHONE_POS[0] - 75, PHONE_POS[1] - 125, on)
    paste(f, sprite('ph_s', lambda: text_layer('SOS', 44, 'Heavy', RED)), PHONE_POS[0] - 44, PHONE_POS[1] - 30, on)
    bd = sprite('bd_icon', lambda: rounded((250, 170), 22, (27, 34, 43, 255), GREEN + (255,), 5))
    paste(f, bd, BOARD_POS[0] - 125, BOARD_POS[1] - 85, on)
    paste(f, sprite('bd_s', lambda: text_layer('Tablero', 40, 'Heavy', TEXT)), BOARD_POS[0] - 72, BOARD_POS[1] - 28, on)
    # nodos
    colors = {'A': (RED if not a_alive else GREEN), 'B': GREEN, 'C': GREEN}
    for k, (x, y) in NODES.items():
        paste(f, node_sprite(k, colors[k]), x - 75, y - 75, on)
    if not a_alive:  # ✕ sobre A y rótulo
        paste(f, sprite('x', make_x), NODES['A'][0] - 48, NODES['A'][1] - 48, ease(seg(t, fall, fall + 0.2)))
        paste(f, sprite('kill', lambda: text_layer('kill -9', 40, 'Heavy', RED)), NODES['A'][0] - 62, NODES['A'][1] - 140, ease(seg(t, fall, fall + 0.3)))
    # paquetes: 1) teléfono → A → B y C → tablero;  2) con A caído: teléfono → B → C → tablero;  3) al volver A se ponen al día
    packet(f, PHONE_POS, NODES['A'], seg(t, 0.5, 1.3))
    packet(f, NODES['A'], NODES['B'], seg(t, 1.3, 2.0), BLUE)
    packet(f, NODES['A'], NODES['C'], seg(t, 1.3, 2.0), BLUE)
    packet(f, NODES['C'], BOARD_POS, seg(t, 2.0, 2.6), GREEN)
    packet(f, PHONE_POS, NODES['B'], seg(t, 4.0, 4.8))
    packet(f, NODES['B'], NODES['C'], seg(t, 4.8, 5.4), BLUE)
    packet(f, NODES['C'], BOARD_POS, seg(t, 5.4, 5.9), GREEN)
    if t >= back:  # al volver, A se pone al día y los tres muestran la misma huella
        for src in 'BC':
            packet(f, NODES[src], NODES['A'], seg(t, back, back + 0.7), BLUE)
        p = ease(seg(t, back + 0.7, back + 1.2))
        for k, (x, y) in NODES.items():
            paste(f, sprite(('hash', k), lambda: rounded((300, 60), 30, (27, 34, 43, 255), GREEN + (255,), 3)), x - 150, y + 92, p)
            paste(f, sprite(('hasht', k), lambda: text_layer('huella fa1404d6', 30, 'Demi', GREEN)), x - 128, y + 100, p)
    # título
    p, dy = rise(None, t, 0.2)
    paste(f, sprite('t_red', lambda: text_layer('Sin nodo principal.', 84, 'Heavy', TEXT)), 120, 90 + dy, p)
    msg = ('Un nodo cae.', RED, fall + 0.3) if not (t >= back) else ('Vuelve y coincide.', GREEN, back + 0.5)
    if t >= fall + 0.3:
        p, dy = rise(None, t, msg[2] if t < back else back + 0.5, 0.4)
        paste(f, sprite(('m', msg[0]), lambda: text_layer(msg[0], 52, 'Demi', msg[1])), 124, 215 + dy, p)
    return f


# ───────────────────────────── escena 3 · el tablero ─────────────────────────────
def window(img, scale):
    w, h = int(img.width * scale), int(img.height * scale)
    return img.resize((w, h), Image.BILINEAR)


def ken(img, t, a, b, z0=1.0, z1=1.06, cx=0.5, cy=0.5):
    """Plano con un zoom lento sobre `img` (que ya llena el cuadro)."""
    z = lerp(z0, z1, ease(seg(t, a, b)))
    w, h = img.size
    cw, ch = w / z, h / z
    x0, y0 = (w - cw) * cx, (h - ch) * cy
    return img.crop((int(x0), int(y0), int(x0 + cw), int(y0 + ch))).resize((w, h), Image.BILINEAR)


def board_still(name):
    def make():
        im = Image.open(ASSETS / name).convert('RGB')
        card = window(im, 1.0)  # 1440×900
        return card
    return sprite(('board', name), make)


def scene_tablero(t, d):
    f = background()
    shadow = sprite('wsh', lambda: rounded((1500, 940), 24, (0, 0, 0, 170)).filter(ImageFilter.GaussianBlur(28)))
    lista, det = board_still('tablero-lista.png'), board_still('tablero-detalle.png')
    mix = ease(seg(t, 5.0, 5.7))
    base = Image.blend(ken(lista, t, 0, 5.6, 1.0, 1.2, 0.0, 0.62), ken(det, t, 5.0, 11.0, 1.2, 1.28, 1.0, 0.3), mix)
    win = base.convert('RGBA')
    mask = rounded(base.size, 18, (255, 255, 255, 255)).getchannel('A')
    win.putalpha(mask)
    wx, wy = (W - 1440) // 2 + 0, 60
    p = ease(seg(t, 0, 0.6))
    paste(f, shadow, wx - 30, wy - 10, p)
    paste(f, win, wx, wy, p)
    # rótulos
    chips = [
        (1.2, 5.0, 'Lo urgente, primero', RED, 100, 800),
        (2.6, 5.0, 'Llegó desde el teléfono', BLUE, 620, 800),
        (5.6, 11.0, 'Por qué tiene esa prioridad', AMBER, 100, 800),
        (6.8, 11.0, 'Es una propuesta', GREEN, 790, 800),
        (8.4, 11.0, 'Aprueba una persona', GREEN, 1230, 800),
    ]
    for a, b, text, color, x, y in chips:
        pp, dy = rise(None, t, a, 0.45)
        out = 1 - ease(seg(t, b - 0.35, b)) if b < 10.9 else 1.0
        paste(f, chip(text, color, 40), x + (0 if x > 0 else 0), y + dy, pp * out)
    # anillo sobre el reporte que vino del teléfono (4.º/5.º en la lista)
    return f


# ───────────────────────────── escena 4 · el silencio ─────────────────────────────
def find_blobs(im):
    """Centros de las zonas rayadas del mapa (violeta) en el recorte."""
    px = im.convert('RGB').load()
    cell = 10
    gw, gh = im.width // cell, im.height // cell
    grid = [[False] * gw for _ in range(gh)]
    for gy in range(gh):
        for gx in range(gw):
            n = 0
            for y in range(gy * cell, gy * cell + cell, 2):
                for x in range(gx * cell, gx * cell + cell, 2):
                    r, g, b = px[x, y]
                    if b > 150 and r > 90 and g < 150 and b - g > 50: n += 1
            grid[gy][gx] = n >= 2
    seen, blobs = set(), []
    for gy in range(gh):
        for gx in range(gw):
            if grid[gy][gx] and (gx, gy) not in seen:
                stack, cells = [(gx, gy)], []
                seen.add((gx, gy))
                while stack:
                    x, y = stack.pop(); cells.append((x, y))
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < gw and 0 <= ny < gh and grid[ny][nx] and (nx, ny) not in seen:
                            seen.add((nx, ny)); stack.append((nx, ny))
                if len(cells) >= 3:
                    blobs.append((sum(c[0] for c in cells) / len(cells) * cell + cell / 2, sum(c[1] for c in cells) / len(cells) * cell + cell / 2))
    return blobs


# centros de las zonas rayadas en el recorte de 655×680 (medidos sobre la captura)
ZONAS = [(448, 110), (380, 249), (239, 357), (490, 406)]


def scene_silencio(t, d):
    f = background()
    crop = sprite('mapa', lambda: Image.open(ASSETS / 'expo-mapa-silencio-recorte.png').convert('RGB'))
    s = 1.3
    mw, mh = int(crop.width * s), int(crop.height * s)
    mx, my = 1030, 70
    p = ease(seg(t, 0, 0.6))
    img = sprite('mapa_s', lambda: crop.resize((mw, mh), Image.BILINEAR).convert('RGBA'))
    mask = sprite('mapa_m', lambda: rounded((mw, mh), 22, (255, 255, 255, 255)).getchannel('A'))
    framed = img.copy(); framed.putalpha(mask)
    sh = sprite('msh', lambda: rounded((mw + 30, mh + 30), 30, (0, 0, 0, 170)).filter(ImageFilter.GaussianBlur(24)))
    paste(f, sh, mx - 15, my + 5, p)
    paste(f, framed, mx, my, p)
    blobs = ZONAS  # las cuatro zonas en silencio del recorte (dos quedan bajo los marcadores y no se detectan solas)
    pulse = seg(t, 1.2, 7.5)
    for k, (bx, by) in enumerate(blobs):
        on = ease(seg(t, 1.2 + 0.25 * k, 1.8 + 0.25 * k))
        for j in range(2):
            ph = ((t * 0.8) + j * 0.5 + k * 0.17) % 1.0
            size = int(60 + ph * 120)
            paste(f, ring(size, VIOLET, 4), mx + bx * s - size // 2, my + by * s - size // 2, (1 - ph) * 0.9 * on)
    pt, dy = rise(None, t, 0.25)
    paste(f, sprite('t_sil', lambda: text_layer('El silencio\nno es seguridad.', 92, 'Heavy', TEXT, line_gap=1.08)), 110, 150 + dy, pt)
    for k, (text, a) in enumerate([('Zonas que reportaron y callaron.', 2.2), ('Rayadas, bajo los incidentes.', 3.6), ('Una marca, no una conclusión.', 5.0)]):
        pp, dy = rise(None, t, a, 0.5)
        paste(f, sprite(('sl', text), lambda text=text: text_layer(text, 44, 'Medium', MUTED)), 116, 470 + k * 90 + dy, pp)
    return f


# ───────────────────────────── escena 5 · cierre ─────────────────────────────
def scene_cierre(t, d):
    f = background()
    mark = sprite('mark_big', lambda: Image.open(ASSETS / 'sard-mark.png').convert('RGBA').crop((190, 190, 834, 834)).resize((420, 420), Image.LANCZOS))
    p = ease(seg(t, 0.1, 0.8))
    paste(f, mark, 250, 190 + (1 - p) * 20, p)
    paste(f, sprite('sard', lambda: text_layer('SARD', 190, 'Heavy', TEXT)), 760, 190 + (1 - p) * 20, p)
    paste(f, sprite('sub', lambda: text_layer('Reportes que sobreviven.\nDecisiones que se pueden explicar.', 56, 'Demi', MUTED, line_gap=1.2)), 764, 410 + (1 - p) * 20, ease(seg(t, 0.6, 1.3)))
    for k, (big, small, color) in enumerate([('33 B', 'por SOS', BLUE), ('0', 'nodos principales', GREEN), ('2 069', 'pruebas automáticas', AMBER)]):
        pp, dy = rise(None, t, 1.5 + 0.25 * k, 0.5)
        x = 190 + k * 540
        paste(f, sprite(('st_c', k), lambda: rounded((500, 190), 28, (27, 34, 43, 255))), x, 640 + dy, pp)
        paste(f, sprite(('st_b', big), lambda big=big, color=color: text_layer(big, 84, 'Heavy', color)), x + 36, 664 + dy, pp)
        paste(f, sprite(('st_s', small), lambda small=small: text_layer(small, 36, 'Medium', MUTED)), x + 40, 770 + dy, pp)
    paste(f, sprite('credit', lambda: text_layer('Hackathon Expo ASI 2026 · Universidad Nacional de Colombia, Sede Manizales', 36, 'Medium', MUTED)), 190, 900, ease(seg(t, 2.6, 3.2)))
    return f


SCENE_FN = {'hook': scene_hook, 'phone': scene_phone, 'red': scene_red, 'tablero': scene_tablero, 'silencio': scene_silencio, 'cierre': scene_cierre}


# ───────────────────────────── rótulos (subtítulos) ─────────────────────────────
def subtitle(t, tl):
    for sc in tl:
        if sc['voice_start'] - 0.05 <= t <= sc['voice_start'] + sc['voice_len'] + 0.35:
            items = SUBS[sc['line']]
            for i, (text, frac) in enumerate(items):
                a = sc['voice_start'] + frac * sc['voice_len']
                b = sc['voice_start'] + (items[i + 1][1] * sc['voice_len'] if i + 1 < len(items) else sc['voice_len'] + 0.3)
                if a - 0.02 <= t < b + (0.0 if i + 1 < len(items) else 0.0):
                    return text, ease(seg(t, a, a + 0.15)) * (1 - ease(seg(t, b - 0.12, b + (0.0 if i + 1 < len(items) else 0.01))))
    return None


def draw_subtitle(f, text, a):
    lay = sprite(('sub', text), lambda: text_layer(text, 46, 'Demi', TEXT))
    w, h = lay.size
    plate = sprite(('plate', text), lambda: rounded((w + 60, h + 24), 22, (10, 13, 17, 215)))
    x = (W - plate.width) // 2
    paste(f, plate, x, 958, a)
    paste(f, lay, x + 30, 958 + 8, a)


def frame_at(t, tl):
    for sc in tl:
        if sc['start'] <= t < sc['end']:
            local = t - sc['start']
            fr = SCENE_FN[sc['name']](local, sc['end'] - sc['start'])
            alpha = min(ease(seg(local, 0, FADE)), 1 - ease(seg(local, sc['end'] - sc['start'] - FADE, sc['end'] - sc['start'])))
            out = Image.blend(background(), fr, alpha) if alpha < 1 else fr
            s = subtitle(t, tl) if sc['name'] != 'cierre' else None  # en el cierre el lema ya está en la imagen
            if s: draw_subtitle(out, s[0], s[1] * min(1.0, alpha * 2))
            return out.convert('RGB')
    return background().convert('RGB')


# ───────────────────────────── audio: música y efectos ─────────────────────────────
def build_audio(tl, total):
    sr = 44100
    n = int((total + 0.6) * sr)
    voice = [0.0] * n
    for sc in tl:
        s = wav_samples(WORK / 'voz' / f"{sc['line']}.wav")
        off = int(sc['voice_start'] * sr)
        for i, v in enumerate(s):
            if off + i < n: voice[off + i] += v / 32768.0
    peak = max(abs(x) for x in voice) or 1.0
    voice = [x * 0.85 / peak for x in voice]
    music = [0.0] * n
    chords = [(220.0, 261.63, 329.63, 392.0), (174.61, 220.0, 261.63, 329.63), (261.63, 329.63, 392.0, 493.88), (196.0, 246.94, 293.66, 392.0)]
    seg_len = total / len(chords)
    rnd = random.Random(5)
    for i in range(n):
        t = i / sr
        k = min(int(t / seg_len), len(chords) - 1)
        tt = t - k * seg_len
        env = min(1.0, tt / 2.5) * min(1.0, (seg_len - tt) / 2.5 + 0.2)
        v = 0.0
        for j, fr in enumerate(chords[k]):
            v += math.sin(2 * math.pi * fr * t + 0.3 * math.sin(2 * math.pi * 0.17 * t + j)) / (1 + j * 0.6)
        v *= 0.5 + 0.5 * math.sin(2 * math.pi * 0.11 * t + 1.0) * 0.4
        music[i] = v * env * 0.075
    fx = [0.0] * n

    def blip(at, freqs, dur=0.5, amp=0.18, decay=7.0):
        o = int(at * sr)
        for i in range(int(dur * sr)):
            if o + i >= n: break
            tt = i / sr
            fx[o + i] += sum(math.sin(2 * math.pi * f * tt) for f in freqs) / len(freqs) * amp * math.exp(-decay * tt)

    by = {sc['name']: sc for sc in tl}
    blip(by['phone']['start'] + 3.4, (880.0, 1318.5), 0.7)  # toque en SOS
    blip(by['phone']['start'] + 7.0, (659.25, 987.77, 1318.5), 0.9, 0.16, 4.0)  # «Enviado a un nodo»
    blip(by['red']['start'] + 3.4, (82.4, 110.0), 0.9, 0.35, 5.0)  # cae un nodo
    blip(by['red']['start'] + 5.7, (523.25, 783.99), 0.8, 0.16, 5.0)  # vuelve
    blip(by['cierre']['start'] + 0.2, (261.63, 392.0, 523.25), 1.8, 0.14, 1.6)
    left, right = [], []
    for i in range(n):
        t = i / sr
        fade = min(1.0, t / 1.0) * min(1.0, (total + 0.5 - t) / 1.2)
        m = (music[i] + fx[i]) * fade
        v = voice[i]
        left.append(max(-0.98, min(0.98, v + m)))
        right.append(max(-0.98, min(0.98, v + m * 0.93)))
    out = array.array('h')
    for a, b in zip(left, right):
        out.append(int(a * 32767)); out.append(int(b * 32767))
    path = WORK / 'audio.wav'
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr); w.writeframes(out.tobytes())
    subprocess.run(['afconvert', '-f', 'm4af', '-d', 'aac', '-b', '192000', str(path), str(WORK / 'audio.m4a')], check=True)
    return WORK / 'audio.m4a'


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
    frame_at(t, tl).save(out)
    print(out)


def render():
    tl = timeline()
    total = tl[-1]['end']
    if total > 60: sys.exit(f'dura {total:.1f} s: pasa de 60 s')
    exe = encoder()
    fr = WORK / 'frames'
    if fr.exists(): shutil.rmtree(fr)
    fr.mkdir()
    nframes = int(total * FPS)
    for i in range(nframes):
        frame_at(i / FPS, tl).save(fr / f'{i:05d}.png', compress_level=1)
        if i % 150 == 0: print(f'  cuadro {i}/{nframes}', flush=True)
    subprocess.run([str(exe), 'frames', str(fr), str(FPS), str(WORK / 'video-sin-audio.mp4')], check=True)
    audio = build_audio(tl, total)
    subprocess.run([str(exe), 'mux', str(WORK / 'video-sin-audio.mp4'), str(audio), str(WORK / 'sard-video.mp4')], check=True)
    print('listo:', WORK / 'sard-video.mp4', f'({total:.1f} s)')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'prepare': prepare()
    elif cmd == 'still': still(float(sys.argv[2]))
    elif cmd == 'render': render()
    else: sys.exit(__doc__)
