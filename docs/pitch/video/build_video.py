#!/usr/bin/env python3
"""Video de presentación de SARD (≤ 60 s), versión 5: metraje REAL en movimiento (la app en el simulador y el tablero navegado), un sistema de
rejilla de 12 columnas con márgenes de 120 px, cortes al compás, transiciones con desenfoque y un verificador de composición.

No necesita ffmpeg: usa `say`/`afconvert` de macOS, Pillow y el codificador de AVFoundation (`encode.swift`).

    python3 -I docs/pitch/video/build_video.py prepare    # codificador, voz y fotogramas de la app
    python3 -I docs/pitch/video/build_video.py check      # mide la composición de cada escena (centrado, área segura) y falla si algo se sale
    python3 -I docs/pitch/video/build_video.py still 12.5 # un fotograma suelto → work/still.png
    python3 -I docs/pitch/video/build_video.py render     # video + subtítulos + póster → work/salida/

Entradas (no versionadas) en `SARD_VIDEO_WORK`: `phone.mov` (grabación del simulador mientras corre `apps/mobile/integration_test/marketing_flow.dart`)
y `board_frames/` (fotogramas del tablero capturados con Playwright a ≈ 15 fps mientras se navega: lista → detalle → mapa → capa «Silencio»;
`meta.json` lleva los fps). **Voz propia:** `SARD_VOICE_DIR` con `l1`…`l6`. Salida: `*.mp4` NO se versiona; `guion.srt` sí.
"""
import array, json, math, os, pathlib, random, shutil, subprocess, sys, wave
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent
WORK = pathlib.Path(os.environ.get('SARD_VIDEO_WORK', ROOT / 'work'))
ASSETS = ROOT / 'assets'
W, H, FPS = 1920, 1080, 30
M = 120                      # margen de la rejilla (área segura)
COL = (W - 2 * M - 11 * 24) / 12  # 12 columnas con medianil de 24 px
def col(i): return M + i * (COL + 24)  # borde izquierdo de la columna i (0..11)
LEFT = (M, col(6) - 12)      # columna de texto en las escenas partidas: 120 … 948
RIGHT = (col(6) + 12, W - M) # columna de medios: 972 … 1800
BG = (14, 17, 23)
RED, GREEN, BLUE, AMBER, VIOLET = (210, 59, 46), (76, 195, 138), (79, 163, 209), (242, 181, 68), (167, 139, 250)
TEXT, MUTED, SURF, LINE = (238, 241, 245), (169, 180, 194), (27, 34, 43), (44, 54, 68)
FONT_FILE = '/System/Library/Fonts/Avenir Next.ttc'
STYLE = {'Bold': 0, 'Demi': 2, 'Medium': 5, 'Regular': 7, 'Heavy': 8}
VOICE, RATE = 'Paulina', '175'
SR = 44100
BPM = 100
BEAT = 60 / BPM
CHECK = False  # en el verificador: fondo plano, sin partículas ni subtítulos, para medir sólo la composición

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
SCENES = [('hook', 6.6, 'l1'), ('phone', 12.6, 'l2'), ('red', 9.6, 'l3'), ('tablero', 10.2, 'l4'), ('silencio', 8.4, 'l5'), ('cierre', 7.2, 'l6')]
LEAD, TAIL, XFADE = 0.6, 0.9, 0.6
PHONE_START, PHONE_LEN = 16.0, 12.6   # en phone.mov: SOS a los 20,0 s, «Esperando señal» 20–23,5, «Enviado» 23,5, «2–5 personas» 27,5
SOS_BTN = (0.499, 0.229)
BOARD_DETAIL, BOARD_MAP, BOARD_SILENCE = 2.9, 6.9, 10.5  # segundos de board_frames en que ocurre cada cosa

_fonts = {}
def font(size, style='Bold'):
    k = (size, style)
    if k not in _fonts: _fonts[k] = ImageFont.truetype(FONT_FILE, size, index=STYLE[style])
    return _fonts[k]


def clamp(x, a=0.0, b=1.0): return max(a, min(b, x))
def ease(x): x = clamp(x); return x * x * (3 - 2 * x)
def ease_out(x): x = clamp(x); return 1 - (1 - x) ** 3
def ease_in(x): x = clamp(x); return x * x * x
def quint(x): x = clamp(x); return 16 * x ** 5 if x < 0.5 else 1 - (-2 * x + 2) ** 5 / 2
def back_out(x):
    x = clamp(x); c1 = 1.70158; c3 = c1 + 1
    return 1 + c3 * (x - 1) ** 3 + c1 * (x - 1) ** 2
def lerp(a, b, t): return a + (b - a) * t
def seg(t, a, b): return clamp((t - a) / (b - a))


# ───────────────────────────── voz y línea de tiempo ─────────────────────────────
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
        length = math.ceil(max(minimum, LEAD + dur + TAIL) / BEAT - 1e-9) * BEAT
        out.append({'name': name, 'start': t, 'end': t + length, 'line': line, 'voice_start': t + LEAD, 'voice_len': dur})
        t += length - XFADE
    return out


# ───────────────────────────── dibujo ─────────────────────────────
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


