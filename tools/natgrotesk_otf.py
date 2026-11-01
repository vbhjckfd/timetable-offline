#!/usr/bin/env python3
"""Rebuild public/fonts/NatGrotesk/NatGrotesk-Regular.otf from the SVG font next to it.

NatGrotesk came to us only as an SVG font inside the city's CorelDRAW panel template.
wkhtmltopdf and Safari render SVG fonts, Chrome and Firefox do not, so the panel would
fall back to another face in a browser and stop matching the print. This turns the
same glyphs and advances into a CFF OpenType font every renderer takes; the SVG font
stays the source, and app.rb still measures names from it.

Rerun it whenever the SVG font changes. Needs fontTools:  pip install fonttools

    python3 tools/natgrotesk_otf.py
"""
import html, os, re
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.svgLib.path import parse_path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.path.join(ROOT, 'public', 'fonts', 'NatGrotesk')
SRC = os.path.join(DIR, 'NatGrotesk-Regular.svg')
OUT = os.path.join(DIR, 'NatGrotesk-Regular.otf')
UPM = 1000  # the SVG font gives no units-per-em, so it is SVG's default


def main():
    svg = open(SRC, encoding='utf-8').read()
    default_advance = float(re.search(r'<font\b[^>]*\shoriz-adv-x="([\d.]+)"', svg).group(1))

    glyphs = {}  # character -> (advance, path data)
    for attrs in re.findall(r'<glyph\b([^>]*?)/?>', svg):
        char = html.unescape(re.search(r'\bunicode="([^"]*)"', attrs).group(1))
        advance = re.search(r'\bhoriz-adv-x="([\d.]+)"', attrs)
        path = re.search(r'\bd="([^"]*)"', attrs)
        glyphs[char] = (float(advance.group(1)) if advance else default_advance, path.group(1) if path else '')

    names = ['.notdef'] + ['uni%04X' % ord(c) for c in glyphs]
    charstrings, metrics, y_min, y_max = {}, {}, 0, 0
    for name, (char, (advance, path)) in zip(names, [(None, (default_advance, ''))] + list(glyphs.items())):
        # SVG font glyphs are drawn y-up in font units already, as OpenType wants them.
        pen = T2CharStringPen(round(advance), None)
        bounds = BoundsPen(None)
        if path:
            parse_path(path, pen)
            parse_path(path, bounds)
        charstrings[name] = pen.getCharString()
        left = 0
        if bounds.bounds:
            left = bounds.bounds[0]
            y_min, y_max = min(y_min, bounds.bounds[1]), max(y_max, bounds.bounds[3])
        metrics[name] = (round(advance), round(left))

    fb = FontBuilder(UPM, isTTF=False)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap({ord(c): n for c, n in zip(glyphs, names[1:])})
    fb.setupCFF('NatGrotesk-Regular', {'FullName': 'NatGrotesk Regular'}, charstrings, {})
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=round(y_max), descent=round(y_min))
    fb.setupNameTable({'familyName': 'NatGrotesk', 'styleName': 'Regular'})
    fb.setupOS2(sTypoAscender=round(y_max), sTypoDescender=round(y_min), usWinAscent=round(y_max),
                usWinDescent=round(-y_min))
    fb.setupPost()
    fb.save(OUT)
    print('%s: %d glyphs, %d bytes' % (os.path.relpath(OUT, ROOT), len(names), os.path.getsize(OUT)))


if __name__ == '__main__':
    main()
