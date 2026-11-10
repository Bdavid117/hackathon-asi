#!/usr/bin/env python3
"""Generador de los diagramas SVG del documento de arquitectura.

Cada función devuelve el texto de un <svg> en línea. build.py los inserta en el HTML
mediante marcadores {{svg:nombre}}. Paleta alineada con el enunciado de la hackathon.
"""
from xml.sax.saxutils import escape

NAVY, DARK = "#1F3A68", "#0F1B3D"
CYAN, CYAN_L = "#22C5D3", "#E5F6F8"
GOLD, GOLD_L = "#E0B040", "#FBF3DC"
BLUE_L, GREY, INK, LINE = "#EDF1FA", "#6B7690", "#1B2433", "#C9D2E3"
RED = "#C0392B"


def _svg(w, h, body, label):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" role="img" '
        f'aria-label="{escape(label)}" class="diagram">'
        '<defs>'
        f'<marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{NAVY}"/></marker>'
        f'<marker id="ahg" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{GREY}"/></marker>'
        f'<marker id="ahr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{RED}"/></marker>'
        '</defs>'
        f'{body}</svg>'
    )


def box(x, y, w, h, fill, stroke=None, rx=8, dash=False, sw=1.2):
    s = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
    d = ' stroke-dasharray="5 4"' if dash else ""
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}"{s}{d}/>'


def text(x, y, s, size=11, weight=400, fill=INK, anchor="middle", italic=False):
    st = ' font-style="italic"' if italic else ""
    return (f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{fill}" '
            f'text-anchor="{anchor}"{st}>{escape(s)}</text>')


def lines(x, y, rows, size=10.5, lh=13, fill=INK, anchor="middle", weight=400):
    return "".join(text(x, y + i * lh, r, size, weight, fill, anchor) for i, r in enumerate(rows))


def arrow(x1, y1, x2, y2, color=NAVY, dash=False, both=False, red=False):
    m = "ahr" if red else ("ahg" if color == GREY else "ah")
    d = ' stroke-dasharray="5 4"' if dash else ""
    start = f' marker-start="url(#{m})"' if both else ""
    return (f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="1.5"{d} '
            f'marker-end="url(#{m})"{start}/>')


def chip(x, y, w, h, title, sub=None, fill=CYAN, fg="#08323a", size=10.5):
    out = box(x, y, w, h, fill, rx=7)
    if sub:
        out += text(x + w / 2, y + h / 2 - 2, title, size, 700, fg)
        out += text(x + w / 2, y + h / 2 + 11, sub, size - 1.5, 400, fg)
    else:
        out += text(x + w / 2, y + h / 2 + 4, title, size, 700, fg)
    return out


# ---------------------------------------------------------------------------------------
def contexto():
    b = []
    # Pila principal (x 10..520)
    b.append(box(10, 8, 510, 92, CYAN_L, CYAN, 12))
    b.append(text(22, 27, "CAPA CIUDADANA · app móvil", 11.5, 800, NAVY, "start"))
    b.append(text(508, 27, "store-and-forward", 10, 400, GREY, "end", True))
    xs = [20, 143, 266, 389]
    for x, t1, t2 in zip(xs, ["Reporte ≤ 3 toques", "Bandeja de salida", "Códec binario", "Planificador"],
                         ["SOS mínimo + detalle", "SQLite durable", "ID idempotente", "reintentos y ventanas"]):
        b.append(chip(x, 40, 118, 50, t1, t2))

    b.append(arrow(265, 100, 265, 130, GREY, True, both=True))
    b.append(text(278, 114, "Canal intermitente", 9.5, 700, GREY, "start", True))
    b.append(text(278, 126, "HTTP/Wi-Fi local · BLE/Nearby · SMS · simulado", 9.2, 400, GREY, "start", True))

    b.append(box(10, 134, 510, 118, GOLD_L, GOLD, 12))
    b.append(text(22, 153, "CAPA DE NODOS SUPERVIVIENTES", 11.5, 800, "#7a5a0a", "start"))
    b.append(text(508, 153, "log de eventos · sin líder", 10, 400, GREY, "end", True))
    for x, n in zip([24, 190, 356], ["Nodo A", "Nodo B", "Nodo C"]):
        b.append(box(x, 164, 140, 76, "#fff", GOLD, 8))
        b.append(text(x + 70, 183, n, 11.5, 800, "#7a5a0a"))
        b.append(lines(x + 70, 198, ["API de ingreso", "Log append-only", "Agentes + proyecciones"], 9.5, 12, INK))
    b.append(arrow(164, 202, 190, 202, NAVY, False, both=True))
    b.append(arrow(330, 202, 356, 202, NAVY, False, both=True))
    b.append(text(265, 247, "anti-entropía entre pares (sincronización al reconectar)", 9.5, 400, GREY, "middle", True))

    b.append(arrow(265, 252, 265, 270, GREY, True, both=True))
    b.append(box(10, 272, 510, 62, BLUE_L, NAVY, 12))
    b.append(text(22, 291, "TEJIDO DE AGENTES · autonomía limitada (en cada nodo)", 11.5, 800, NAVY, "start"))
    for x, t in zip([20, 130, 240, 350], ["1 Recepción", "2 Triaje", "3 Correlación", "6 Coordinación"]):
        b.append(box(x, 300, 100, 26, NAVY, rx=6))
        b.append(text(x + 50, 317, t, 10.5, 700, "#fff"))
    b.append(box(458, 300, 52, 26, GOLD, rx=6))
    b.append(text(484, 311, "4 · 5", 10, 800, DARK))
    b.append(text(484, 322, "transv.", 8, 400, DARK))

    b.append(arrow(265, 334, 265, 352, GREY, True, both=True))
    b.append(box(10, 354, 510, 56, DARK, rx=12))
    b.append(text(22, 373, "CENTRO DE COORDINACIÓN HUMANA · tablero web (otra superficie)", 11.5, 800, GOLD, "start"))
    b.append(lines(265, 391, ["cola priorizada · fuentes · incertidumbre · recomendación · aprobar / rechazar"], 10, 12, "#fff"))

    # Banco de pruebas (x 545..710)
    b.append(box(545, 8, 165, 402, "#fff", GOLD, 12, dash=True, sw=1.6))
    b.append(text(627, 28, "BANCO DE PRUEBAS", 11.5, 800, "#7a5a0a"))
    b.append(text(627, 41, "(entregables 6 y 7)", 9.5, 400, GREY, "middle", True))
    items = [("Generador sintético", "reportes con verdad de", "referencia, ruido, rumores"),
             ("Simulador de canal", "pérdida · retardo · reorden", "ventanas cortas · ancho"),
             ("Inyector de fallos", "kill -9 · partición", "reinicio de nodos"),
             ("Recolector de métricas", "entrega · recall P1", "falsas fusiones · RTO")]
    y = 54
    for t, a, c in items:
        b.append(box(555, y, 145, 74, GOLD_L, GOLD, 8))
        b.append(text(627, y + 19, t, 10.5, 800, "#7a5a0a"))
        b.append(lines(627, y + 36, [a, c], 9.2, 12, INK))
        y += 86
    b.append(arrow(545, 112, 520, 118, GOLD, True))
    b.append(arrow(545, 198, 520, 200, GOLD, True))
    b.append(arrow(545, 284, 520, 200, GOLD, True))
    return _svg(720, 418, "".join(b), "Vista general de componentes de SARD")


