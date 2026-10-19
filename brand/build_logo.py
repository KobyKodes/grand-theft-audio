#!/usr/bin/env python3
"""Builds the Grand Theft Audio logo masters in brand/logo: symbol, small-size symbol,
horizontal, stacked and wordmark, in black, colour and reversed.

    pip3 install fonttools && python3 brand/build_logo.py

Everything is filled outlines (no strokes, no <text>) and the note is a real hole (evenodd).
The wordmark is outlined from DIN Condensed Bold, which ships with macOS.
"""
import math
import os
import re

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logo")
FONT = "/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"
HEAT, INK, WHITE = "#FF3B5C", "#160C1A", "#FFFFFF"
SKEW = 9  # degrees, wordmark lean
DY = -4   # optical lift for the symbol (bbox 26–238 → 22–234)


def shift(d, dx=0, dy=DY):
    """Offsets the absolute coordinates of a path made of M/L/C/H/V/A/Z."""
    out = []
    toks = re.findall(r"[MLCHVZAa]|-?\d+(?:\.\d+)?", d)
    cmd, n = None, 0
    for t in toks:
        if t.isalpha():
            cmd, n = t, 0
            out.append(t)
            continue
        v = float(t)
        if cmd in "MLC":
            v += dx if n % 2 == 0 else dy
        elif cmd == "H":
            v += dx
        elif cmd == "V":
            v += dy
        elif cmd == "A" and n % 7 in (5, 6):
            v += dx if n % 7 == 5 else dy
        n += 1
        out.append(f"{v:g}")
    return " ".join(out).replace(" Z", "Z")


# ---- symbol -------------------------------------------------------------------------------
BODY = ("M108 84C70 96 36 128 36 172C36 216 76 238 128 238C180 238 220 216 220 172"
        "C220 128 186 96 148 84Z")
NOTE = ("M132 104H146C150 126 180 132 178 164C172 150 160 142 146 140"
        "V192C148 208 130 220 112 218C94 216 86 204 92 192C98 180 118 172 132 178Z")
TIE = "M103 66H153A7 7 0 0 1 153 80H103A7 7 0 0 1 103 66Z"
TUFT = "M110 62C98 52 86 42 86 26C100 34 114 32 128 42C142 32 156 34 170 26C170 42 158 52 146 62Z"

# small-size cut: one silhouette (tie merged into the neck), chunkier note
SMALL_BODY = ("M108 84C70 96 36 128 36 172C36 216 76 238 128 238C180 238 220 216 220 172"
              "C220 128 186 96 148 84L152 62C164 52 174 40 174 22C156 32 142 30 128 40"
              "C114 30 100 32 82 22C82 40 92 52 104 62Z")
SMALL_NOTE = ("M126 100H148C154 122 186 128 182 168C174 152 162 146 148 144"
              "V190C150 210 128 224 106 222C86 220 76 206 84 192C92 178 112 170 126 174Z")


def symbol_paths(color, small=False):
    if small:
        return f'<path fill="{color}" fill-rule="evenodd" d="{shift(SMALL_BODY)}{shift(SMALL_NOTE)}"/>'
    return (f'<path fill="{color}" fill-rule="evenodd" d="{shift(BODY)}{shift(NOTE)}"/>'
            f'<path fill="{color}" d="{shift(TIE)}{shift(TUFT)}"/>')


SYM_INK = (36, 22, 220, 234)  # ink bbox after the lift


# ---- wordmark -----------------------------------------------------------------------------
_font = TTFont(FONT)
_gs = _font.getGlyphSet()
_cmap = _font.getBestCmap()
_cap = _font["OS/2"].sCapHeight
_upm = _font["head"].unitsPerEm


