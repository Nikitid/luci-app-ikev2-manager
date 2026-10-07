#!/usr/bin/env python3
"""Draws the Private Lane icon and writes icon.png, PrivateLane.icns and PrivateLane.ico.

Three lanes, one of them taken. Needs Pillow; the .icns is assembled by the
macOS iconutil. Run from anywhere; the results are committed.
"""
import pathlib, shutil, subprocess, tempfile
from PIL import Image, ImageDraw

here = pathlib.Path(__file__).resolve().parent
S = 4096  # drawn large, reduced for smooth edges


def draw():
    image = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    # Background: a rounded square with a vertical blend.
    blend = Image.new('RGBA', (S, S))
    top, bottom = (22, 96, 201), (10, 46, 120)
    pixels = ImageDraw.Draw(blend)
    for y in range(S):
        t = y / (S - 1)
        pixels.line([(0, y), (S, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    mask = Image.new('L', (S, S), 0)
    inset = round(S * 0.098)
    ImageDraw.Draw(mask).rounded_rectangle([inset, inset, S - inset, S - inset], radius=round(S * 0.185), fill=255)
    image.paste(blend, (0, 0), mask)
    d = ImageDraw.Draw(image)
    left, right, bar = S * 0.27, S * 0.73, S * 0.062
    dim, lit = (96, 142, 214, 255), (255, 255, 255, 255)
    for centre in (0.36, 0.64):
        d.rounded_rectangle([left, S * centre - bar / 2, right, S * centre + bar / 2], radius=bar / 2, fill=dim)
    # The taken lane, with its direction.
    y, head = S * 0.50, S * 0.105
    d.rounded_rectangle([left, y - bar / 2, right - head * 0.6, y + bar / 2], radius=bar / 2, fill=lit)
    d.polygon([(right + head * 0.25, y), (right - head * 0.85, y - head * 0.85), (right - head * 0.85, y + head * 0.85)], fill=lit)
    return image


master = draw().resize((1024, 1024), Image.LANCZOS)
master.save(here / 'icon.png')
master.save(here / 'PrivateLane.ico', sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)])
with tempfile.TemporaryDirectory() as work:
    iconset = pathlib.Path(work) / 'PrivateLane.iconset'
    iconset.mkdir()
    for n in (16, 32, 128, 256, 512):
        master.resize((n, n), Image.LANCZOS).save(iconset / f'icon_{n}x{n}.png')
        master.resize((n * 2, n * 2), Image.LANCZOS).save(iconset / f'icon_{n}x{n}@2x.png')
    if shutil.which('iconutil'):
        subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(here / 'PrivateLane.icns')], check=True)