# ---------------------------------------------------------------------------------------
def app_capas():
    b = []
    layers = [
        ("Interfaz (UI)", "SOS · formulario mínimo · estado de entrega · modo ahorro", CYAN_L, CYAN),
        ("Dominio (casos de uso)", "crearReporte · enriquecerReporte · priorizarSalida · expirar", BLUE_L, NAVY),
        ("Persistencia", "SQLite (WAL, synchronous=FULL): outbox · eventos · ajustes", GOLD_L, GOLD),
        ("Transporte", "interfaz Channel: Http · Nearby/BLE · Sms · Simulado", BLUE_L, NAVY),
        ("Plataforma", "GPS (una lectura) · batería · conectividad · servicio en 1.er plano", "#F1EEF7", "#7C6AA6"),
    ]
    y = 8
    for t, s, f, st in layers:
        b.append(box(8, y, 352, 52, f, st, 8))
        b.append(text(22, y + 21, t, 11.5, 800, NAVY, "start"))
        b.append(text(22, y + 39, s, 9.3, 400, INK, "start"))
        y += 60
    for i in range(4):
        b.append(arrow(184, 60 + i * 60, 184, 68 + i * 60, GREY))
    b.append(text(184, 318, "Regla: la UI nunca habla con la red; sólo escribe en la persistencia.", 9.6, 400, GREY, "middle", True))

    # Máquina de estados (derecha)
    states = [("GUARDADO", "commit en SQLite", "Guardado en tu teléfono", CYAN),
              ("EN COLA", "listo para enviar", "Esperando señal", CYAN),
              ("ENVIANDO", "trama en vuelo", "Enviando…", NAVY),
              ("ENVIADO", "ACK de un nodo", "Enviado a un nodo", NAVY),
              ("CONFIRMADO", "visto por el tejido", "Recibido por SARD", GOLD)]
    x0, w = 436, 146
    y = 8
    for i, (n, d, u, c) in enumerate(states):
        fg = "#fff" if c == NAVY else "#08323a"
        if c == GOLD:
            fg = DARK
        b.append(box(x0, y, w, 46, c, rx=8))
        b.append(text(x0 + w / 2, y + 19, n, 11, 800, fg))
        b.append(text(x0 + w / 2, y + 34, d, 9, 400, fg))
        b.append(text(x0 + w + 10, y + 27, u, 9.2, 400, GREY, "start", True))
        if i < 4:
            b.append(arrow(x0 + w / 2, y + 46, x0 + w / 2, y + 60))
        y += 60
    # Reintento: ENVIANDO -> EN COLA (curva por la izquierda)
    b.append(f'<path d="M{x0},{8+120+23} C{x0-34},{8+120+23} {x0-34},{8+60+23} {x0},{8+60+23}" fill="none" stroke="{RED}" stroke-width="1.5" marker-end="url(#ahr)"/>')
    b.append(text(x0 - 40, 8 + 94, "fallo", 8.6, 400, RED, "end", True))
    b.append(text(x0 - 40, 8 + 105, "backoff", 8.6, 400, RED, "end", True))
    b.append(box(x0, 308, w, 24, "#fff", RED, 6, dash=True))
    b.append(text(x0 + w / 2, 324, "EXPIRADO (TTL, baja prioridad)", 8.6, 700, RED))
    return _svg(720, 340, "".join(b), "Capas internas de la app y máquina de estados de entrega")


