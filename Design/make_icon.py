"""Draws Unreeled's app icon: a film reel with its film unspooling, white on steel blue.

    python3 Design/make_icon.py

Writes Unreeled/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024 x 1024, opaque) and a
preview of the icon at home-screen sizes next to this script. Needs Pillow.
"""

import math
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # Drawn 4x larger, then scaled down, for smooth edges.
TOP = (0x4B, 0x82, 0xB0)
BOTTOM = (0x2E, 0x5B, 0x82)

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "Unreeled/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
PREVIEW = Path(__file__).resolve().parent / "icon-preview.png"


def s(value):
    return value * SCALE


def background(width, height):
    gradient = Image.linear_gradient("L").resize((width, height))
    return Image.composite(Image.new("RGB", (width, height), BOTTOM), Image.new("RGB", (width, height), TOP), gradient)


def rotated_rect(center, along, across, unit, normal):
    cx, cy = center
    ux, uy = unit
    nx, ny = normal
    a, c = along / 2, across / 2
    return [
        (cx + ux * a + nx * c, cy + uy * a + ny * c),
        (cx + ux * a - nx * c, cy + uy * a - ny * c),
        (cx - ux * a - nx * c, cy - uy * a - ny * c),
        (cx - ux * a + nx * c, cy - uy * a + ny * c),
    ]


def motif():
    """White where the reel and film are, black elsewhere."""
    mask = Image.new("L", (s(SIZE), s(SIZE)), 0)
    draw = ImageDraw.Draw(mask)

    reel_center, reel_radius = (392, 382), 244

    # The film: it leaves the bottom of the reel along a tangent and runs off the right edge, with
    # sprocket holes on both sides. Drawn first, so the reel covers where it starts.
    angle = math.radians(27)
    unit = (math.cos(angle), math.sin(angle))
    normal = (-unit[1], unit[0])  # Away from the reel's centre, on the film's side.
    width = 176
    inner, outer = reel_radius - width, reel_radius
    cx, cy = reel_center

    def at(t, offset):
        return (cx + normal[0] * offset + unit[0] * t, cy + normal[1] * offset + unit[1] * t)

    band = [at(0, inner), at(0, outer), at(1300, outer), at(1300, inner)]
    draw.polygon([(s(x), s(y)) for x, y in band], fill=255)
    t = 20.0
    while t < 1300:
        for offset in (inner + 30, outer - 30):
            corners = rotated_rect(at(t, offset), 34, 26, unit, normal)
            draw.polygon([(s(x), s(y)) for x, y in corners], fill=0)
        t += 64

    # The reel on top, with five round holes and a hub.
    draw.ellipse([s(cx - reel_radius), s(cy - reel_radius), s(cx + reel_radius), s(cy + reel_radius)], fill=255)
    for k in range(5):
        angle = math.radians(-90 + k * 72)
        hx, hy = cx + math.cos(angle) * 140, cy + math.sin(angle) * 140
        draw.ellipse([s(hx - 60), s(hy - 60), s(hx + 60), s(hy + 60)], fill=0)
    draw.ellipse([s(cx - 34), s(cy - 34), s(cx + 34), s(cy + 34)], fill=0)
    return mask


def icon():
    big = background(s(SIZE), s(SIZE))
    big.paste((255, 255, 255), (0, 0), motif())
    return big.resize((SIZE, SIZE), Image.LANCZOS)


def rounded(image, size):
    small = image.resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1], radius=int(size * 4 * 0.2237), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(small, (0, 0), mask.resize((size, size), Image.LANCZOS))
    return out


def preview(image):
    sizes = [360, 180, 120, 60]
    sheet = Image.new("RGB", (sum(sizes) + 40 * (len(sizes) + 1), 440), (0xF2, 0xF2, 0xF7))
    x = 40
    for size in sizes:
        tile = rounded(image, size)
        sheet.paste(tile, (x, 40 + (360 - size) // 2), tile)
        x += size + 40
    return sheet


if __name__ == "__main__":
    image = icon()
    image.save(ICON)
    preview(image).save(PREVIEW)
    print(f"Wrote {ICON.relative_to(ROOT)} and {PREVIEW.relative_to(ROOT)}")
