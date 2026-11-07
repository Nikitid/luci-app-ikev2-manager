#!/usr/bin/env python3
"""Draws the Waypoint icon, variant B "Stone", for macOS and Windows.

Three lanes, the middle one taken. A light surface with an edge, free lanes in
line-strong, the path in patina; the graphite variant is the dark theme.
Colours are the design-code tokens ("Patina and graphite"), given in OKLCH and
converted here, so the icon follows the palette rather than copying hex values.

Edge rule (same roles as the interface, no new colours):
  macOS    16 and 32 pt cells (with @2x): small drawing, border-control of the
           theme. 64 px and up, light: line-strong plus Apple's shadow (baked
           into the .icns); graphite: border-control, no shadow.
  Windows  border-control, 1 px at every size, no shadow (nothing under a
           taskbar icon holds it); 16, 20, 24 and 32 px are pixel-aligned.

Writes next to this file (all committed):
  icon.png, Waypoint.icns            light Stone, macOS (the .icns needs iconutil)
  Waypoint.ico, Waypoint-dark.ico    light Stone and graphite, Windows
  icon-composer/                     layers for Icon Composer (macOS 26+)
  tray/                              Windows tray icons: panel x state, .ico
  menubar/                           macOS menu bar template PNGs per state

Needs Pillow. Run from anywhere.
"""
import math, pathlib, shutil, subprocess, tempfile
from PIL import Image, ImageChops, ImageDraw, ImageFilter

here = pathlib.Path(__file__).resolve().parent


# --- tokens -----------------------------------------------------------------