# ---------------------------------------------------------------------------------------
def secuencia():
    parts = [("Ciudadano / App", 112), ("Canal simulado", 218), ("Nodo A", 324), ("Nodo B", 430),
             ("Agentes", 540), ("Tablero", 652)]
    H = 504
    b = []
    for n, x in parts:
        b.append(box(x - 50, 6, 100, 24, NAVY, rx=6))
        b.append(text(x, 22, n, 10, 700, "#fff"))
        b.append(f'<line x1="{x}" y1="30" x2="{x}" y2="{H-6}" stroke="{LINE}" stroke-width="1.2" stroke-dasharray="4 4"/>')
    X = dict(parts)
    y = 54

    def msg(x1, x2, label, yy, color=NAVY, dash=False, red=False, dy=-5):
        mid = (X[x1] + X[x2]) / 2
        out = arrow(X[x1], yy, X[x2], yy, color, dash, red=red)
        if label:
            out += text(mid, yy + dy, label, 9.4, 400, color if color != NAVY else INK)
        return out

    def note(x, yy, label, fill=CYAN, w=156, fg="#08323a"):
        return box(X[x] - w / 2, yy - 13, w, 26, fill, rx=6) + text(X[x], yy + 4, label, 9.6, 700, fg)

    def step(yy, n):
        return f'<circle cx="14" cy="{yy}" r="9" fill="{DARK}"/>' + text(14, yy + 3.6, str(n), 10, 800, "#fff")

    A, C, NA, NB, AG, T = ("Ciudadano / App", "Canal simulado", "Nodo A", "Nodo B", "Agentes", "Tablero")
    b += [note(A, y, "crear reporte (SOS)"), step(y, 1)]; y += 34
    b += [note(A, y, "commit SQLite → «Guardado»"), step(y, 2)]; y += 36
    b += [msg(A, NA, "trama de 33 B", y), step(y, 3),
          text(X[C], y + 14, "canal: pérdida · duplicado · retardo", 8.8, 400, GREY, "middle", True)]; y += 30
    b += [msg(NA, A, "ACK selectivo (ventana de 32)", y, GREY, True)]; y += 34
    b += [msg(NA, AG, "report.received", y), step(y, 4)]; y += 24
    b += [msg(AG, NA, "normalizado · triado · vinculado", y, GREY, True)]; y += 34
    b += [note(NA, y, "cola priorizada P1…P4 + aging", GOLD_L, 180, DARK), step(y, 5)]; y += 32
    b += [msg(NA, T, "vista del coordinador", y), step(y, 6)]; y += 32
    b += [msg(NA, NB, "anti-entropía: eventos que faltan", y, GREY, True)]; y += 24
    b += [msg(NB, NA, "vector de versiones", y, GREY, True)]; y += 36
    b.append(box(X[NA] - 84, y - 14, 168, 28, "#FDECEA", RED, 6))
    b.append(text(X[NA], y + 4, "✕ kill -9 del Nodo A", 10.5, 800, RED)); b.append(step(y, 7)); y += 34
    b += [msg(A, NB, "reintento con backoff + jitter", y, RED, red=True)]; y += 26
    b += [msg(NB, T, "el tablero sigue (muestra frescura)", y)]; y += 34
    b += [note(NA, y, "↻ Nodo A reinicia", CYAN, 150), step(y, 8)]; y += 30
    b += [msg(NB, NA, "reconciliación: envía los eventos que faltan", y, NAVY)]
    return _svg(720, H, "".join(b), "Recorrido de integración de ocho pasos")


# ---------------------------------------------------------------------------------------
def nodo():
    b = []
    b.append(box(8, 120, 118, 92, CYAN_L, CYAN, 10))
    b.append(text(67, 140, "Ingreso", 11.5, 800, NAVY))
    b.append(lines(67, 156, ["HTTP · trama binaria", "canal simulado", "límite de tasa por", "dispositivo"], 9.2, 12))
    b.append(arrow(126, 166, 150, 166))
    b.append(box(150, 120, 140, 92, CYAN_L, CYAN, 10))
    b.append(text(220, 140, "Validación", 11.5, 800, NAVY))
    b.append(lines(220, 156, ["CRC / etiqueta", "idempotencia por", "(report_id, rev)", "→ ACK siempre"], 9.2, 12))
    b.append(arrow(290, 166, 322, 166))
    b.append(box(322, 100, 150, 132, GOLD_L, GOLD, 10, sw=2))
    b.append(text(397, 122, "LOG DE EVENTOS", 11.5, 800, "#7a5a0a"))
    b.append(lines(397, 140, ["append-only", "SQLite (WAL)", "fuente de verdad", "report.* · triage.*", "incident.* · approval.*"], 9.4, 13))
    b.append(arrow(472, 166, 500, 166))
    b.append(box(500, 80, 212, 152, BLUE_L, NAVY, 10))
    b.append(text(606, 100, "PROYECCIONES (derivables)", 11, 800, NAVY))
    for i, (t, s) in enumerate([("Cola priorizada", "orden + aging, sin ocultar"),
                                ("Grupos de incidentes", "vínculos a cada observación"),
                                ("Estado de nodos", "frescura de cada par"),
                                ("API del tablero", "REST + eventos del servidor")]):
        yy = 112 + i * 29
        b.append(box(510, yy, 192, 25, "#fff", LINE, 6))
        b.append(text(520, yy + 11, t, 9.8, 700, INK, "start"))
        b.append(text(520, yy + 21.5, s, 8.4, 400, GREY, "start"))

    # Agentes + puerto LLM
    b.append(box(236, 6, 300, 70, BLUE_L, NAVY, 10))
    b.append(text(386, 24, "Tejido de agentes · suscriptores del log", 11, 800, NAVY))
    for x, t in [(246, "Recepción"), (318, "Triaje"), (390, "Correlación"), (462, "Coordinación")]:
        b.append(box(x, 36, 66, 28, NAVY, rx=5)); b.append(text(x + 33, 54, t, 8.4, 700, "#fff"))
    b.append(arrow(397, 76, 397, 100, NAVY, both=True))
    b.append(text(388, 92, "leen eventos / añaden derivados", 8.8, 400, GREY, "end", True))
    b.append(box(548, 6, 164, 62, "#F1EEF7", "#7C6AA6", 10))
    b.append(text(630, 24, "Puerto LLM (intercambiable)", 10.2, 800, "#4B3C73"))
    b.append(lines(630, 40, ["1) nube · 2) modelo local", "3) reglas deterministas", "salida validada por esquema"], 8.8, 11.5))
    b.append(arrow(548, 38, 536, 38, "#7C6AA6", True))

    # Parte baja
    b.append(box(246, 262, 270, 56, GOLD_L, GOLD, 10))
    b.append(text(381, 281, "Sincronización (anti-entropía)", 11, 800, "#7a5a0a"))
    b.append(lines(381, 297, ["vector de versiones por origen", "intercambia sólo lo que falta"], 9.2, 12))
    b.append(arrow(397, 232, 397, 262, GOLD, both=True))
    b.append(box(246, 340, 270, 30, "#fff", GOLD, 8, dash=True))
    b.append(text(381, 359, "Nodos pares (B, C, …)", 10.5, 700, "#7a5a0a"))
    b.append(arrow(381, 318, 381, 340, GOLD, both=True))
    b.append(box(540, 262, 172, 56, "#fff", NAVY, 10, dash=True))
    b.append(text(626, 281, "Supervisor de salud", 11, 800, NAVY))
    b.append(lines(626, 297, ["latidos · lógica convencional", "sin LLM (agente 5)"], 9.2, 12))
    b.append(arrow(626, 232, 626, 262, GREY, True, both=True))
    b.append(box(8, 262, 214, 108, "#fff", LINE, 10))
    b.append(text(115, 282, "Invariantes del nodo", 11, 800, NAVY))
    b.append(lines(115, 299, ["Nada se borra: sólo se añaden eventos", "Una vista se puede reconstruir", "desde cero a partir del log", "Un nodo funciona solo (sin pares,", "sin Internet y sin LLM)"], 9, 12.2))
    return _svg(720, 378, "".join(b), "Arquitectura interna de un nodo superviviente")