def line(txt, x, baseline, cap_h, track):
    s = cap_h / _cap
    pen = SVGPathPen(_gs, ntos=lambda v: f"{v:.2f}".rstrip("0").rstrip("."))
    cur = 0
    for ch in txt:
        g = _gs[_cmap[ord(ch)]]
        g.draw(TransformPen(pen, (s, 0, 0, -s, x + cur * s, baseline)))
        cur += g.width + track * _upm
    return pen.getCommands(), (cur - track * _upm) * s


def wordmark(x0, top, total, gap_ratio=16 / 176):
    """Two justified lines, slanted. Returns (path d, transform, ink bbox)."""
    _, w1 = line("GRAND THEFT", 0, 0, 100, 0.04)
    _, w2 = line("AUDIO", 0, 0, 100, 0.03)
    gap = total * gap_ratio
    ch1 = (total - gap) / (1 + w1 / w2)
    ch2 = ch1 * w1 / w2
    d1, wa = line("GRAND THEFT", x0, top + ch1, ch1, 0.04)
    d2, _ = line("AUDIO", x0, top + ch1 + gap + ch2, ch2, 0.03)
    t = math.tan(math.radians(SKEW))
    mid = top + total / 2
    # skew about the block's middle: top leans right, bottom leans left
    lean = t * total / 2
    transform = f"translate({lean:.2f} 0) translate(0 {mid:.2f}) skewX(-{SKEW}) translate(0 {-mid:.2f})"
    return d1 + d2, transform, (x0, top, x0 + wa + 2 * lean, top + total)


def svg(w, h, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:g} {h:g}" width="{w:g}" height="{h:g}">'
            f"<title>{title}</title>{body}</svg>\n")


def write(name, content):
    with open(os.path.join(OUT, name), "w") as f:
        f.write(content)


def main():
    os.makedirs(OUT, exist_ok=True)
    T = "Grand Theft Audio"
    # symbols
    write("gta-symbol.svg", svg(256, 256, symbol_paths("#000"), T))
    write("gta-symbol-small.svg", svg(256, 256, symbol_paths("#000", small=True), T))
    write("gta-symbol-color.svg", svg(256, 256, symbol_paths(HEAT), T))

    # horizontal: symbol ink starts at x=0, wordmark 44 units after it, block 176 tall centred on 128
    sx = -SYM_INK[0]
    sym = f'<g transform="translate({sx} 0)">{{}}</g>'
    wx = SYM_INK[2] + sx + 44
    d, tf, bb = wordmark(wx, 40, 176)
    hw = bb[2] + 2
    for suffix, sc, wc in (("", "#000", "#000"), ("-color", HEAT, INK), ("-reversed", HEAT, WHITE)):
        body = sym.format(symbol_paths(sc)) + f'<path fill="{wc}" transform="{tf}" d="{d}"/>'
        write(f"gta-horizontal{suffix}.svg", svg(hw, 256, body, T))

    # stacked: symbol centred above, wordmark below
    d, tf, bb = wordmark(0, 0, 100)
    ww = bb[2]
    W = max(ww, 184) + 0
    sym_x = (W - 184) / 2 - SYM_INK[0]
    sym_y = -SYM_INK[1]
    wy = (SYM_INK[3] - SYM_INK[1]) + 32
    h = wy + 100
    for suffix, sc, wc in (("", "#000", "#000"), ("-color", HEAT, INK), ("-reversed", HEAT, WHITE)):
        body = (f'<g transform="translate({sym_x:.2f} {sym_y})">{symbol_paths(sc)}</g>'
                f'<g transform="translate({(W - ww) / 2:.2f} {wy})"><path fill="{wc}" transform="{tf}" d="{d}"/></g>')
        write(f"gta-stacked{suffix}.svg", svg(round(W, 2), h, body, T))

    # wordmark only
    d, tf, bb = wordmark(0, 0, 176)
    for suffix, wc in (("", "#000"), ("-white", WHITE)):
        write(f"gta-wordmark{suffix}.svg", svg(round(bb[2], 2), 176, f'<path fill="{wc}" transform="{tf}" d="{d}"/>', T))
    print("wrote", OUT)


main()