def oklch(l, c, h):
    a, b = c * math.cos(math.radians(h)), c * math.sin(math.radians(h))
    l_ = (l + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m_ = (l - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s_ = (l - 0.0894841775 * a - 1.2914855480 * b) ** 3
    lin = (4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
           -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
           -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_)
    def enc(v):
        v = min(1.0, max(0.0, v))
        return 12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055
    return tuple(round(enc(v) * 255) for v in lin)


THEMES = {
    'light': dict(surface=oklch(0.993, 0.002, 85), line_strong=oklch(0.800, 0.005, 85),
                  border=oklch(0.520, 0.010, 250),  # border-control = text-3
                  accent=oklch(0.500, 0.075, 195), danger=oklch(0.480, 0.130, 28),
                  ink=oklch(0.250, 0.012, 250)),
    'dark': dict(surface=oklch(0.265, 0.006, 255), line_strong=oklch(0.450, 0.010, 255),
                 border=oklch(0.665, 0.008, 255),
                 accent=oklch(0.760, 0.070, 195), danger=oklch(0.740, 0.120, 28),
                 ink=(255, 255, 255)),
}


def rgba(rgb, alpha=255):
    return tuple(rgb) + (alpha,)


# --- drawing primitives -----------------------------------------------------

def reduce(image, size):
    return image.resize((size, size), Image.LANCZOS)


def rrect(d, box, radius, fill):
    d.rounded_rectangle(box, radius=radius, fill=fill)


def small(n, theme, edge):
    """Pixel-aligned small drawing for n = 16, 20, 24 or 32 (n >= 32 scales the 32 one).

    Drawn at 16x and reduced with a box filter, so whole-pixel geometry stays crisp.
    """
    t = THEMES[theme]
    k = 16
    scale = n / 32 if n > 32 else 1
    g = 32 if n >= 32 else n
    img = Image.new('RGBA', (n * k, n * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    p = lambda v: v * scale * k
    if g == 32:
        inset, radius = 2, 6
        rrect(d, [p(inset), p(inset), p(32 - inset) - 1, p(32 - inset) - 1], p(radius + 0.5), rgba(edge))
        rrect(d, [p(inset + 1), p(inset + 1), p(32 - inset - 1) - 1, p(32 - inset - 1) - 1], p(radius - 0.5), rgba(t['surface']))
        for y in (9, 21):
            rrect(d, [p(8), p(y), p(24) - 1, p(y + 2) - 1], p(1), rgba(t['line_strong']))
        rrect(d, [p(8), p(15), p(19) - 1, p(17) - 1], p(1), rgba(t['accent']))
        d.polygon([(p(18), p(11.5)), (p(23.5), p(16)), (p(18), p(20.5))], fill=rgba(t['accent']))
    else:
        m = {16: 4, 20: 5, 24: 6}[g]
        inset, radius = {16: (1, 3), 20: (1, 4), 24: (2, 4)}[g]
        rrect(d, [p(inset), p(inset), p(g - inset) - 1, p(g - inset) - 1], p(radius + 0.5), rgba(edge))
        rrect(d, [p(inset + 1), p(inset + 1), p(g - inset - 1) - 1, p(g - inset - 1) - 1], p(radius - 0.5), rgba(t['surface']))
        top, bottom, mid = m, g - m - 1, g // 2 - 1       # one-pixel lanes, two-pixel path
        for y in (top, bottom):
            d.rectangle([p(m), p(y), p(g - m) - 1, p(y + 1) - 1], fill=rgba(t['line_strong']))
        tip = g - m + 1
        base = tip - (bottom - top - 1) // 2 - 1
        d.rectangle([p(m), p(mid), p(base) - 1, p(mid + 2) - 1], fill=rgba(t['accent']))
        d.polygon([(p(base - 1), p(top + 1)), (p(base), p(top + 1)), (p(tip), p(g / 2)),
                   (p(base), p(bottom)), (p(base - 1), p(bottom))], fill=rgba(t['accent']))
    return img.resize((n, n), Image.BOX)


def large(size, theme, edge, edge_px=None, shadow=False):
    """The large drawing on the 1024 grid, rendered at `size`.

    edge_px: fixed edge width in output pixels (Windows: 1), else 8 of 1024.
    """
    t = THEMES[theme]
    k = max(1, 4096 // size) if size < 4096 else 1
    big = size * k
    u = big / 1024
    img = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if edge_px is None:
        o, w = 100 * u, 8 * u
        radius = 192 * u
    else:
        o = round(104 * size / 1024) * k - 0                # snapped to a whole pixel
        w, radius = edge_px * k, 188 * u
    rrect(d, [o, o, big - o - 1, big - o - 1], radius, rgba(edge))
    rrect(d, [o + w, o + w, big - o - w - 1, big - o - w - 1], radius - w, rgba(t['surface']))
    for y in (337, 623):
        rrect(d, [276 * u, y * u, 748 * u, (y + 64) * u], 32 * u, rgba(t['line_strong']))
    rrect(d, [276 * u, 480 * u, 684 * u, 544 * u], 32 * u, rgba(t['accent']))
    d.polygon([(775 * u, 512 * u), (657 * u, 421 * u), (657 * u, 603 * u)], fill=rgba(t['accent']))
    if shadow:
        alpha = img.getchannel('A')
        blur = alpha.filter(ImageFilter.GaussianBlur(14 * u)).point(lambda v: round(v * 0.30))
        cast = Image.new('RGBA', (big, big), (0, 0, 0, 0))
        cast.putalpha(ImageChops.offset(blur, 0, round(10 * u)))
        cast.alpha_composite(img)
        img = cast
    return img.resize((size, size), Image.BOX if edge_px else Image.LANCZOS) if k > 1 else img


# --- macOS ------------------------------------------------------------------

def mac_cell(px, theme):
    """One .iconset cell by pixel size. 16 and 32 pt cells (16, 32, 64 px) use the small drawing."""
    t = THEMES[theme]
    if px <= 64:
        return small(px, theme, t['border'])
    edge = t['line_strong'] if theme == 'light' else t['border']
    return large(px, theme, edge, shadow=(theme == 'light'))


# --- Windows ----------------------------------------------------------------

def win_cell(px, theme):
    t = THEMES[theme]
    if px in (16, 20, 24, 32):
        return small(px, theme, t['border'])
    return large(px, theme, t['border'], edge_px=1)


WIN_SIZES = (16, 20, 24, 32, 48, 64, 256)


def save_ico(path, cells):
    """An .ico of PNG entries, one per cell, written as drawn (Pillow would resize them from one)."""
    import io, struct
    blobs = []
    for cell in cells:
        buffer = io.BytesIO()
        cell.save(buffer, format='PNG')
        blobs.append(buffer.getvalue())
    out = struct.pack('<HHH', 0, 1, len(cells))
    offset = 6 + 16 * len(cells)
    for cell, blob in zip(cells, blobs):
        size = 0 if cell.width >= 256 else cell.width
        out += struct.pack('<BBBBHHII', size, size, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    path.write_bytes(out + b''.join(blobs))


# --- one-colour glyphs: Windows tray and macOS menu bar ---------------------

STATES = ('open', 'off', 'connecting', 'attention')


def glyph(n, state, ink, danger, ink_alpha=255):
    """Two lines and an arrow, one colour. open: arrow filled; off: pale contour;
    connecting: the middle line broken; attention: contour plus a danger dot."""
    k = 16
    img = Image.new('RGBA', (n * k, n * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    u = n / 16 * k
    w = max(1, round(n / 16)) * k                    # stroke, whole pixels
    pale = round(ink_alpha * 0.55) if state == 'off' else ink_alpha
    c = rgba(ink, pale)
    x0, x1 = 2 * u, 14 * u
    for y in (3.5, 12.5):
        d.rectangle([x0, y * u - w / 2, x1 - 1, y * u + w / 2 - 1], fill=c)
    mid, h = 8 * u, 3.2 * u
    tip, base = 14 * u, 10 * u
    stem_end = base + 0.01 * u
    if state == 'connecting':
        d.rectangle([x0, mid - w / 2, x0 + 2 * u - 1, mid + w / 2 - 1], fill=c)
        d.rectangle([x0 + 4 * u, mid - w / 2, stem_end, mid + w / 2 - 1], fill=c)
    else:
        d.rectangle([x0, mid - w / 2, stem_end, mid + w / 2 - 1], fill=c)
    head = [(base, mid - h), (tip, mid), (base, mid + h)]
    if state in ('open', 'connecting'):
        d.polygon(head, fill=c)
    else:
        d.line(head + [head[0]], fill=c, width=w, joint='curve')
    if state == 'attention':
        cx, cy, r = 12.5 * u, 12.5 * u, 2.4 * u
        d.ellipse([cx - r - u * 0.6, cy - r - u * 0.6, cx + r + u * 0.6, cy + r + u * 0.6], fill=(0, 0, 0, 0))
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=rgba(danger))
    return img.resize((n, n), Image.BOX)


# --- layers for Icon Composer ----------------------------------------------

def layers(theme):
    """Base, lanes and path as separate 1024 layers (macOS 26 draws the edge highlight and shadow itself)."""
    t = THEMES[theme]
    base = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    rrect(ImageDraw.Draw(base), [104, 104, 919, 919], 188, rgba(t['surface']))
    lanes = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    dl = ImageDraw.Draw(lanes)
    for y in (337, 623):
        rrect(dl, [276, y, 748, y + 64], 32, rgba(t['line_strong']))
    path = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    dp = ImageDraw.Draw(path)
    rrect(dp, [276, 480, 684, 544], 32, rgba(t['accent']))
    dp.polygon([(775, 512), (657, 421), (657, 603)], fill=rgba(t['accent']))
    return {'base': base, 'lanes': lanes, 'path': path}


def main():
    # macOS: icon.png (1024, light) and the .icns for macOS 14-25 (light only).
    mac = mac_cell(1024, 'light')
    mac.save(here / 'icon.png')
    with tempfile.TemporaryDirectory() as work:
        iconset = pathlib.Path(work) / 'Waypoint.iconset'
        iconset.mkdir()
        for pt in (16, 32, 128, 256, 512):
            mac_cell(pt, 'light').save(iconset / f'icon_{pt}x{pt}.png')
            mac_cell(pt * 2, 'light').save(iconset / f'icon_{pt}x{pt}@2x.png')
        if shutil.which('iconutil'):
            subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(here / 'Waypoint.icns')], check=True)

    # Windows: light Stone for the installer and the Start menu; graphite for the dark taskbar.
    save_ico(here / 'Waypoint.ico', [win_cell(n, 'light') for n in WIN_SIZES])
    save_ico(here / 'Waypoint-dark.ico', [win_cell(n, 'dark') for n in WIN_SIZES])

    # Icon Composer layers.
    for theme in ('light', 'dark'):
        folder = here / 'icon-composer' / theme
        folder.mkdir(parents=True, exist_ok=True)
        for name, layer in layers(theme).items():
            layer.save(folder / f'{name}.png')

    # Windows tray: dark mark on the light panel, white on the dark one.
    tray = here / 'tray'
    tray.mkdir(exist_ok=True)
    for panel in ('light', 'dark'):
        t = THEMES[panel]
        for state in STATES:
            cells = [glyph(n, state, t['ink'], t['danger']) for n in (16, 20, 24, 32)]
            save_ico(tray / f'tray-{panel}-{state}.ico', cells)

    # macOS menu bar: black template images, 18 pt at 1x and 2x.
    bar = here / 'menubar'
    bar.mkdir(exist_ok=True)
    for state in STATES:
        glyph(18, state, (0, 0, 0), (0, 0, 0)).save(bar / f'menubar-{state}.png')
        glyph(36, state, (0, 0, 0), (0, 0, 0)).save(bar / f'menubar-{state}@2x.png')


if __name__ == '__main__':
    main()
