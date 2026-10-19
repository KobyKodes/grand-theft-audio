#!/usr/bin/env python3
"""Draws the thumbnail for Hear it → Own it (square, 1200x1200).

    python3 marketing/make_thumbnail.py   → marketing/thumbnail.png

Rendered at 2x and scaled down so the shapes come out smooth.
Original artwork only: no Apple or Shazam logos.
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "thumbnail.png")
SIZE = 1200
S = 2  # supersampling
W = SIZE * S

PINK = (250, 45, 85)
ORANGE = (255, 140, 60)
WHITE = (255, 255, 255)


def font(size, weight="Bold"):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size * S)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def background():
    img = Image.new("RGB", (W, W), (14, 11, 22))
    # soft colour glows
    glow = Image.new("RGB", (W, W), (0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.ellipse([-W * 0.25, -W * 0.3, W * 0.75, W * 0.55], fill=(120, 20, 60))
    g.ellipse([W * 0.45, W * 0.05, W * 1.3, W * 0.8], fill=(110, 45, 20))
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.16))
    return Image.blend(img, glow, 0.55)


def gradient_file(w, h, radius, fold):
    """A document with a folded top-right corner, pink→orange gradient.
    (A file you own, rather than anything that looks like an app icon.)"""
    grad = Image.new("RGB", (w, h))
    px = grad.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = lerp(PINK, ORANGE, (x / w + y / h) / 2)
    mask = Image.new("L", (w, h), 0)
    m = ImageDraw.Draw(mask)
    m.rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=255)
    m.polygon([(w - fold, -1), (w, -1), (w, fold)], fill=0)  # cut the corner
    return grad, mask


def music_note(d, cx, cy, h, color):
    """Beamed double note, drawn from shapes."""
    r = h * 0.17
    gap = h * 0.62
    stem_w = h * 0.075
    heads = [(cx - gap / 2, cy + h * 0.32), (cx + gap / 2, cy + h * 0.22)]
    for hx, hy in heads:
        d.ellipse([hx - r * 1.2, hy - r, hx + r * 1.2, hy + r], fill=color)
    tops = []
    for hx, hy in heads:
        x = hx + r * 1.2 - stem_w
        top = hy - h * 0.62
        d.rectangle([x, top, x + stem_w, hy], fill=color)
        tops.append((x, top))
    (x1, y1), (x2, y2) = tops
    beam = h * 0.13
    d.polygon([(x1, y1), (x2 + stem_w, y2), (x2 + stem_w, y2 + beam), (x1, y1 + beam)], fill=color)


def sound_waves(d, cx, cy, color):
    """A dot with three sound arcs: 'a song playing nearby'."""
    dot = 34 * S
    d.ellipse([cx - dot, cy - dot, cx + dot, cy + dot], fill=color)
    for i, radius in enumerate((95, 150, 205)):
        rr = radius * S
        alpha = 255 - i * 55
        d.arc([cx - rr, cy - rr, cx + rr, cy + rr], start=-50, end=50,
              fill=color + (alpha,), width=int(22 * S))
        d.arc([cx - rr, cy - rr, cx + rr, cy + rr], start=130, end=230,
              fill=color + (alpha,), width=int(22 * S))


def arrow(d, x0, x1, y, color):
    t = 20 * S
    d.rounded_rectangle([x0, y - t / 2, x1 - 40 * S, y + t / 2], radius=t / 2, fill=color)
    head = 52 * S
    d.polygon([(x1, y), (x1 - head * 1.15, y - head), (x1 - head * 1.15, y + head)], fill=color)


def main():
    img = background().convert("RGBA")
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    cy = int(W * 0.37)
    # left: sound waves
    sound_waves(d, int(W * 0.24), cy, WHITE)
    # middle: arrow
    arrow(d, int(W * 0.43), int(W * 0.56), cy, WHITE)
    img.alpha_composite(layer)

    # right: the song as a file you own (with a soft shadow)
    fw, fh = int(W * 0.235), int(W * 0.30)
    fold = int(fw * 0.30)
    radius = int(fw * 0.12)
    tx, ty = int(W * 0.62), cy - fh // 2
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([tx, ty + 24 * S, tx + fw, ty + fh + 24 * S],
                                             radius=radius, fill=(0, 0, 0, 150))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(30 * S)))
    grad, mask = gradient_file(fw, fh, radius, fold)
    img.paste(grad, (tx, ty), mask)
    nd = ImageDraw.Draw(img)
    # the folded-over corner
    nd.polygon([(tx + fw - fold, ty), (tx + fw - fold, ty + fold - radius * 0.4),
                (tx + fw - fold + radius * 0.4, ty + fold), (tx + fw, ty + fold)], fill=(255, 190, 170))
    music_note(nd, tx + fw / 2 - fw * 0.03, ty + fh * 0.53, fw * 0.55, WHITE)

    # title + tagline
    d = ImageDraw.Draw(img)
    d.text((W / 2, W * 0.665), "Hear it → Own it", font=font(128), fill=WHITE, anchor="mm")
    d.text((W / 2, W * 0.765), "Hear a song. It's in your Music library.", font=font(48, "Medium"),
           fill=(225, 222, 232), anchor="mm")

    # "for Mac" pill
    label = "for Mac"
    f = font(44, "Semibold")
    tw = d.textlength(label, font=f)
    pw, ph = tw + 80 * S, 86 * S
    px, py = W / 2 - pw / 2, W * 0.85
    d.rounded_rectangle([px, py, px + pw, py + ph], radius=ph / 2, outline=PINK, width=4 * S,
                        fill=(250, 45, 85, 40))
    d.text((W / 2, py + ph / 2 + 1 * S), label, font=f, fill=WHITE, anchor="mm")

    img.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS).save(OUT, optimize=True)
    print(OUT)


if __name__ == "__main__":
    main()
