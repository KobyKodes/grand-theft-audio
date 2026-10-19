#!/usr/bin/env python3
"""Draws the app icon for Hear it → Own it (macOS style, 1024x1024).

    python3 marketing/icon/make_icon.py   → marketing/icon/icon_1024.png
                                            marketing/icon/HearItOwnIt.icns

One spiral: the outer turns are loose dots (a song in the air), the dots stretch
into dashes, then close into solid vinyl grooves around a pink→orange label
(the file you keep). Rendered at 4x and scaled down.
Original artwork only: no Apple or Shazam logos.
"""
import math
import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SIZE = 1024
S = 4
W = SIZE * S
C = W / 2

PINK = (250, 45, 85)
ORANGE = (255, 140, 60)

# macOS Big Sur+ icon grid: 824px body centred on a 1024 canvas
BODY = 824 * S
TOP = (W - BODY) / 2


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def squircle_mask():
    """Superellipse (n=5) body, close to the continuous-corner macOS icon shape."""
    mask = Image.new("L", (W, W), 0)
    n = 5.0
    a = BODY / 2
    pts = []
    for i in range(1440):
        t = 2 * math.pi * i / 1440
        ct, st = math.cos(t), math.sin(t)
        pts.append((C + a * math.copysign(abs(ct) ** (2 / n), ct),
                    C + a * math.copysign(abs(st) ** (2 / n), st)))
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    return mask


def radial(size, center, radius, inner, outer, power=1.0):
    """RGB radial gradient image."""
    small = 256
    img = Image.new("RGB", (small, small))
    px = img.load()
    k = small / size
    for y in range(small):
        for x in range(small):
            d = math.hypot(x / k - center[0], y / k - center[1]) / radius
            px[x, y] = lerp(inner, outer, min(1.0, d) ** power)
    return img.resize((size, size), Image.BICUBIC)


def background():
    base = radial(W, (C * 0.7, C * 0.55), W * 0.95, (44, 16, 40), (10, 7, 16), 0.9)
    glow = Image.new("RGB", (W, W), (0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.ellipse([-W * 0.2, -W * 0.25, W * 0.6, W * 0.45], fill=(125, 22, 62))
    g.ellipse([W * 0.55, W * 0.6, W * 1.25, W * 1.25], fill=(120, 50, 18))
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.13))
    return ImageChops.add(base, Image.blend(Image.new("RGB", (W, W)), glow, 0.55))


# ---------- the spiral ----------

R_OUT = BODY * 0.455     # where the scattered dots begin
R_DISC = BODY * 0.335    # solid vinyl from here inwards
R_IN = BODY * 0.165      # label edge
TURNS = 13


def spiral_marks():
    """Walks the spiral outside→in by arc length, returning mark segments.

    Each mark is (points, width, alpha). Dash duty cycle grows from ~0 (dots)
    to 1 (continuous groove) as the spiral tightens toward the disc."""
    pitch = (R_OUT - R_IN) / TURNS
    theta_max = TURNS * 2 * math.pi
    start = -math.pi * 0.62  # outermost end sits upper-left

    def point(th):
        r = R_OUT - pitch * th / (2 * math.pi)
        a = start + th
        return C + r * math.cos(a), C + r * math.sin(a), r

    marks = []
    th = 0.0
    period = 34.0 * S         # arc length of one dot+gap cycle
    while th < theta_max:
        x, y, r = point(th)
        # 0 in the air, 1 once we reach the disc edge
        t = smooth((R_OUT - r) / (R_OUT - R_DISC))
        duty = 0.0 + t ** 1.6
        width = (4.2 + 1.8 * t) * S if r > R_DISC else 2.6 * S
        alpha = int(40 + 215 * t ** 0.8) if r > R_DISC else 0
        step_len = period
        d_th = step_len / max(r, 1)
        if alpha:
            dash = max(duty * period, 0.001)
            pts = []
            n = max(2, int(dash / (2 * S)))
            for i in range(n + 1):
                px, py, _ = point(th + (dash / r) * i / n)
                pts.append((px, py))
            marks.append((pts, width, alpha))
        th += d_th
        # period tightens as the sound gathers
        period = (34.0 - 18.0 * t) * S
    return marks


def draw_air(layer):
    d = ImageDraw.Draw(layer)
    for pts, w, a in spiral_marks():
        col = (255, 244, 240, a)
        if len(pts) > 1 and math.dist(pts[0], pts[-1]) > w * 0.3:
            d.line(pts, fill=col, width=int(w), joint="curve")
            for p in (pts[0], pts[-1]):
                d.ellipse([p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2], fill=col)
        else:
            p = pts[0]
            d.ellipse([p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2], fill=col)


