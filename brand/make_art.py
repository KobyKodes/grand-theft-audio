#!/usr/bin/env python3
"""Draws the Grand Theft Audio app icon and README thumbnail from the logo masters.

    python3 brand/make_art.py   → brand/icon/GrandTheftAudio.icns, brand/icon/icon-1024.png,
                                  brand/thumbnail.png (used by the README)

Needs rsvg-convert (brew install librsvg), Pillow, and iconutil (comes with macOS).
"""
import os
import re
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
HEAT, INK, PLUM = "#FF3B5C", "#160C1A", "#5A1A45"


def master(name, color):
    with open(os.path.join(HERE, "logo", name)) as f:
        svg = f.read()
    return re.sub(r'fill="#000"', f'fill="{color}"', svg)


def inner(svg):
    """The drawing inside an <svg>, without <title>."""
    body = svg[svg.index(">") + 1:svg.rindex("</svg>")]
    return re.sub(r"<title>.*?</title>", "", body)


def render(svg, out, w, h):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg)
    subprocess.run(["rsvg-convert", "-w", str(w), "-h", str(h), "-o", out, f.name], check=True)
    os.unlink(f.name)


def glow(cx, cy, r):
    return (f'<defs><radialGradient id="g" cx="{cx}" cy="{cy}" r="{r}" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{PLUM}"/><stop offset="1" stop-color="{INK}"/></radialGradient></defs>')


def icon():
    """macOS-style icon: ink tile (824 of 1024, Big Sur grid), heat sack with a soft plum glow."""
    sack = inner(master("gta-symbol.svg", HEAT))
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
           + glow(512, 470, 420)
           + '<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#g)"/>'
           # symbol ink is 184×212 on its 256 canvas; scale to ~470 tall, centre optically
           + f'<g transform="translate(512 500) scale(2.2) translate(-128 -128)">{sack}</g></svg>')
    out_dir = os.path.join(HERE, "icon")
    os.makedirs(out_dir, exist_ok=True)
    png = os.path.join(out_dir, "icon-1024.png")
    render(svg, png, 1024, 1024)

    tmp = tempfile.mkdtemp()
    iconset = os.path.join(tmp, "GrandTheftAudio.iconset")
    os.makedirs(iconset)
    src = Image.open(png)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            src.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(out_dir, "GrandTheftAudio.icns")],
                   check=True)
    shutil.rmtree(tmp)


def thumbnail():
    """README thumbnail, 1200×1200: stacked lockup (heat + white) on ink, tagline, 'for Mac' pill."""
    W = 1200
    stacked = master("gta-stacked-reversed.svg", HEAT)
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', stacked).group(1).split()]
    lw, lh = vb[2], vb[3]
    s = 640 / lh  # lockup 640 tall
    x, y = (W - lw * s) / 2, 150
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {W}">'
           + glow(W / 2, 380, 620)
           + f'<rect width="{W}" height="{W}" fill="url(#g)"/>'
           + f'<g transform="translate({x:.1f} {y}) scale({s:.4f})">{inner(stacked)}</g></svg>')
    out = os.path.join(HERE, "thumbnail.png")
    render(svg, out, W, W)

    img = Image.open(out).convert("RGBA")
    d = ImageDraw.Draw(img)

    def font(size, weight):
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
        try:
            f.set_variation_by_name(weight)
        except Exception:
            pass
        return f

    d.text((W / 2, 900), "Hear a song. It's in your Music library.", font=font(46, "Medium"),
           fill=(232, 224, 232), anchor="mm")
    label, f = "for Mac", font(40, "Semibold")
    tw = d.textlength(label, font=f)
    d.rounded_rectangle([W / 2 - tw / 2 - 30, 975, W / 2 + tw / 2 + 30, 1045], radius=35,
                        outline=HEAT, width=4)
    d.text((W / 2, 1010), label, font=f, fill=HEAT, anchor="mm")
    img.save(out)


if __name__ == "__main__":
    icon()
    thumbnail()
    print("wrote brand/icon/GrandTheftAudio.icns, brand/icon/icon-1024.png, brand/thumbnail.png")
