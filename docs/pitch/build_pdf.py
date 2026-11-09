#!/usr/bin/env python3
"""Renderiza las láminas del pitch (docs/pitch/deck/) con Chrome sin cabeza.

Salidas:
  --pdf RUTA        un PDF con una página de 1920x1080 por lámina
  --png-dir CARPETA un PNG por lámina (para revisarlas a ojo)

Las láminas usan el subconjunto de HTML/CSS del tipo «Slides» (estilos en línea, sección de 1920x1080).
Aquí se les añade sólo lo que ese tipo pone por su cuenta: márgenes en cero, cajas border-box, el aspecto de
las tablas y las imágenes locales en lugar de /_blob/<id> (ver deck/assets.json). Las notas del orador
(<aside>) no se dibujan.

Uso:  python3 -I docs/pitch/build_pdf.py --pdf docs/pitch/SARD-pitch.pdf [--png-dir /tmp/laminas]
Requiere Google Chrome (variable CHROME si está en otra ruta) y conexión para las tipografías de Google Fonts.
"""
import argparse, json, os, pathlib, re, subprocess, sys, tempfile

AQUI = pathlib.Path(__file__).resolve().parent
CHROME = os.environ.get('CHROME', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')

CSS = """
*{margin:0;padding:0;box-sizing:border-box}
html,body{background:#000}
.lam{position:relative;width:1920px;height:1080px;overflow:hidden;page-break-after:always;break-after:page}
.lam>section{width:1920px;height:1080px;position:relative;overflow:hidden}
aside{display:none}
table{width:100%;border-collapse:collapse}
th,td{padding:0.35em 0.6em;border-bottom:1px solid #2C3644;vertical-align:top}
th{font-weight:600;color:#A9B4C2;border-bottom:2px solid #3F4C5E}
@page{size:1920px 1080px;margin:0}
"""


def cargar(src):
    deck = json.loads((src / 'project' / 'deck.json').read_text(encoding='utf-8'))
    assets = json.loads((src / 'assets.json').read_text(encoding='utf-8')) if (src / 'assets.json').exists() else {}
    fuentes = [f['href'] for f in deck.get('faces', {}).values() if 'href' in f]
    laminas = []
    for sid in deck['order']:
        t = (src / 'project' / 'slides' / f'{sid}.html').read_text(encoding='utf-8')
        def local(m):
            ruta = assets.get(m.group(1))
            if not ruta:
                sys.exit(f'{sid}: la imagen /_blob/{m.group(1)} no está en assets.json')
            return 'src="' + (src / ruta).resolve().as_uri() + '"'
        t = re.sub(r'src="/_blob/([0-9a-f]+)"', local, t)
        laminas.append((sid, t))
    return deck, fuentes, laminas


def pagina(fuentes, cuerpo):
    links = ''.join(f'<link rel="stylesheet" href="{h}">' for h in fuentes)
    return f'<!doctype html><html lang="es"><head><meta charset="utf-8">{links}<style>{CSS}</style></head><body>{cuerpo}</body></html>'


def chrome(*args):
    r = subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-pdf-header-footer',
                        '--virtual-time-budget=15000', *args], capture_output=True, text=True, timeout=120)
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', default=str(AQUI / 'deck'))
    ap.add_argument('--pdf')
    ap.add_argument('--png-dir')
    a = ap.parse_args()
    src = pathlib.Path(a.src).resolve()
    deck, fuentes, laminas = cargar(src)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        if a.png_dir:
            out = pathlib.Path(a.png_dir)
            out.mkdir(parents=True, exist_ok=True)
            for i, (sid, t) in enumerate(laminas, 1):
                f = tmp / f'{sid}.html'
                f.write_text(pagina(fuentes, f'<div class="lam">{t}</div>'), encoding='utf-8')
                png = out / f'{i:02d}-{sid}.png'
                chrome(f'--window-size=1920,1080', f'--screenshot={png}', f.as_uri())
                print('PNG', png, png.exists() and png.stat().st_size)
        if a.pdf:
            f = tmp / 'todo.html'
            f.write_text(pagina(fuentes, ''.join(f'<div class="lam">{t}</div>' for _, t in laminas)), encoding='utf-8')
            pdf = pathlib.Path(a.pdf).resolve()
            chrome(f'--print-to-pdf={pdf}', f.as_uri())
            print('PDF', pdf, pdf.exists() and pdf.stat().st_size)


if __name__ == '__main__':
    main()