def disc():
    """The condensed record: black vinyl, fine grooves, conic sheen."""
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    R = R_DISC + 3 * S
    d.ellipse([C - R, C - R, C + R, C + R], fill=(14, 11, 16, 255))
    # grooves: exact concentric steps
    step = 7.0 * S
    r = R - 5 * S
    i = 0
    while r > R_IN + 10 * S:
        shade = 38 if i % 3 else 52
        d.ellipse([C - r, C - r, C + r, C + r], outline=(shade, shade - 6, shade - 2, 255), width=int(1.4 * S))
        r -= step
        i += 1
    # a slightly brighter rim
    d.ellipse([C - R, C - R, C + R, C + R], outline=(70, 58, 66, 255), width=int(2 * S))

    # conic sheen: two opposed soft wedges of light
    sheen = Image.new("L", (W, W), 0)
    s = ImageDraw.Draw(sheen)
    for a0 in (-60, 120):
        s.pieslice([C - R, C - R, C + R, C + R], a0 - 16, a0 + 16, fill=120)
    sheen = sheen.filter(ImageFilter.GaussianBlur(26 * S))
    ring = Image.new("L", (W, W), 0)
    ImageDraw.Draw(ring).ellipse([C - R, C - R, C + R, C + R], fill=255)
    ImageDraw.Draw(ring).ellipse([C - R_IN, C - R_IN, C + R_IN, C + R_IN], fill=0)
    sheen = ImageChops.multiply(sheen, ring)
    light = Image.new("RGBA", (W, W), (255, 225, 230, 0))
    light.putalpha(sheen.point(lambda v: int(v * 0.55)))
    return Image.alpha_composite(layer, light)


def label():
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    size = int(R_IN * 2)
    grad = Image.new("RGB", (size, size))
    px = grad.load()
    for y in range(size):
        for x in range(size):
            px[x, y] = lerp(PINK, ORANGE, smooth((x + y) / (2 * size) * 1.15 - 0.05))
    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    md.ellipse([0, 0, size - 1, size - 1], fill=255)
    hole = 15 * S
    h = size / 2
    grad = grad.convert("RGBA")
    grad.putalpha(mask)
    ox = int(C - R_IN)
    layer.alpha_composite(grad, (ox, ox))
    d = ImageDraw.Draw(layer)
    # one thin inner ring on the label, like a pressed edge
    r = R_IN * 0.72
    d.ellipse([C - r, C - r, C + r, C + r], outline=(255, 255, 255, 70), width=int(1.6 * S))
    # spindle hole, with a darker rim so it reads as a hole, not a dot
    d.ellipse([C - hole, C - hole, C + hole, C + hole], fill=(20, 12, 20, 255), outline=(150, 40, 50, 255), width=int(2 * S))
    return layer


def label_glow():
    g = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    r = R_IN * 1.5
    ImageDraw.Draw(g).ellipse([C - r, C - r, C + r, C + r], fill=(255, 80, 70, 55))
    return g.filter(ImageFilter.GaussianBlur(22 * S))


def compose():
    mask = squircle_mask()
    body = background().convert("RGBA")

    air = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw_air(air)
    body = Image.alpha_composite(body, air)

    # disc shadow, then disc, glow, label
    sh = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    R = R_DISC + 3 * S
    ImageDraw.Draw(sh).ellipse([C - R, C - R + 14 * S, C + R, C + R + 14 * S], fill=(0, 0, 0, 170))
    body = Image.alpha_composite(body, sh.filter(ImageFilter.GaussianBlur(18 * S)))
    body = Image.alpha_composite(body, disc())
    body = Image.alpha_composite(body, label_glow())
    body = Image.alpha_composite(body, label())

    # hairline highlight along the top edge of the squircle
    edge = Image.new("RGBA", (W, W), (255, 255, 255, 0))
    inner = mask.filter(ImageFilter.MinFilter(int(3 * S) | 1))
    rim = ImageChops.subtract(mask, inner)
    fade = Image.linear_gradient("L").resize((W, W)).point(lambda v: int(max(0, 255 - v * 2.2) * 0.35))
    edge.putalpha(ImageChops.multiply(rim, fade))
    body = Image.alpha_composite(body, edge)

    icon = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    icon.paste(body, (0, 0), mask)

    # drop shadow per Apple's icon grid
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    shadow.putalpha(mask.point(lambda v: int(v * 0.45)))
    shadow = ImageChops.offset(shadow, 0, 10 * S).filter(ImageFilter.GaussianBlur(14 * S))
    out = Image.alpha_composite(shadow, icon)
    return out.resize((SIZE, SIZE), Image.LANCZOS)


def make_icns(png):
    if not shutil.which("iconutil"):
        return None
    tmp = tempfile.mkdtemp()
    iconset = os.path.join(tmp, "HearItOwnIt.iconset")
    os.makedirs(iconset)
    img = Image.open(png)
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    out = os.path.join(HERE, "HearItOwnIt.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    shutil.rmtree(tmp)
    return out


if __name__ == "__main__":
    png = os.path.join(HERE, "icon_1024.png")
    compose().save(png)
    print(png)
    icns = make_icns(png)
    if icns:
        print(icns)