def text_layer(text, size, style='Bold', color=TEXT, line_gap=1.12, align='left', width=None):
    f = font(size, style)
    lines = text.split('\n')
    widths = [int(f.getlength(l)) for l in lines]
    w = width or max(widths)
    lh = int(size * line_gap)
    im = Image.new('RGBA', (w + 8, lh * len(lines) + 12), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for i, l in enumerate(lines):
        x = 4 if align == 'left' else (w - widths[i]) // 2 + 4
        d.text((x, 2 + i * lh), l, font=f, fill=color + (255,))
    return im


def text_w(text, size, style='Bold'): return font(size, style).getlength(text)


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
        base.alpha_composite(l, (x, y)); return
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(base.width, x + l.width), min(base.height, y + l.height)
    if x1 > x0 and y1 > y0: base.alpha_composite(l.crop((x0 - x, y0 - y, x1 - x, y1 - y)), (x0, y0))


def reveal(base, layer, x, y, p, a=1.0, direction='right'):
    """Revelado con máscara: el elemento aparece barrido de izquierda a derecha (o de abajo arriba)."""
    p = clamp(p)
    if p <= 0: return
    if p >= 1: paste(base, layer, x, y, a); return
    if direction == 'right':
        w = max(1, int(layer.width * p)); paste(base, layer.crop((0, 0, w, layer.height)), x, y, a)
    else:
        h = max(1, int(layer.height * p)); paste(base, layer.crop((0, layer.height - h, layer.width, layer.height)), x, y + layer.height - h, a)


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


def zoom_frame(img, z, cx=0.5, cy=0.5):
    if z <= 1.0001 and cx == 0.5 and cy == 0.5: return img
    w, h = img.size
    cw, ch = w / z, h / z
    x0, y0 = (w - cw) * cx, (h - ch) * cy
    return img.crop((int(x0), int(y0), int(x0 + cw), int(y0 + ch))).resize((w, h), Image.BILINEAR)


def slide_blur(img, dx, blur):
    if abs(dx) >= 1: img = img.transform(img.size, Image.AFFINE, (1, 0, -dx, 0, 1, 0), fillcolor=(8, 10, 13))
    if blur >= 0.4: img = img.filter(ImageFilter.GaussianBlur(blur))
    return img


def kinetic(f, text, x, y, size, style, color, t, start, stagger=0.08, dur=0.5, dy=40, a=1.0):
    fnt = font(size, style)
    cx = x
    for i, w in enumerate(text.split(' ')):
        p, d = rise(t, start + i * stagger, dur, dy)
        paste(f, sprite(('kw', w, size, style, color), lambda w=w: text_layer(w, size, style, color)), cx, y + d, p * a)
        cx += fnt.getlength(w + ' ')


def centered_text(f, text, y, size, style, color, t, start, kin=True, **kw):
    x = (W - text_w(text, size, style)) / 2
    if kin: kinetic(f, text, x, y, size, style, color, t, start, **kw)
    else:
        p, d = rise(t, start, 0.5, 30)
        paste(f, sprite(('ct', text, size, style, color), lambda: text_layer(text, size, style, color)), x, y + d, p)


def rule(f, x0, x1, y, t, start, color=LINE, width=2, dur=0.6):
    """Una línea horizontal que se dibuja de izquierda a derecha."""
    p = quint(seg(t, start, start + dur))
    if p <= 0: return
    ImageDraw.Draw(f).line((x0, y, x0 + (x1 - x0) * p, y), fill=color + (255,), width=width)


# ───────────────────────────── fondo ─────────────────────────────
PARTICLES = [(random.Random(11 + i).random(), random.Random(23 + i).random(), 2 + (i % 3), 0.10 + 0.22 * random.Random(37 + i).random(), 5 + 12 * random.Random(41 + i).random()) for i in range(56)]


def _make_bg():
    """Degradado radial: azul profundo al centro, negro en los bordes; y una luz diagonal suave."""
    im = Image.new('RGB', (W, H), (8, 10, 13))
    core = Image.new('RGB', (W, H), (22, 27, 36))
    v = Image.new('L', (W, H), 0)
    ImageDraw.Draw(v).ellipse((-200, -300, W + 200, H + 300), fill=255)
    v = v.filter(ImageFilter.GaussianBlur(260))
    im = Image.composite(core, im, v)
    streak = Image.new('L', (W, H), 0)
    ImageDraw.Draw(streak).polygon([(600, -200), (1500, -200), (900, 1300), (0, 1300)], fill=255)
    streak = streak.filter(ImageFilter.GaussianBlur(180))
    im = Image.composite(Image.new('RGB', (W, H), (30, 36, 48)), im, streak.point(lambda v: int(v * 0.45)))
    return im.convert('RGBA')


def background(tg=0.0, accent=RED, energy=1.0):
    if CHECK: return Image.new('RGBA', (W, H), BG + (255,))
    f = sprite('bg', _make_bg).copy()
    a1 = sprite(('aur', accent), lambda: glow(accent, 1200, 0.20))
    a2 = sprite(('aur', BLUE), lambda: glow(BLUE, 1000, 0.14))
    paste(f, a1, 1150 + 160 * math.sin(tg * 0.21) - 600, 260 + 120 * math.cos(tg * 0.17) - 600, 0.9)
    paste(f, a2, 450 + 140 * math.cos(tg * 0.15) - 500, 760 + 90 * math.sin(tg * 0.19) - 500, 0.9)
    for px, py, sz, al, speed in PARTICLES:
        x = (px * W + 25 * math.sin(tg * 0.3 + py * 9)) % W
        y = (py * H - tg * speed * energy) % H
        paste(f, sprite(('part', sz), lambda sz=sz: disc(sz * 2, (238, 241, 245, 255))), x, y, al * (0.6 + 0.4 * math.sin(tg * 1.7 + px * 20)))
    return f


# ───────────────────────────── piezas de interfaz ─────────────────────────────
def chip(text, color, size=36):
    def make():
        f = font(size, 'Demi')
        tw = int(f.getlength(text))
        im = rounded((tw + 52, size + 36), (size + 36) // 2, (27, 34, 43, 242), color + (255,), 3)
        ImageDraw.Draw(im).text((26, 14), text, font=f, fill=TEXT + (255,))
        return im
    return sprite(('chip', text, color, size), make)


def mark(size):
    return sprite(('mark', size), lambda: Image.open(ASSETS / 'sard-mark.png').convert('RGBA').crop((190, 190, 834, 834)).resize((size, size), Image.LANCZOS))


def header(f, eyebrow_text, t, start=0.2):
    """Cabecera común de las escenas de producto: marca a la izquierda, antetítulo a la derecha, sobre una línea fina. Simétrica respecto a la rejilla."""
    p = ease(seg(t, start, start + 0.5))
    paste(f, mark(44), M, 52, p)
    paste(f, sprite('brand_t', lambda: text_layer('SARD', 30, 'Heavy', TEXT)), M + 56, 56, p)
    lay = sprite(('eb', eyebrow_text), lambda: text_layer(eyebrow_text, 24, 'Demi', MUTED))
    paste(f, lay, W - M - lay.width, 62, p)
    rule(f, M, W - M, 112, t, start + 0.1, LINE, 1, 0.8)


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
    paste(f, text_layer(f'{value:,}'.replace(',', ' ') + suffix, size, 'Heavy', color), x, y, a)


def device_frame(screen, w, h, radius, bezel=14, color=(12, 15, 20, 255), edge=(70, 82, 100, 255)):
    """Marco de dispositivo con reflejo diagonal suave."""
    fr = rounded((w + 2 * bezel, h + 2 * bezel), radius + bezel, color, edge, 2)
    scr = screen.resize((w, h), Image.LANCZOS).convert('RGBA')
    scr.putalpha(rounded((w, h), radius, (255, 255, 255, 255)).getchannel('A'))
    fr.alpha_composite(scr, (bezel, bezel))
    shine = Image.new('L', (w, h), 0)
    ImageDraw.Draw(shine).polygon([(0, 0), (int(w * 0.55), 0), (0, int(h * 0.42))], fill=255)
    shine = shine.filter(ImageFilter.GaussianBlur(40)).point(lambda v: int(v * 0.07))
    gl = Image.new('RGBA', (w, h), (255, 255, 255, 0)); gl.putalpha(shine)
    fr.alpha_composite(gl, (bezel, bezel))
    return fr


_board_cache = {}
def board_frame(tb):
    """Fotograma del tablero navegado en el segundo `tb` de la captura (≈ 15 fps)."""
    meta = sprite('board_meta', lambda: json.loads((WORK / 'board_frames' / 'meta.json').read_text()))
    i = int(clamp(tb * meta['fps'], 0, meta['frames'] - 1))
    if i not in _board_cache:
        if len(_board_cache) > 40: _board_cache.clear()
        _board_cache[i] = Image.open(WORK / 'board_frames' / f'{i:05d}.png').convert('RGB')
    return _board_cache[i]


def phone_frame_image(i):
    src = WORK / 'phone_frames' / f'{i:05d}.png'
    if not src.exists(): src = sorted((WORK / 'phone_frames').glob('*.png'))[-1]
    return Image.open(src).convert('RGB')

# ───────────────────────────── escena 0 · gancho ─────────────────────────────
def pulse_line(t, x, env_t):
    """Línea de pulso a lo ancho: temblor con el sismo, plano con el apagón y un latido (el SOS) que cruza."""
    env = math.exp(-(env_t - 0.3) * 0.9) * min(1.0, (env_t - 0.3) / 0.12) if 0.3 <= env_t < 1.25 else 0.0
    y = env * 70 * (math.sin(x * 0.045 + env_t * 31) * 0.6 + math.sin(x * 0.11 - env_t * 47) * 0.3 + math.sin(x * 0.021 + env_t * 13) * 0.4)
    if env_t >= 2.5:
        c = (env_t - 2.5) * 950
        y += -150 * math.exp(-((x - c) / 24) ** 2) + 60 * math.exp(-((x - c + 56) / 20) ** 2)
    return y


def scene_hook(t, tg):
    f = background(tg, RED, 1.6)
    # el pulso cruza el centro geométrico de la pantalla, detrás del titular
    base_y = 564
    pts = [(x, base_y + pulse_line(t, x - M, t)) for x in range(M, W - M + 1, 8)]
    lay = Image.new('RGBA', (W, 420), (0, 0, 0, 0))
    ImageDraw.Draw(lay).line([(x, y - (base_y - 210)) for x, y in pts], fill=RED + (255,), width=4, joint='curve')
    on = ease(seg(t, 0.1, 0.5))
    paste(f, lay.filter(ImageFilter.GaussianBlur(12)), 0, base_y - 210, 0.8 * on)
    paste(f, lay, 0, base_y - 210, 0.9 * on)
    # marca arriba, centrada; titular centrado bajo el pulso; promesa debajo
    sc = 0.5 + 0.5 * back_out(seg(t, 0.1, 0.9))
    m = mark(int(200 * sc)) if sc > 0.02 else None
    if m: paste(f, m, 960 - m.width // 2, 274 - m.height // 2, ease(seg(t, 0.1, 0.5)))
    fnt = font(136, 'Heavy')
    line = 'Sismo.  Apagón.'
    x0 = (W - fnt.getlength(line)) / 2
    kinetic(f, 'Sismo.', x0, 624, 136, 'Heavy', TEXT, t, 0.35, dur=0.45, dy=60)
    kinetic(f, 'Apagón.', x0 + fnt.getlength('Sismo.  '), 624, 136, 'Heavy', TEXT, t, 1.2, dur=0.45, dy=60)
    centered_text(f, 'Un SOS que tiene que llegar.', 799, 64, 'Heavy', RED, t, 2.55, stagger=0.08)
    rule(f, 760, 1160, 904, t, 3.2, RED, 3, 0.8)
    if 0.3 <= t < 1.25:
        amp = 9 * math.exp(-(t - 0.3) * 2.2)
        rnd = random.Random(int(t * 60))
        f = zoom_frame(f, 1.03, 0.5 + rnd.uniform(-amp, amp) / 100, 0.5 + rnd.uniform(-amp, amp) / 100)
    dark = ease(seg(t, 1.2, 1.3)) * (1 - ease(seg(t, 1.38, 1.9)))
    if dark > 0: f = Image.blend(f, Image.new('RGBA', (W, H), (4, 5, 7, 255)), 0.92 * dark)
    return f


# ───────────────────────────── escena 1 · la app (metraje real) ─────────────────────────────
SC_W, SC_H = 350, 760  # pantalla del teléfono (proporción 1206 × 2622)
PH_BEZEL = 14
PH_W, PH_H = SC_W + 2 * PH_BEZEL, SC_H + 2 * PH_BEZEL
PH_X = (RIGHT[0] + RIGHT[1]) / 2 - PH_W / 2   # centrado en la columna de medios
PH_Y = (H - PH_H) / 2                          # centrado en alto
STEPS = [
    (4.0, '01', 'Un toque', 'Se guarda al instante.', RED),
    (4.9, '02', 'Sin red, no se pierde', 'Queda en el teléfono: «Esperando señal».', AMBER),
    (7.6, '03', 'Sale sola al volver la señal', '«Enviado a un nodo».', GREEN),
    (11.5, '04', 'Los detalles, después', 'Cuántas personas, una frase: el mismo reporte.', BLUE),
]


def scene_phone(t, tg):
    f = background(tg, RED, 1.0)
    header(f, '01 — EL REPORTE', t)
    enter = quint(seg(t, 0.0, 1.0))
    px = lerp(PH_X + 360, PH_X, enter)
    py = PH_Y + 6 * math.sin(t * 1.1)
    on = ease(seg(t, 0, 0.5))
    paste(f, sprite('pgl', lambda: glow(RED, 1000, 0.5)), px + PH_W / 2 - 500, py + PH_H / 2 - 500, 0.25 * on + 0.55 * ease_out(seg(t, 3.9, 4.3)) * (1 - ease(seg(t, 4.3, 6.5))))
    paste(f, sprite('pshadow', lambda: rounded((PH_W + 60, PH_H + 60), 90, (0, 0, 0, 160)).filter(ImageFilter.GaussianBlur(30))), px - 30, py + 18, on)
    idx = int(clamp(t, 0, PHONE_LEN - 0.034) * FPS)
    dev = device_frame(phone_frame_image(idx), SC_W, SC_H, 54, PH_BEZEL)
    paste(f, dev, px, py, on)
    sx, sy = px + PH_BEZEL, py + PH_BEZEL
    pulse_ring(f, sx + SOS_BTN[0] * SC_W, sy + SOS_BTN[1] * SC_H, seg(t, 3.95, 4.75), RED, 200, 6)
    # columna de texto: una línea de tiempo vertical con cuatro pasos, centrada en alto
    tl_x = M + 22
    block_h = 4 * 150
    y0 = (H - block_h) / 2 + 20
    rule_p = quint(seg(t, 0.6, 1.4))
    ImageDraw.Draw(f).line((tl_x, y0, tl_x, y0 + (block_h - 60) * rule_p), fill=LINE + (255,), width=2)
    for k, (a, num, title, sub, color) in enumerate(STEPS):
        y = y0 + k * 150
        p = ease_out(seg(t, a, a + 0.5))
        if p <= 0: continue
        d = sprite(('stepdot', color), lambda color=color: disc(44, SURF + (255,), color + (255,), 4))
        d2 = d.resize((max(2, int(44 * (0.5 + 0.5 * back_out(seg(t, a, a + 0.5))))),) * 2, Image.LANCZOS)
        paste(f, d2, tl_x - d2.width / 2, y + 22 - d2.height / 2, p)
        paste(f, sprite(('stepnum', num, color), lambda num=num, color=color: text_layer(num, 22, 'Heavy', color)), tl_x + 44, y - 6, p)
        reveal(f, sprite(('steptitle', title), lambda title=title: text_layer(title, 48, 'Heavy', TEXT)), tl_x + 44, y + 14, quint(seg(t, a + 0.05, a + 0.55)))
        paste(f, sprite(('stepsub', sub), lambda sub=sub: text_layer(sub, 28, 'Medium', MUTED)), tl_x + 46, y + 76, ease(seg(t, a + 0.35, a + 0.7)))
    # 239 B → 33 B
    p = ease(seg(t, 5.3, 5.8)) * (1 - ease(seg(t, 7.4, 7.8)))
    if p > 0:
        v = int(round(lerp(239, 33, ease(seg(t, 5.4, 6.3)))))
        lay = text_layer(f'{v} B', 64, 'Heavy', BLUE if v == 33 else MUTED)
        paste(f, chip(' ', BLUE, 1), 0, 0, 0)  # (mantiene el caché caliente)
        paste(f, lay, LEFT[1] - lay.width - 10, y0 + 150 * 1 + 10, p)
    return f


# ───────────────────────────── escena 2 · la red ─────────────────────────────
NY = 600
NODES = {'A': (720, NY - 130), 'B': (720, NY + 130), 'C': (1100, NY)}
PHONE_POS, BOARD_POS = (330, NY), (1590, NY)


def node_sprite(label, color, size=140):
    def make():
        im = disc(size, SURF + (255,), color + (255,), 6)
        d = ImageDraw.Draw(im)
        f = font(int(size * 0.48), 'Heavy')
        d.text(((size - f.getlength(label)) / 2, size * 0.2), label, font=f, fill=TEXT + (255,))
        return im
    return sprite(('node', label, color, size), make)


def along(p, q, s): return (lerp(p[0], q[0], s), lerp(p[1], q[1], s))


def packet(f, p, q, s, color=AMBER, r=20):
    if not 0 < s < 1: return
    for k, a in ((3, 0.18), (2, 0.3), (1, 0.5)):
        x, y = along(p, q, ease(max(0.0, s - 0.035 * k)))
        paste(f, sprite(('pkt', color, r), lambda: disc(int(r * 1.5), color + (255,))), x - r * 0.75, y - r * 0.75, a)
    x, y = along(p, q, ease(s))
    paste(f, sprite(('pk', color, r), lambda: disc(r * 2, color + (255,))), x - r, y - r)
    paste(f, sprite(('pkg', color), lambda: glow(color, 120, 0.6)), x - 60, y - 60)


def scene_red(t, tg):
    f = background(tg, BLUE, 1.2)
    dr = ImageDraw.Draw(f)
    fall, back = 3.4, 5.7
    a_alive = not (fall <= t < back)
    dim = (52, 62, 78)
    # el diagrama: 5 elementos centrados en el ancho útil (330 … 1590 → centro 960)
    def link(p, q, color, w=5, dashed=False):
        if dashed:
            n = int(math.dist(p, q) // 26)
            for i in range(n): dr.line([along(p, q, i / n), along(p, q, (i + 0.55) / n)], fill=color + (255,), width=w)
        else: dr.line([p, q], fill=color + (255,), width=w)
    on = ease(seg(t, 0, 0.5))
    link(PHONE_POS, NODES['A'], BLUE if a_alive else dim, 6, not a_alive)
    link(PHONE_POS, NODES['B'], dim if a_alive else BLUE, 6, True)
    for a, b in [('A', 'B'), ('A', 'C'), ('B', 'C')]:
        alive = a_alive or 'A' not in (a, b)
        link(NODES[a], NODES[b], (110, 124, 142) if alive else dim, 5, not alive)
    link(NODES['C'], BOARD_POS, GREEN, 6)
    paste(f, sprite('ph_icon', lambda: rounded((140, 240), 30, SURF + (255,), BLUE + (255,), 5)), PHONE_POS[0] - 70, PHONE_POS[1] - 120, on)
    paste(f, sprite('ph_s', lambda: text_layer('SOS', 40, 'Heavy', RED)), PHONE_POS[0] - text_w('SOS', 40, 'Heavy') / 2 - 4, PHONE_POS[1] - 28, on)
    paste(f, sprite('bd_icon', lambda: rounded((240, 160), 22, SURF + (255,), GREEN + (255,), 5)), BOARD_POS[0] - 120, BOARD_POS[1] - 80, on)
    paste(f, sprite('bd_s', lambda: text_layer('Tablero', 36, 'Heavy', TEXT)), BOARD_POS[0] - text_w('Tablero', 36, 'Heavy') / 2 - 4, BOARD_POS[1] - 24, on)
    colors = {'A': RED if not a_alive else GREEN, 'B': GREEN, 'C': GREEN}
    for i, (k, (x, y)) in enumerate(NODES.items()):
        beat = 1 + 0.04 * max(0.0, math.sin((t - i * 0.2) * 2 * math.pi / BEAT)) ** 6
        ns = node_sprite(k, colors[k])
        if beat > 1.001: ns = ns.resize((int(140 * beat), int(140 * beat)), Image.LANCZOS)
        paste(f, ns, x - ns.width // 2, y - ns.height // 2, on * (0.6 + 0.4 * back_out(seg(t, 0.1 + i * 0.12, 0.7 + i * 0.12))))
    if not a_alive:
        paste(f, sprite('x', make_x), NODES['A'][0] - 48, NODES['A'][1] - 48, ease(seg(t, fall, fall + 0.2)))
        lay = sprite('kill', lambda: text_layer('kill -9', 36, 'Heavy', RED))
        paste(f, lay, NODES['A'][0] - lay.width / 2, NODES['A'][1] - 130, ease(seg(t, fall, fall + 0.3)))
        pulse_ring(f, *NODES['A'], seg(t, fall, fall + 0.9), RED, 300, 6)
    packet(f, PHONE_POS, NODES['A'], seg(t, 0.5, 1.3)); packet(f, NODES['A'], NODES['B'], seg(t, 1.3, 2.0), BLUE); packet(f, NODES['A'], NODES['C'], seg(t, 1.3, 2.0), BLUE)
    packet(f, NODES['C'], BOARD_POS, seg(t, 2.0, 2.6), GREEN); packet(f, PHONE_POS, NODES['B'], seg(t, 4.0, 4.8)); packet(f, NODES['B'], NODES['C'], seg(t, 4.8, 5.4), BLUE); packet(f, NODES['C'], BOARD_POS, seg(t, 5.4, 5.9), GREEN)
    for at, pos, colr in [(1.3, NODES['A'], BLUE), (2.0, NODES['B'], BLUE), (2.0, NODES['C'], BLUE), (2.6, BOARD_POS, GREEN), (4.8, NODES['B'], BLUE), (5.4, NODES['C'], BLUE), (5.9, BOARD_POS, GREEN)]:
        pulse_ring(f, pos[0], pos[1], seg(t, at, at + 0.7), colr, 190, 4)
    if t >= back:
        for src in 'BC': packet(f, NODES[src], NODES['A'], seg(t, back, back + 0.7), BLUE)
        pulse_ring(f, *NODES['A'], seg(t, back + 0.7, back + 1.5), GREEN, 260, 5)
        p = ease(seg(t, back + 0.7, back + 1.2))
        for k, (x, y) in NODES.items():
            paste(f, sprite('hash', lambda: rounded((280, 54), 27, SURF + (255,), GREEN + (255,), 3)), x - 140, y + 86, p)
            lay = sprite('hasht', lambda: text_layer('huella fa1404d6', 26, 'Demi', GREEN))
            paste(f, lay, x - lay.width / 2, y + 94, p)
    centered_text(f, 'Sin nodo principal.', 170, 76, 'Heavy', TEXT, t, 0.2)
    if t >= fall + 0.3:
        msg = ('Un nodo cae.', RED, fall + 0.3) if t < back else ('Vuelve y coincide.', GREEN, back + 0.5)
        centered_text(f, msg[0], 268, 44, 'Demi', msg[1], t, msg[2], stagger=0.07, dur=0.35, dy=20)
    z = 1.0 + 0.035 * ease(seg(t, 0, 9)) + 0.03 * (1 - ease(seg(t, fall, fall + 0.5))) * (t >= fall)
    f = zoom_frame(f, z, 0.5, 0.55)
    header(f, '02 — LA RED', t)  # la cabecera no se mueve con la cámara
    return f


# ───────────────────────────── escena 3 · el tablero (metraje real) ─────────────────────────────
WIN_W, WIN_H, BAR = 1440, 900, 40
WIN_S = 0.80                       # la ventana se muestra al 80 % (1152 × 720 + barra) para respetar la rejilla
WIN_X = (W - WIN_W * WIN_S) / 2
WIN_Y = 120


def window_bar():
    def make():
        im = rounded((WIN_W, BAR + 30), 16, (27, 34, 43, 255))
        d = ImageDraw.Draw(im)
        for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]): d.ellipse((22 + i * 28, 13, 22 + i * 28 + 14, 27), fill=c)
        im.alpha_composite(rounded((420, 26), 13, (18, 22, 28, 255)), (int(WIN_W / 2 - 210), 7))
        d.text((WIN_W / 2 - 90, 9), 'localhost:8081 · SARD', font=font(18, 'Medium'), fill=MUTED + (255,))
        return im.crop((0, 0, WIN_W, BAR))
    return sprite('wbar', make)


def browser(f, content, x, y, a=1.0, scale=1.0):
    """Ventana de navegador con barra, sombra y esquinas; `content` es una imagen 1440 × 900."""
    w, h = int(WIN_W * scale), int(WIN_H * scale)
    full = Image.new('RGBA', (w, int(BAR * scale) + h), (0, 0, 0, 0))
    full.alpha_composite(window_bar().resize((w, int(BAR * scale)), Image.LANCZOS) if scale != 1.0 else window_bar(), (0, 0))
    full.alpha_composite(content.resize((w, h), Image.BILINEAR).convert('RGBA') if content.size != (w, h) else content.convert('RGBA'), (0, int(BAR * scale)))
    full.putalpha(sprite(('wmask', w, h), lambda: rounded((w, int(BAR * scale) + h), 16, (255, 255, 255, 255)).getchannel('A')))
    paste(f, sprite(('wsh', w, h), lambda: rounded((w + 60, int(BAR * scale) + h + 60), 30, (0, 0, 0, 170)).filter(ImageFilter.GaussianBlur(28))), x - 30, y - 10, a)
    paste(f, full, x, y, a)


def scene_tablero(t, tg):
    f = background(tg, BLUE, 0.8)
    # metraje: lista → clic → detalle (segundos 0 … 7 de la captura), acelerado 1,15× para que el clic caiga sobre «explica por qué»
    tb = clamp(t * 1.15, 0, 9.0)
    content = board_frame(tb)
    on = ease(seg(t, 0, 0.6))
    wy = WIN_Y + (1 - quint(seg(t, 0, 1.0))) * 120
    # zoom muy lento hacia la columna del detalle cuando se abre
    z = lerp(1.0, 1.12, ease(seg(t, BOARD_DETAIL / 1.15 + 0.3, 10.0)))
    content = zoom_frame(content, z, 1.0, 0.25)
    browser(f, content, WIN_X, wy, on, WIN_S)
    # cursor real: viaja hasta el primer P1 y hace clic justo cuando el tablero abre el detalle
    click_t = BOARD_DETAIL / 1.15
    tx, ty = WIN_X + 330 * WIN_S, wy + (BAR + 322) * WIN_S
    pc = ease(seg(t, click_t - 1.4, click_t - 0.1))
    cxp, cyp = lerp(WIN_X + 1000 * WIN_S, tx, pc), lerp(wy + (BAR + 640) * WIN_S, ty, pc) + 40 * math.sin(pc * math.pi)
    if t < click_t + 1.2:
        paste(f, cursor_sprite(), cxp, cyp, ease(seg(t, click_t - 1.7, click_t - 1.3)) * (1 - ease(seg(t, click_t + 0.7, click_t + 1.2))))
        pulse_ring(f, tx, ty, seg(t, click_t, click_t + 0.7), BLUE, 140, 4)
    # rótulos en una fila centrada bajo la ventana
    groups = [[(0.9, 'Lo urgente, primero', RED), (1.7, 'Llegó desde el teléfono', BLUE)], [(click_t + 1.0, 'Explica el porqué', AMBER), (click_t + 2.4, 'Propone, no ejecuta', GREEN), (click_t + 3.8, 'Decide una persona', GREEN)]]
    for gi, group in enumerate(groups):
        out = (1 - ease(seg(t, click_t - 0.45, click_t - 0.1))) if gi == 0 else 1.0
        if out <= 0: continue
        chips_ = [chip(text, color, 34) for _, text, color in group]
        total_w = sum(c.width for c in chips_) + 24 * (len(chips_) - 1)
        x = (W - total_w) / 2
        for (a_, text, color), c in zip(group, chips_):
            pp, dy = rise(t, a_, 0.45, 30)
            paste(f, c, x, H - 130 - c.height + dy, pp * out)
            x += c.width + 24
    return f


# ───────────────────────────── escena 4 · el mapa (metraje real) ─────────────────────────────
ZONAS = [(448, 325), (380, 464), (239, 572), (490, 621)]  # centros de las zonas rayadas en la captura de 1440 × 900 (mapa en la columna izquierda)


def scene_silencio(t, tg):
    f = background(tg, VIOLET, 0.6)
    # metraje: mapa → capa «Silencio» (segundos 6,9 … 16 de la captura); se recorta a la columna del mapa (0 … 655 × 215 … 895)
    tb = clamp(BOARD_MAP + 0.4 + t, 0, 15.9)
    crop = zoom_frame(board_frame(tb).crop((0, 215, 655, 895)), 1.0 + 0.05 * ease(seg(t, 0, 8)), 0.5, 0.5)  # la cámara se mueve dentro del marco
    s = 1.05
    mw, mh = int(655 * s), int(680 * s)
    mx = (RIGHT[0] + RIGHT[1]) / 2 - mw / 2 + (1 - quint(seg(t, 0, 1.0))) * 260
    my = (H - mh) / 2
    on = ease(seg(t, 0, 0.6))
    img = crop.resize((mw, mh), Image.BILINEAR)
    dev = device_frame(img, mw, mh, 18, 10, (20, 25, 33, 255), (60, 72, 90, 255))
    paste(f, sprite(('msh', mw), lambda: rounded((mw + 50, mh + 50), 30, (0, 0, 0, 170)).filter(ImageFilter.GaussianBlur(26))), mx - 25, my + 6, on)
    paste(f, dev, mx - 10, my - 10, on)
    # cuando la capa se enciende, las zonas rayadas laten
    since = t - (BOARD_SILENCE - BOARD_MAP - 0.4)
    for k, (bx, by) in enumerate(ZONAS):
        onz = ease(seg(since, 0.2 + 0.2 * k, 0.8 + 0.2 * k))
        for j in range(2):
            ph = ((t * 0.8) + j * 0.5 + k * 0.17) % 1.0
            size = int(50 + ph * 110)
            paste(f, ring(size, VIOLET, 4), mx + bx * s - size // 2, my + (by - 215) * s - size // 2, (1 - ph) * 0.9 * onz)
    # texto: bloque centrado en alto en la columna izquierda
    block_y = (H - 420) / 2
    kinetic(f, 'El silencio', M, block_y, 84, 'Heavy', TEXT, t, 0.25)
    kinetic(f, 'no es seguridad.', M, block_y + 96, 84, 'Heavy', TEXT, t, 0.45)
    rule(f, M, M + 360, block_y + 215, t, 1.0, VIOLET, 3)
    for k, (text, a) in enumerate([('Zonas que reportaron y callaron.', 2.2), ('Rayadas, bajo los incidentes.', 3.6), ('Una marca, no una conclusión.', 5.0)]):
        reveal(f, sprite(('sl', text), lambda text=text: text_layer(text, 36, 'Medium', MUTED)), M, block_y + 250 + k * 56, quint(seg(t, a, a + 0.6)))
    header(f, '03 — EL MAPA', t)
    return f


# ───────────────────────────── escena 5 · cierre ─────────────────────────────
def scene_cierre(t, tg):
    f = background(tg, RED, 0.8)
    p = ease_out(seg(t, 0.1, 0.9))
    # fila centrada: marca + «SARD»
    wm = text_w('SARD', 170, 'Heavy')
    row_w = 220 + 48 + wm
    x0 = (W - row_w) / 2
    cy = 282
    sc = 0.5 + 0.5 * back_out(seg(t, 0.1, 0.9))
    m = mark(max(2, int(220 * sc)))
    for k in range(3):
        ph = ((t * 0.4) + k / 3) % 1.0
        size = int(240 + ph * 600)
        paste(f, ring(size, RED, 4), x0 + 110 - size // 2, cy - size // 2, (1 - ph) ** 1.6 * 0.3 * p)
    pulse_ring(f, x0 + 110, cy, seg(t, 0.15, 1.1), RED, 900, 6)
    paste(f, m, x0 + 110 - m.width / 2, cy - m.height / 2, p)
    kinetic(f, 'SARD', x0 + 268, cy - 110, 170, 'Heavy', TEXT, t, 0.3, dur=0.6, dy=60)
    centered_text(f, 'Reportes que sobreviven. Decisiones que se pueden explicar.', 472, 46, 'Demi', MUTED, t, 0.8, stagger=0.05)
    rule(f, 760, 1160, 564, t, 1.3, LINE, 2)
    cards = [(33, ' B', 'por SOS', BLUE), (0, '', 'nodos principales', GREEN), (2069, '', 'pruebas automáticas', AMBER)]
    cw, gap = 420, 36
    cx0 = (W - (cw * 3 + gap * 2)) / 2
    for k, (target, suffix, small, color) in enumerate(cards):
        a0 = 1.5 + 0.2 * k
        pp, dy = rise(t, a0, 0.5, 40)
        x = cx0 + k * (cw + gap)
        paste(f, sprite(('st_c', cw), lambda: rounded((cw, 160), 24, SURF + (255,))), x, 612 + dy, pp)
        v = int(round(target * ease_out(seg(t, a0 + 0.2, a0 + 1.3)))) if target else 0
        counter(f, v, suffix, x + 30, 628 + dy, 66, color, pp)
        paste(f, sprite(('st_s', small), lambda small=small: text_layer(small, 28, 'Medium', MUTED)), x + 34, 716 + dy, pp)
    centered_text(f, 'github.com/Bdavid117/hackathon-asi  ·  se reproduce con un comando', 832, 30, 'Demi', TEXT, t, 2.6, kin=False)
    centered_text(f, 'Hackathon Expo ASI 2026 · Universidad Nacional de Colombia, Sede Manizales', 878, 24, 'Medium', MUTED, t, 2.9, kin=False)
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
    lay = sprite(('sub', text), lambda: text_layer(text, 40, 'Demi', TEXT))
    plate = sprite(('plate', text), lambda: rounded((lay.width + 56, lay.height + 20), 20, (8, 10, 13, 215)))
    x = (W - plate.width) // 2
    paste(f, plate, x, H - 112, a)
    paste(f, lay, x + 28, H - 112 + 8, a)


def frame_at(t, tl, cues):
    active = [(i, sc) for i, sc in enumerate(tl) if sc['start'] <= t < sc['end']]
    total = tl[-1]['end']
    if not active: return background(t).convert('RGB')
    n = len(tl)
    frames = []
    for i, sc in active:
        local = t - sc['start']
        length = sc['end'] - sc['start']
        fr = SCENE_FN[sc['name']](local, t)
        win = quint(seg(local, 0, XFADE)) if i > 0 else ease(seg(local, 0, 0.5))
        wout = 1 - quint(seg(local, length - XFADE, length)) if i < n - 1 else 1 - ease(seg(local, length - 0.9, length))
        if i > 0 and not CHECK: fr = zoom_frame(fr, 1.0 + 0.05 * (1 - quint(seg(local, 0, 1.1))))
        frames.append((fr.convert('RGB'), win, wout))
    if len(frames) == 2:
        fa, fb, p = frames[0][0], frames[1][0], frames[1][1]
        fa = slide_blur(fa, -110 * ease_in(p), 9 * p)
        fb = slide_blur(fb, 110 * (1 - p), 9 * (1 - p))
        out = Image.blend(fa, fb, p)
    else:
        fr, win, wout = frames[0]
        w = min(win, wout)
        out = Image.blend(background(t).convert('RGB'), fr, w) if w < 1 else fr
    if CHECK: return out
    o = out.convert('RGBA')
    for a, b, text, name in cues:
        if name == 'cierre' or not (a <= t < b): continue
        alpha = ease(seg(t, a + 0.03, a + 0.18)) * (1 - ease(seg(t, b - 0.12, b)))
        if alpha > 0: draw_subtitle(o, text, alpha)
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
    for i, (a, b, text, _) in enumerate(cues, 1): lines += [str(i), f'{ts(a)} --> {ts(b)}', text, '']
    pathlib.Path(path).write_text('\n'.join(lines), encoding='utf-8')


# ───────────────────────────── verificador de composición ─────────────────────────────
def content_bbox(img, x0=0, x1=W, y0=0, y1=H, thr=6):
    """Caja de lo que no es fondo dentro de una región (diferencia con el color de fondo mayor que `thr`)."""
    reg = img.crop((x0, y0, x1, y1)).convert('RGB')
    diff = ImageChops.difference(reg, Image.new('RGB', reg.size, BG)).convert('L').point(lambda v: 255 if v > thr else 0)
    bb = diff.getbbox()
    return None if bb is None else (bb[0] + x0, bb[1] + y0, bb[2] + x0, bb[3] + y0)


CHECKS = [  # (escena, segundo local, qué se comprueba)
    ('hook', 4.5, 'centered'), ('phone', 9.0, 'split'), ('red', 2.5, 'centered'), ('red', 7.5, 'centered'),
    ('tablero', 5.0, 'centered'), ('silencio', 6.0, 'split'), ('cierre', 4.0, 'centered'),
]


def check():
    global CHECK
    CHECK = True
    tl = timeline()
    by = {sc['name']: sc for sc in tl}
    fails = 0
    print(f'{"escena":10} {"t":>5}  {"izq":>5} {"der":>5} {"arr":>5} {"aba":>5}  resultado')
    for name, local, kind in CHECKS:
        t = by[name]['start'] + local
        img = frame_at(t, tl, [])
        (WORK / 'check').mkdir(exist_ok=True)
        img.save(WORK / 'check' / f'{name}-{local}.png')
        bb = content_bbox(img)
        if bb is None: print(f'{name:10} {local:5.1f}  (vacío)'); fails += 1; continue
        l, tp, r, bt = bb[0], bb[1], W - bb[2], H - bb[3]
        problems = []
        if l < M - 4 or r < M - 4: problems.append(f'fuera del área segura ({M} px)')
        if kind == 'centered':
            if abs(l - r) > 10: problems.append(f'descentrado en ancho: {l} ≠ {r}')
        else:  # partido: cada columna dentro de su mitad y los medios centrados en alto
            lb = content_bbox(img, 0, int(LEFT[1]), 140, H - 60)
            rb = content_bbox(img, int(RIGHT[0]), W, 130, H)
            if lb is None or rb is None: problems.append('falta una columna')
            else:
                if lb[2] > LEFT[1] + 2: problems.append(f'el texto invade la columna de medios ({lb[2]} > {LEFT[1]:.0f})')
                if rb[0] < RIGHT[0] - 2: problems.append(f'los medios invaden la columna de texto ({rb[0]} < {RIGHT[0]:.0f})')
                mc = (rb[0] + rb[2]) / 2
                rc = (RIGHT[0] + RIGHT[1]) / 2
                if abs(mc - rc) > 12: problems.append(f'medios descentrados en su columna: {mc:.0f} ≠ {rc:.0f}')
        ok = not problems
        fails += 0 if ok else 1
        print(f'{name:10} {local:5.1f}  {l:5d} {r:5d} {tp:5d} {bt:5d}  {"✓" if ok else "✗ " + "; ".join(problems)}')
    CHECK = False
    print('composición: TODO CUADRA' if fails == 0 else f'composición: {fails} fotograma(s) con problemas')
    return fails


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
    if not (WORK / 'board_frames' / 'meta.json').exists(): sys.exit(f'faltan los fotogramas del tablero: {WORK / "board_frames"}')
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
    if check() != 0: sys.exit('no se renderiza con la composición fuera de rejilla')
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
    frame_at(ph['start'] + 8.5, tl, cues).save(out / 'SARD-video-poster.png')
    print('listo:', out / 'SARD-video.mp4', f'({total:.1f} s)', '· subtítulos:', ROOT / 'guion.srt')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'prepare': prepare()
    elif cmd == 'check': sys.exit(1 if check() else 0)
    elif cmd == 'still': still(float(sys.argv[2]))
    elif cmd == 'render': render()
    else: sys.exit(__doc__)
