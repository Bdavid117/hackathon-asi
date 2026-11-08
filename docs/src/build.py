#!/usr/bin/env python3
"""Construye docs/SARD-arquitectura-app-movil.pdf a partir de docs/src/.

Pipeline: parts/*.html + diagrams.py + style.css  ->  HTML  ->  Chrome headless  ->  PDF.
Se hacen dos pasadas para que el índice lleve los números de página reales.

Uso (desde cualquier directorio):  python3 docs/src/build.py
Requisitos: Google Chrome (o variable CHROME), python3 y pypdf.
"""
import html
import json
import os
import pathlib
import re
import subprocess
import unicodedata
import sys

SRC = pathlib.Path(__file__).resolve().parent
OUT_PDF = SRC.parent / "SARD-arquitectura-app-movil.pdf"
BUILD = SRC / "_build"
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

sys.path.insert(0, str(SRC))
import diagrams  # noqa: E402

COVER = """
<section class="cover">
  <svg class="circuit" viewBox="0 0 210 297" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg">
    <g fill="none" stroke="#E0B040" stroke-width="0.35" opacity="0.8">
      <path d="M0 20 H14 L22 12 H46"/><path d="M0 28 H10 L18 20"/><path d="M164 0 V10 L172 18 H210"/>
      <path d="M210 30 H196 L190 36 H170"/><path d="M0 292 H14 L20 286 H44"/><path d="M210 292 H196 L190 286 H168"/>
    </g>
    <g fill="#E0B040"><circle cx="46" cy="12" r="1.1"/><circle cx="18" cy="20" r="1"/>
      <circle cx="170" cy="36" r="1"/><circle cx="44" cy="286" r="1.1"/><circle cx="168" cy="286" r="1.1"/></g>
    <g fill="none" stroke="#7C6AA6" stroke-width="0.35" opacity="0.9"><path d="M0 36 H8 L14 42"/><path d="M210 44 H200 L194 50"/></g>
  </svg>
  <div class="inner">
    <div class="kicker">HACKATHON SARD · EXPO ASI 2026</div>
    <h1 class="title">Arquitectura y plan<br>de desarrollo de la<br><em>app móvil</em> SARD</h1>
    <div class="subtitle">Sistema Agéntico de Respuesta y Resiliencia ante Desastres: análisis del enunciado, arquitectura recomendada, protocolo, agentes, pruebas y hoja de ruta.</div>
    <div class="rule"></div>
    <div class="meta">
      <b>Evento</b> &nbsp; Universidad Nacional de Colombia | Sede Manizales<br>
      <b>Departamento</b> &nbsp; Informática y Computación<br>
      <b>Repositorio</b> &nbsp; hackathon-asi<br>
      <b>Versión</b> &nbsp; 0.2 · desarrollo individual con Flutter y Dart · 8 de noviembre de 2026
    </div>
    <div class="badge">LAS DECISIONES DE DISEÑO SON PROPUESTAS · SUPUESTOS MARCADOS</div>
  </div>
  <div class="foot">Documento derivado del enunciado «HackathonExpoASI2026.pdf» (12 páginas). Las cifras de tamaño de trama provienen de la
  calculadora de referencia <span style="font-family:Menlo,monospace">docs/src/tools/frame_size.py</span>; las metas de las pruebas son sugerencias a calibrar.</div>
</section>
"""


def read_parts():
    out = []
    for p in sorted((SRC / "parts").glob("*.html")):
        out.append(p.read_text(encoding="utf-8"))
    return "\n".join(out)


def number_headings(body):
    """Numera h1/h2 y devuelve (html, lista de entradas {id, nivel, num, titulo})."""
    entries = []
    c1 = 0
    c2 = 0
    annex_label = None

    def repl(m):
        nonlocal c1, c2, annex_label
        tag, attrs, title = m.group(1), m.group(2), m.group(3)
        idm = re.search(r'id="([^"]+)"', attrs)
        hid = idm.group(1) if idm else None
        if tag == "h1":
            am = re.search(r'data-annex="([^"]+)"', attrs)
            if am:
                annex_label = am.group(1)
                num = annex_label
            else:
                annex_label = None
                c1 += 1
                num = str(c1)
            c2 = 0
        else:
            c2 += 1
            num = f"{annex_label or c1}.{c2}"
        entries.append(dict(id=hid, level=int(tag[1]), num=num, title=html.unescape(re.sub(r"<[^>]+>", "", title))))
        return f'<{tag}{attrs}><span class="num">{num}</span>{title}</{tag}>'

    body = re.sub(r"<(h[12])([^>]*)>(.*?)</\1>", repl, body, flags=re.S)
    return body, entries