# ---------------------------------------------------------------------------------------
def agentes():
    b = []
    xs = [14, 160, 306, 452]
    names = [("1 · Recepción", "valida y normaliza", CYAN, "#08323a"),
             ("2 · Triaje", "estima urgencia", CYAN, "#08323a"),
             ("3 · Correlación", "agrupa duplicados", CYAN, "#08323a"),
             ("6 · Coordinación", "propone acción", NAVY, "#fff")]
    for x, (t, s, f, fg) in zip(xs, names):
        b.append(box(x, 24, 128, 54, f, rx=9))
        b.append(text(x + 64, 47, t, 11.5, 800, fg))
        b.append(text(x + 64, 63, s, 9.6, 400, fg))
    b.append(box(598, 24, 108, 54, DARK, rx=9))
    b.append(text(652, 47, "Humano", 11.5, 800, GOLD)); b.append(text(652, 63, "aprueba o rechaza", 9.4, 400, GOLD))
    for i in range(4):
        x1 = xs[i] + 128
        x2 = (xs[i + 1] if i < 3 else 598)
        b.append(arrow(x1, 51, x2, 51))
    labels = [("report.normalized", 151), ("triage.assessed", 297), ("incident.linked", 443), ("recommendation.proposed", 588)]
    for l, x in labels:
        b.append(text(x, 18, l, 8.6, 400, GREY, "middle", True))
    b.append(text(8, 100, "Respaldo determinista (si el LLM no responde, se rechaza o excede el tiempo)", 10, 800, NAVY, "start"))
    fbs = ["esquema + reglas de campos", "reglas de señales de riesgo", "bloqueo geohash + similitud", "plantilla de acción por tipo"]
    for x, f in zip(xs, fbs):
        b.append(box(x, 108, 128, 30, GOLD_L, GOLD, 6)); b.append(text(x + 64, 127, f, 8.8, 400, INK))
    b.append(box(598, 108, 108, 30, "#fff", RED, 6, dash=True)); b.append(text(652, 127, "sin salto posible", 8.8, 700, RED))
    b.append(box(8, 152, 704, 34, CYAN_L, CYAN, 8))
    b.append(text(20, 167, "4 · Comunicación y sincronización", 11, 800, NAVY, "start"))
    b.append(text(20, 180, "orden de envío, fragmentos, ACK, reintentos (reglas + aging; el LLM opcional sólo explica)", 9.2, 400, INK, "start"))
    b.append(box(8, 194, 704, 34, GOLD_L, GOLD, 8))
    b.append(text(20, 209, "5 · Resiliencia y recuperación", 11, 800, "#7a5a0a", "start"))
    b.append(text(20, 222, "salud de nodos, estado persistido, reanudación — lógica distribuida convencional, sin LLM", 9.2, 400, INK, "start"))
    b.append(box(8, 236, 704, 30, DARK, rx=8))
    b.append(text(360, 255, "LOG DE EVENTOS append-only · cada salida cita sus entradas · autonomía limitada por construcción (sin herramienta de despacho)", 9.6, 700, "#fff"))
    return _svg(720, 274, "".join(b), "Flujo de eventos entre agentes y respaldo determinista")


