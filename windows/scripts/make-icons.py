#!/usr/bin/env python3
"""Generate tray.png and icon.ico from the repo's Mac app icon (assets/app-1024.png)."""
import os
from PIL import Image, ImageDraw

root = os.path.join(os.path.dirname(__file__), '..')
assets = os.path.join(root, 'assets')
build = os.path.join(root, 'buildResources')
os.makedirs(build, exist_ok=True)

src = Image.open(os.path.join(assets, 'app-1024.png')).convert('RGBA')
sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
src.save(os.path.join(build, 'icon.ico'), sizes=sizes)
src.resize((512, 512), Image.LANCZOS).save(os.path.join(build, 'icon.png'))

# Tray icon: the blue Clicky triangle (same shape as the on-screen cursor), 4x supersampled.
S = 128
img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
import math
cx, cy = S / 2, S / 2
r = S * 0.34
pts = [(0, -r * 1.15), (-r, r * 0.8), (r, r * 0.8)]
ang = math.radians(-35)
rot = [(cx + x * math.cos(ang) - y * math.sin(ang), cy + x * math.sin(ang) + y * math.cos(ang)) for x, y in pts]
d.polygon(rot, fill=(51, 128, 255, 255))
img.resize((32, 32), Image.LANCZOS).save(os.path.join(assets, 'tray.png'))
img.save(os.path.join(assets, 'tray@4x.png'))
print('icons written')
