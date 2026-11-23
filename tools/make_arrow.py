"""Draws arrow.tga, the guide arrow: a white pointer with a black edge, pointing up.

Usage: python tools/make_arrow.py

White so the addon can tint it (green ahead, red behind); the black edge stays black under a
tint. Everything sits inside the circle the texture turns in, so no corner is cut off when
it rotates. 128x128, drawn at 4x and scaled down for smooth edges.
"""
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIZE, UP = 128, 4
S = SIZE * UP


def pts(points):
    return [(x * UP, y * UP) for x, y in points]


# tip, right barb, notch, left barb: all within 58 px of the middle (64, 64)
SHAPE = [(64, 8), (102, 106), (64, 86), (26, 106)]

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)
draw.polygon(pts(SHAPE), fill=(0, 0, 0, 255))
draw.line(pts(SHAPE + SHAPE[:2]), fill=(0, 0, 0, 255), width=7 * UP, joint="curve")
# the white body, inset from the edge
cx, cy = 64, 68
inner = [(cx + (x - cx) * 0.80, cy + (y - cy) * 0.80) for x, y in SHAPE]
draw.polygon(pts(inner), fill=(255, 255, 255, 255))

img = img.resize((SIZE, SIZE), Image.LANCZOS)
img.save(os.path.join(ROOT, "arrow.tga"))
far = max(((x - 64) ** 2 + (y - 64) ** 2) ** 0.5 for x in range(SIZE) for y in range(SIZE) if img.getpixel((x, y))[3] > 8)
print("wrote arrow.tga; furthest drawn pixel is %.1f px from the middle (must stay under 64)" % far)