# ---------------------------------------------------------------------------------------
def trama():
    b = []
    W = 692
    x0 = 14
    pxB = W / 33.0
    segs = [("v|t", 1, NAVY, "#fff"), ("flags", 1, NAVY, "#fff"), ("device_id (8 B)", 8, CYAN, "#08323a"),
            ("seq (4 B)", 4, CYAN, "#08323a"), ("rev", 1, GOLD, DARK), ("len", 1, GOLD, DARK),
            ("carga bit a bit (13 B)", 13, "#7C6AA6", "#fff"), ("etiqueta 4 B", 4, GREY, "#fff")]
    b.append(text(x0, 14, "Trama del reporte mínimo (SOS): 33 bytes", 11.5, 800, NAVY, "start"))
    top, bot = 50, 90
    x = x0
    cen = {}
    for name, n, c, fg in segs:
        w = n * pxB
        b.append(box(x, top, w, bot - top, c, "#fff", 4, sw=1.5))
        cen[name] = x + w / 2
        if w > 60:
            b.append(text(x + w / 2, 74, name, 10, 700, fg))
        x += w
    # llave de report_id (encima de la barra)
    xa, xb = x0 + 2 * pxB, x0 + 14 * pxB
    b.append(f'<path d="M{xa},{top-3} v-6 H{xb} v6" fill="none" stroke="{CYAN}" stroke-width="1.5"/>')
    b.append(text((xa + xb) / 2, top - 15, "report_id = device_id + seq de la trama rev 0 (12 B)", 9.4, 700, "#08323a"))
    # llamadas bajo la barra, escalonadas
    def call(cx, y_end, tx, ty, label, anchor="start"):
        b.append(f'<line x1="{cx}" y1="{bot}" x2="{cx}" y2="{y_end}" stroke="{GREY}" stroke-width="1"/>')
        b.append(text(tx, ty, label, 9, 400, INK, anchor))
    call(cen["flags"], 106, cen["flags"] + 5, 112, "flags: FRAG · ACKREQ · FIRMADA · PRIO (2 b) · REV")
    call(cen["v|t"], 124, x0, 136, "versión (4 b) + tipo de mensaje (4 b)")
    call(cen["rev"], 106, cen["rev"] + 2, 112, "revisión", "end")
    call(cen["len"], 124, cen["len"] - 2, 136, "largo de carga (varint)")

    # Carga: 104 bits
    b.append(text(x0, 172, "Carga útil: 104 bits = 13 B, campos empaquetados sin relleno", 11.5, 800, NAVY, "start"))
    fields = [("tipo", 4, NAVY), ("situación", 8, NAVY), ("pers", 3, CYAN), ("cal", 3, CYAN),
              ("lat · 24 bits (≈1,2 m)", 24, GOLD), ("lon · 25 bits", 25, GOLD),
              ("capturado_en · 32 bits", 32, "#7C6AA6"), ("bat", 4, GREY), ("t", 1, DARK)]
    pxb = W / 104.0
    x = x0
    c2 = {}
    for name, n, c in fields:
        w = n * pxb
        fg = DARK if c in (GOLD, CYAN) else "#fff"
        b.append(box(x, 182, w, 36, c, "#fff", 3, sw=1.5))
        c2[name] = x + w / 2
        if n >= 12:
            b.append(text(x + w / 2, 204, name, 9.4, 700, fg))
        elif n == 8:
            b.append(text(x + w / 2, 204, "situación", 8.4, 700, fg))
        x += w

    def call2(cx, y_end, tx, ty, label, anchor="start"):
        b.append(f'<line x1="{cx}" y1="218" x2="{cx}" y2="{y_end}" stroke="{GREY}" stroke-width="1"/>')
        b.append(text(tx, ty, label, 9, 400, INK, anchor))
    call2(c2["tipo"], 232, x0, 244, "tipo de incidente (4 b)")
    call2(c2["pers"], 252, c2["pers"] - 4, 264, "personas por rango (3 b)")
    call2(c2["cal"], 278, c2["cal"] - 2, 290, "calidad de la ubicación (3 b)")
    call2(c2["bat"], 232, c2["bat"] + 6, 244, "batería (4 b)", "end")
    call2(c2["t"], 252, c2["t"] + 2, 264, "¿hay texto? (1 b)", "end")

    b.append(box(x0, 306, W, 52, GOLD_L, GOLD, 8))
    b.append(text(x0 + 10, 325, "«situación» = 8 indicadores: atrapado · herido · incendio · dificultad respiratoria · vía bloqueada · estructura inestable · menores/mayores · medicación.", 9, 400, INK, "start"))
    b.append(text(x0 + 10, 341, "Sin ubicación: lat/lon se omiten (−49 bits). Con texto: varint + UTF-8 (≤ 140 B). Revisión (bit REV): +4 B de ref_seq. Si no cabe en el MTU: bit FRAG + 2 B.", 9, 400, INK, "start"))
    return _svg(720, 366, "".join(b), "Diseño de la trama binaria del reporte")


# ---------------------------------------------------------------------------------------
def despliegue():
    b = []
    b.append(box(8, 10, 168, 150, CYAN_L, CYAN, 10))
    b.append(text(92, 29, "Teléfonos", 11.5, 800, NAVY))
    b.append(box(18, 40, 148, 50, "#fff", CYAN, 7)); b.append(lines(92, 58, ["Android (emulador)", "1 reporte en vivo"], 9.8, 13))
    b.append(box(18, 98, 148, 52, "#fff", CYAN, 7)); b.append(lines(92, 116, ["Clientes headless ×N", "carga sintética (mismo códec)"], 9.4, 13))

    b.append(arrow(176, 85, 214, 85, NAVY, both=True)); b.append(arrow(176, 125, 214, 125, NAVY, both=True))
    b.append(box(214, 48, 150, 112, GOLD_L, GOLD, 10, sw=2))
    b.append(text(289, 68, "Proxy de canal", 11.5, 800, "#7a5a0a"))
    b.append(lines(289, 85, ["pérdida · duplicados", "retardo · reorden", "ventana abre/cierra", "tope de ancho de banda"], 9.4, 13))
    b.append(arrow(364, 104, 402, 104, NAVY, both=True))

    b.append(box(402, 10, 306, 168, "#fff", NAVY, 12, dash=True, sw=1.6))
    b.append(text(555, 29, "Red local sin Internet (procesos o contenedores)", 10.5, 800, NAVY))
    for x, n in zip([412, 512, 612], ["Nodo A", "Nodo B", "Nodo C"]):
        b.append(box(x, 42, 88, 62, BLUE_L, NAVY, 8))
        b.append(text(x + 44, 62, n, 11, 800, NAVY))
        b.append(lines(x + 44, 77, ["log + agentes", "SQLite propio"], 8.8, 11.5))
    b.append(arrow(500, 73, 512, 73, NAVY, both=True)); b.append(arrow(600, 73, 612, 73, NAVY, both=True))
    b.append(box(412, 116, 288, 50, "#F1EEF7", "#7C6AA6", 8))
    b.append(lines(556, 133, ["Modelo de lenguaje: nube cuando hay Internet,", "local o reglas cuando no (puerto intercambiable)"], 9.2, 13))

    b.append(box(8, 196, 230, 90, DARK, rx=10))
    b.append(text(123, 216, "Tablero del coordinador", 11.5, 800, GOLD))
    b.append(lines(123, 233, ["navegador (PWA) en el mismo", "portátil o en otra tableta;", "se conecta a cualquier nodo vivo"], 9.4, 13, "#fff"))
    b.append(arrow(480, 178, 200, 196, NAVY, True))
    b.append(box(260, 196, 214, 90, GOLD_L, GOLD, 10))
    b.append(text(367, 216, "Orquestador de escenarios", 11.5, 800, "#7a5a0a"))
    b.append(lines(367, 233, ["CLI: arranca nodos, inyecta fallos", "(kill -9, partición), reproduce", "semillas y guarda resultados"], 9.4, 13))
    b.append(arrow(367, 196, 289, 160, GOLD, True)); b.append(arrow(420, 196, 520, 180, GOLD, True))
    b.append(box(496, 196, 212, 90, "#fff", GREY, 10, dash=True))
    b.append(text(602, 216, "Recolector de métricas", 11.5, 800, GREY))
    b.append(lines(602, 233, ["entrega, bytes, recall P1,", "falsas fusiones, RTO →", "JSON/CSV + informe"], 9.4, 13))
    return _svg(720, 296, "".join(b), "Despliegue de la demostración")