def toc_html(entries, pages):
    rows = ['<section class="toc"><h1 id="indice" style="break-before:avoid">Índice de contenido</h1>']
    for e in entries:
        pg = pages.get(e["id"], "·")
        cls = "h1r" if e["level"] == 1 else "h2r"
        rows.append(
            f'<div class="row {cls}"><span class="n">{e["num"]}</span><span>{html.escape(e["title"])}</span>'
            f'<span class="dots"></span><span class="pg">{pg}</span></div>'
        )
    rows.append("</section>")
    return "\n".join(rows)


def assemble(pages):
    css = (SRC / "style.css").read_text(encoding="utf-8")
    body = read_parts()
    for name, fn in diagrams.ALL.items():
        body = body.replace("{{svg:%s}}" % name, fn())
    body, entries = number_headings(body)
    # referencias cruzadas {{ref:id}} -> «§N.M»
    nums = {e["id"]: e["num"] for e in entries if e["id"]}

    def ref(m):
        k = m.group(1)
        if k not in nums:
            raise SystemExit(f"Referencia cruzada desconocida: {k}")
        return f"§{nums[k]}"

    body = re.sub(r"\{\{ref:([^}]+)\}\}", ref, body)
    if "{{" in body:
        left = re.findall(r"\{\{[^}]+\}\}", body)[:5]
        raise SystemExit(f"Marcadores sin resolver: {left}")
    doc = (
        '<!doctype html><html lang="es"><head><meta charset="utf-8">'
        "<title>SARD · Arquitectura y plan de desarrollo de la app móvil</title>"
        f"<style>{css}</style></head><body>{COVER}{toc_html(entries, pages)}{body}</body></html>"
    )
    return doc, entries


def render(doc_html, pdf_path):
    BUILD.mkdir(exist_ok=True)
    f = BUILD / "index.html"
    f.write_text(doc_html, encoding="utf-8")
    cmd = [CHROME, "--headless=new", "--disable-gpu", "--no-pdf-header-footer", "--hide-scrollbars",
           f"--print-to-pdf={pdf_path}", f"file://{f}"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if not pathlib.Path(pdf_path).exists():
        raise SystemExit(f"Chrome no generó el PDF.\n{r.stderr[-800:]}")


def locate_pages(pdf_path, entries):
    from pypdf import PdfReader

    reader = PdfReader(str(pdf_path))
    texts = []
    for pg in reader.pages:
        lines = [re.sub(r"\s+", " ", unicodedata.normalize("NFKC", ln)).strip() for ln in (pg.extract_text() or "").splitlines()]
        texts.append(lines)
    pages = {}
    start = 1  # saltar portada
    for e in entries:
        target = re.sub(r"\s+", " ", unicodedata.normalize("NFKC", e["title"])).strip()
        found = None
        for i in range(start, len(texts)):
            for ln in texts[i]:
                stripped = re.sub(r"^[A-Z0-9]+(\.\d+)?\s*", "", ln)
                if stripped == target or ln == target:
                    # descartar líneas del índice (llevan el número de página al final)
                    found = i
                    break
            if found is not None:
                break
        if found is None:
            raise SystemExit(f"No se halló el encabezado en el PDF: {e['num']} {e['title']}")
        pages[e["id"]] = found + 1
        start = found
    return pages, len(reader.pages)


def main():
    BUILD.mkdir(exist_ok=True)
    tmp = BUILD / "pass1.pdf"
    doc, entries = assemble({})
    render(doc, tmp)
    pages, n1 = locate_pages(tmp, entries)
    doc2, _ = assemble(pages)
    tmp2 = BUILD / "pass2.pdf"
    render(doc2, tmp2)
    pages2, n2 = locate_pages(tmp2, entries)
    if pages2 != pages:
        # una tercera pasada estabiliza el índice si la numeración se desplazó
        doc3, _ = assemble(pages2)
        render(doc3, tmp2)
        pages3, n2 = locate_pages(tmp2, entries)
        if pages3 != pages2:
            raise SystemExit("La paginación del índice no se estabiliza.")
    OUT_PDF.write_bytes(tmp2.read_bytes())
    (BUILD / "pages.json").write_text(json.dumps(pages2, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"OK  {OUT_PDF}  ({n2} páginas)")


if __name__ == "__main__":
    main()