# ---------------------------------------------------------------------------------------
def hoja_ruta():
    b = []
    L, R = 292, 706
    span = R - L
    rows = [("B0 · Cimientos", 0, 8, CYAN), ("B1 · Esqueleto vertical (8 pasos, stubs)", 8, 28, CYAN),
            ("B2 · Transporte real (códec, ACK, reintentos)", 22, 42, CYAN),
            ("B3 · Agentes 1–3 reales + deduplicación", 28, 56, NAVY),
            ("B4 · Resiliencia: sync y pérdida de nodo", 46, 70, GOLD),
            ("B5 · Tablero + agente 6 + aprobaciones", 54, 82, NAVY),
            ("B6 · Estrés, documentación y pitch", 72, 100, DARK)]
    y = 40
    for p in range(0, 101, 20):
        x = L + span * p / 100
        b.append(f'<line x1="{x}" y1="28" x2="{x}" y2="{40+len(rows)*34}" stroke="{LINE}" stroke-width="1"/>')
        b.append(text(x, 22, f"{p} %", 8.8, 400, GREY))
    for name, s, e, c in rows:
        b.append(text(L - 10, y + 15, name, 9.8, 700, INK, "end"))
        b.append(box(L + span * s / 100, y + 2, span * (e - s) / 100, 20, c, rx=5))
        y += 34
    # hitos
    def hito(p, label, row_y, dy=0):
        x = L + span * p / 100
        return (f'<path d="M{x},{row_y-7} l7,7 l-7,7 l-7,-7 z" fill="{RED}"/>')
    y_h = 40 + len(rows) * 34 + 14
    for p, lab, dy in [(28, "H1 · recorrido completo\ncon stubs", 0), (56, "H2 · agentes reales\ny dedup medida", 0), (70, "H3 · demo con una\ncondición adversa", 28), (100, "H4 · entrega", 0)]:
        x = L + span * p / 100
        b.append(f'<line x1="{x}" y1="{y_h-12}" x2="{x}" y2="40" stroke="{RED}" stroke-width="1" stroke-dasharray="3 3"/>')
        b.append(f'<path d="M{x},{y_h-9} l7,7 l-7,7 l-7,-7 z" fill="{RED}"/>')
        for i, ln in enumerate(lab.split("\n")):
            anchor = "end" if p == 100 else "middle"
            b.append(text(x if p != 100 else x + 4, y_h + 18 + dy + i * 11, ln, 8.8, 700, RED, anchor))
    b.append(text(8, y_h + 74, "Eje horizontal: porcentaje del tiempo disponible (escalar al plazo real del equipo).", 9, 400, GREY, "start", True))
    return _svg(720, y_h + 84, "".join(b), "Hoja de ruta por bloques de trabajo")


# ---------------------------------------------------------------------------------------
def pantallas():
    b = []
    SCR, SCR2 = "#101826", "#1B2538"

    def phone(x, title):
        out = box(x, 24, 206, 336, DARK, rx=22)
        out += box(x + 8, 34, 190, 316, SCR, rx=14)
        out += text(x + 103, 14, title, 10.5, 800, NAVY)
        return out

    def chipd(x, y, w, label, fill=SCR2, stroke="#3A4A66", fg="#E8EEF9", h=24, size=8.8):
        return box(x, y, w, h, fill, stroke, 6, sw=1) + text(x + w / 2, y + h / 2 + 3.2, label, size, 600, fg)

    # --- Pantalla 1
    x = 12
    b.append(phone(x, "1 · Reportar (≤ 3 toques)"))
    b.append(text(x + 20, 52, "SARD", 10, 800, GOLD, "start"))
    b.append(box(x + 130, 43, 52, 14, "none", "#E8EEF9", 3, sw=1))
    b.append(box(x + 133, 46, 8, 8, RED, rx=1))
    b.append(text(x + 160, 53.6, "17 %", 8.6, 700, "#E8EEF9"))
    b.append(text(x + 103, 74, "Modo ahorro activo", 8.4, 400, GOLD))
    b.append(f'<circle cx="{x+103}" cy="148" r="54" fill="{RED}"/>')
    b.append(f'<circle cx="{x+103}" cy="148" r="62" fill="none" stroke="{RED}" stroke-width="2" opacity="0.45"/>')
    b.append(text(x + 103, 158, "SOS", 30, 800, "#fff"))
    b.append(text(x + 103, 226, "Un toque: guarda y pone en cola", 8.8, 400, "#B8C4DA"))
    labs = ["Atrapado", "Herido", "Incendio", "Vía bloqueada", "Sin aire", "Menores / mayores"]
    for i, l in enumerate(labs):
        cx = x + 18 + (i % 2) * 88
        cy = 244 + (i // 2) * 30
        b.append(chipd(cx, cy, 82, l))
    # --- Pantalla 2
    x = 252
    b.append(phone(x, "2 · Añadir detalle (opcional)"))
    b.append(text(x + 20, 56, "✓ Ya está guardado", 10.5, 800, CYAN, "start"))
    b.append(text(x + 20, 71, "Puedes enviar más datos o salir.", 8.6, 400, "#B8C4DA", "start"))
    b.append(text(x + 20, 96, "¿Cuántas personas?", 9.4, 700, "#E8EEF9", "start"))
    for i, l in enumerate(["1", "2–3", "4–10", "+10"]):
        b.append(chipd(x + 20 + i * 42, 104, 38, l, CYAN if l == "2–3" else SCR2, CYAN if l == "2–3" else "#3A4A66", DARK if l == "2–3" else "#E8EEF9"))
    b.append(text(x + 20, 152, "Una frase (máx. 140)", 9.4, 700, "#E8EEF9", "start"))
    b.append(box(x + 20, 160, 160, 62, SCR2, "#3A4A66", 6, sw=1))
    b.append(lines(x + 28, 176, ["Edificio colapsado, hay", "una persona bajo la losa…"], 8.6, 12, "#B8C4DA", "start"))
    b.append(text(x + 20, 246, "Ubicación", 9.4, 700, "#E8EEF9", "start"))
    b.append(chipd(x + 20, 254, 160, "GPS ± 20 m · hace 6 s", SCR2, "#3A4A66", "#E8EEF9"))
    b.append(chipd(x + 20, 286, 160, "Enviar detalle (123 B)", CYAN, CYAN, DARK, 30, 9.6))
    b.append(text(x + 103, 334, "cada detalle es una revisión del mismo reporte", 8, 400, "#8795B0"))
    # --- Pantalla 3
    x = 492
    b.append(phone(x, "3 · Estado de entrega"))
    b.append(text(x + 20, 56, "Mis reportes", 10.5, 800, "#E8EEF9", "start"))
    # reporte 1
    b.append(box(x + 16, 66, 166, 94, SCR2, "#3A4A66", 8, sw=1))
    b.append(text(x + 26, 84, "#17 · SOS · atrapado", 9.2, 700, "#E8EEF9", "start"))
    b.append(box(x + 26, 92, 118, 18, GOLD, rx=9)); b.append(text(x + 85, 104.5, "Guardado en tu teléfono", 8.2, 800, DARK))
    for i in range(4):
        b.append(f'<circle cx="{x+36+i*38}" cy="128" r="5" fill="{CYAN if i < 1 else "none"}" stroke="{CYAN}" stroke-width="1.4"/>')
        if i < 3:
            b.append(f'<line x1="{x+41+i*38}" y1="128" x2="{x+69+i*38}" y2="128" stroke="#3A4A66" stroke-width="1.5"/>')
    b.append(text(x + 26, 148, "Sin señal · se enviará solo", 8.2, 400, "#B8C4DA", "start"))
    # reporte 2
    b.append(box(x + 16, 168, 166, 78, SCR2, "#3A4A66", 8, sw=1))
    b.append(text(x + 26, 186, "#16 · herido", 9.2, 700, "#E8EEF9", "start"))
    b.append(box(x + 26, 194, 104, 18, CYAN, rx=9)); b.append(text(x + 78, 206.5, "Recibido por SARD", 8.2, 800, DARK))
    for i in range(4):
        b.append(f'<circle cx="{x+36+i*38}" cy="230" r="5" fill="{CYAN}"/>')
        if i < 3:
            b.append(f'<line x1="{x+41+i*38}" y1="230" x2="{x+69+i*38}" y2="230" stroke="{CYAN}" stroke-width="1.5"/>')
    b.append(text(x + 103, 270, "Reintento en 40 s (con variación)", 8.4, 400, "#B8C4DA"))
    b.append(box(x + 16, 282, 166, 52, "none", "#3A4A66", 8, dash=True, sw=1))
    b.append(lines(x + 99, 301, ["Los reportes nunca se borran del", "teléfono; sólo cambian de estado."], 8.4, 12, "#8795B0"))
    return _svg(720, 366, "".join(b), "Wireframes de las tres pantallas de la app")


# ---------------------------------------------------------------------------------------
def tablero():
    b = []
    b.append(box(6, 6, 708, 348, "#fff", NAVY, 10, sw=1.6))
    b.append(box(6, 6, 708, 30, DARK, rx=10)); b.append(box(6, 22, 708, 14, DARK, rx=0))
    b.append(text(20, 26, "SARD · Tablero del coordinador (conectado al Nodo B)", 11, 800, GOLD, "start"))
    b.append(box(520, 12, 186, 18, "#1B2A52", rx=9))
    b.append(text(613, 25, "frescura: 2 de 3 nodos · hace 4 s", 8.8, 600, "#E8EEF9"))

    # Columna izquierda
    b.append(text(20, 56, "COLA PRIORIZADA", 10, 800, NAVY, "start"))
    items = [("P1", RED, "Edificio colapsado · Calle 20", "5 fuentes indep. · ±30 m · hace 3 min", "incertidumbre media"),
             ("P1", RED, "Persona atrapada · Cra. 23", "2 fuentes · sin ubicación · hace 9 min", "ubicación ausente"),
             ("P2", GOLD, "Incendio en vivienda · Av. Centro", "3 fuentes · ±80 m · hace 14 min", "contradicción"),
             ("P2", GOLD, "Herido en vía · km 4", "1 fuente · ±200 m · hace 21 min", "fuente única"),
             ("P3", CYAN, "Vía bloqueada · sector norte", "4 fuentes · ±60 m · hace 31 min", "")]
    y = 64
    for pr, col, t, s1, u in items:
        sel = (y == 64)
        b.append(box(14, y, 226, 46, BLUE_L if sel else "#fff", NAVY if sel else LINE, 7, sw=1.6 if sel else 1))
        b.append(box(20, y + 7, 26, 16, col, rx=4)); b.append(text(33, y + 19, pr, 9.4, 800, "#fff" if col != GOLD and col != CYAN else DARK))
        b.append(text(52, y + 18, t, 9.2, 700, INK, "start"))
        b.append(text(52, y + 31, s1, 8, 400, GREY, "start"))
        if u:
            b.append(text(52, y + 42, "⚠ " + u, 7.8, 700, "#9a6a00", "start"))
        y += 52
    b.append(box(14, 328, 226, 20, GOLD_L, GOLD, 6))
    b.append(text(127, 341, "+ 143 en seguimiento · 12 con incertidumbre alta · Ver todo", 7.9, 700, "#7a5a0a"))

    # Centro
    b.append(text(256, 56, "INCIDENTE A-17 · EVIDENCIA", 10, 800, NAVY, "start"))
    b.append(box(250, 64, 242, 90, "#fff", LINE, 7))
    obs = [("Obs. 1", "app · GPS ±20 m · «atrapada bajo la losa»"), ("Obs. 2", "app · GPS ±35 m · «edificio colapsado»"),
           ("Obs. 3", "radio (rumor) · sin ubicación · «hay humo»")]
    for i, (a, c) in enumerate(obs):
        b.append(text(258, 80 + i * 22, a, 8.4, 800, NAVY, "start"))
        b.append(text(258, 91 + i * 22, c, 7.8, 400, INK, "start"))
    b.append(box(250, 162, 242, 54, "#FDECEA", RED, 7))
    b.append(text(258, 178, "⚠ 1 contradicción conservada", 8.8, 800, RED, "start"))
    b.append(lines(258, 191, ["«puente transitable» (Obs. 5) vs.", "«puente colapsado» (Obs. 2, 4)"], 8, 11, INK, "start"))
    b.append(box(250, 224, 242, 124, BLUE_L, NAVY, 7))
    b.append(text(258, 240, "Por qué P1", 9.4, 800, NAVY, "start"))
    b.append(lines(258, 254, ["• indicador «atrapado» en 2 fuentes independientes",
                              "• ubicaciones compatibles (a 40 m, precisión ±35 m)",
                              "• 1 observación no independiente (copia de texto)",
                              "Confianza 0,82 · salida validada: citas OK"], 8, 12.5, INK, "start"))
    b.append(box(256, 314, 96, 26, "#fff", NAVY, 6)); b.append(text(304, 331, "Ver vínculos (3)", 8.6, 700, NAVY))

    # Derecha
    b.append(text(508, 56, "RECOMENDACIÓN (propuesta)", 10, 800, NAVY, "start"))
    b.append(box(502, 64, 204, 130, GOLD_L, GOLD, 7))
    b.append(lines(510, 80, ["Enviar equipo de rescate", "en estructuras (R-04),", "declarado disponible."], 9, 12.5, INK, "start", 700))
    b.append(text(510, 124, "Requisitos pendientes:", 8.4, 800, "#7a5a0a", "start"))
    b.append(lines(510, 136, ["• confirmar acceso por la vía", "• ubicación ±35 m: verificar en sitio"], 8.2, 11.5, INK, "start"))
    b.append(text(510, 176, "Requiere aprobación humana", 8.4, 800, RED, "start"))
    b.append(box(510, 200, 92, 26, CYAN, rx=6)); b.append(text(556, 217, "Aprobar", 10, 800, DARK))
    b.append(box(610, 200, 88, 26, "#fff", NAVY, 6)); b.append(text(654, 217, "Rechazar", 10, 700, NAVY))
    b.append(box(502, 238, 204, 110, "#fff", LINE, 7))
    b.append(text(510, 254, "NODOS", 9, 800, NAVY, "start"))
    for i, (n, st, c) in enumerate([("Nodo A", "sin contacto hace 2 min", RED), ("Nodo B", "activo (este tablero)", CYAN), ("Nodo C", "activo · sync hace 4 s", CYAN)]):
        yy = 270 + i * 22
        b.append(f'<circle cx="518" cy="{yy}" r="5" fill="{c}"/>')
        b.append(text(530, yy + 3.5, n, 8.8, 800, INK, "start"))
        b.append(text(576, yy + 3.5, st, 8.2, 400, GREY, "start"))
    b.append(text(510, 338, "Vista parcial: faltan eventos del Nodo A", 8, 700, "#9a6a00", "start"))
    return _svg(720, 362, "".join(b), "Wireframe del tablero del coordinador")


ALL = {
    "contexto": contexto,
    "app-capas": app_capas,
    "secuencia": secuencia,
    "nodo": nodo,
    "agentes": agentes,
    "trama": trama,
    "despliegue": despliegue,
    "hoja-ruta": hoja_ruta,
    "pantallas": pantallas,
    "tablero": tablero,
}

if __name__ == "__main__":
    import pathlib
    import sys
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in ALL.items():
        (out / f"{name}.svg").write_text(fn(), encoding="utf-8")
        print("ok", name)
