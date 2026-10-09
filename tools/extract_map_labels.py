#!/usr/bin/env python3
"""Find where every stop name sits on the 2026 network drawing in views/scheme.erb.

The drawing has no <text>: every label is a run of glyph outlines. This script
  1. groups the black (Ukrainian) glyph paths by outline, so one outline is one letter,
  2. spells the outlines out via GLYPHS below (read off a contact sheet by eye); labels renamed
     in the drawing are <text class="map-label"> and are read as text,
  3. rebuilds the words and the one-to-three line labels they form,
  4. pins each label to the stop marker nearest to it that serves the name's tram/trolleybus routes,
  5. writes data/map_labels.json: normalised stop name -> [[x, y, [route numbers]], ...] in poster
     coordinates; the app keeps the pins on the stop's own routes, as some names sit on two lines.

Redo it whenever the drawing changes; if it reports outlines with no letter, run with --sheet
for a contact sheet and add them to GLYPHS. Needs fontTools:  pip install fonttools

    python3 tools/extract_map_labels.py [--stops stops.json] [--sheet sheet.svg]
"""
import argparse, collections, hashlib, json, math, os, re, sys, urllib.request
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.svgLib.path import parse_path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEME = os.path.join(ROOT, 'views', 'scheme.erb')
OUT = os.path.join(ROOT, 'data', 'map_labels.json')
OUT_STOPS = os.path.join(ROOT, 'data', 'map_stop_pins.json')

# The drawing is placed on the poster by <g id="scheme" transform="translate(..) scale(..)">,
# and its paths carry matrix(1,0,0,-1,0,H) on top of that.
SCHEME_TX, SCHEME_TY, SCHEME_SCALE, PAGE_H = 623.71, 178.2, 3.065, 2267.7166

BLACK = '#1a1a18'  # Ukrainian names; English ones are #7a8890 and are not needed

# Letter -> outlines it is drawn with (a short hash of each glyph's shape; one letter comes in
# several, as the drawing is set at more than one size and position). Read off a --sheet contact
# sheet by eye. Case is irrelevant to the match.
GLYPHS = {
    'А': ["d822d9a7"],
    'а': ["23b67a18", "3e926e39", "565ebdca", "67e6a29d", "83ce94e9", "92252f8a", "942b1dcb"],
    'Б': ["9bd5268e"],
    'б': ["2219d063", "834fbcb2", "b19fd1f3", "bb8d5182", "cdda361c"],
    'В': ["a4fe613f", "be41fac9"],
    'в': ["79c8fbb6", "82d0fbed", "d3841b41"],
    'Г': ["58b9d174"],
    'г': ["c374392b"],
    'Д': ["dbd17567"],
    'д': ["0ca618ba", "17a57f24", "6832e178", "c220a193"],
    'е': ["024690de", "577836f1"],
    'ж': ["77b78935"],
    'З': ["1fcb77f3", "a8d7aec6"],
    'з': ["a96e8f6c", "f61c3dcb"],
    'и': ["df41b782"],
    'й': ["00e01439", "ab4e2504"],
    'К': ["0244b2a7", "1496e474", "9f24e6c3", "ae4ab88c"],
    'к': ["06f3373d", "1bd5c467", "998035c0"],
    'Л': ["9b34f0f9"],
    'л': ["4672650e", "89073988", "d1dd6af9"],
    'М': ["bb6affc7"],
    'м': ["de18396d"],
    'Н': ["2f3fb29a", "7f8e1726"],
    'н': ["f21fe371"],
    'О': ["ecc22936"],
    'о': ["29894468", "2fe4176e", "bc2f7459", "c2ae752e", "ecbfb5af"],
    'П': ["37a79eb7"],
    'п': ["7d4b0c2e"],
    'Р': ["b12b2321"],
    'р': ["41600186", "df5e0a10", "ef275253"],
    'С': ["3114dbf2"],
    'с': ["1c82a6f2", "6daabdc1", "9276ebd8"],
    'Т': ["0bbc1850", "736bed25"],
    'т': ["0ebdde41"],
    'У': ["406adf15"],
    'у': ["0511fab4", "22bb3126", "a2f68d7c", "beaa47e4"],
    'Ф': ["dfc847dc"],
    'ф': ["03804d0f"],
    'Х': ["74cadae5"],
    'х': ["06f91633", "48035c1b", "7def62b8"],
    'ц': ["8f1538c5", "9465711f"],
    'Ч': ["c10cac9e"],
    'ч': ["e5ba3aa6", "ebe569f6"],
    'Ш': ["25f6b165"],
    'ш': ["05b602a6"],
    'щ': ["2df71a76", "4b6fd61d"],
    'ь': ["07498d36", "aaafcc78", "ef3c7f3d", "f10167c6"],
    'Ю': ["99ff1fea"],
    'ю': ["13e39334"],
    'Я': ["f7099f18"],
    'я': ["6809707d"],
    'Є': ["4db38cb4"],
    'є': ["5f9c89f9"],
    'І': ["5c455844"],
    'і': ["0958975d", "0c89edfe", "2730d5a7", "640a1788", "ac9749ef"],
    'ї': ["4227dd74"],
    '!': ["21c8e6cf"],
    "'": ["b874743f", "edc960c0"],
    '-': ["33f10915"],
    '.': ["73d59a97"],
    '0': ["f1e97622"],
    '4': ["721c58dd"],
    '5': ["b51526bc"],
    '7': ["19ec4910"],
    '«': ["fa87859a"],
    '»': ["e2e5d360"],
    '№': ["7a973936"],
}
LETTERS = {h: ch for ch, hs in GLYPHS.items() for h in hs}

# Labels the drawing spells differently from the API: abbreviated, or with a word more.
ALIASES = {
    'соборсвюра': ['соборсвятогоюра'],
    'церквасванни': ['церквасвятоїанни'],
    'палацкультуригнхоткевича': ['палацкультуригнатахоткевича'],
    'площасоборна': ['соборна'],
    'бкотика': ['котика', 'богданакотика'],
    'сихівськарайадміністрація': ['сихівськара'],
    'шевченківськарайадміністрація': ['шевченківськара'],
    'клевицького': ['левицького'],
    # the drawing's Головна пошта, renamed Словацького in views/scheme.erb; the Головна пошта
    # stops still stand at that marker
    'словацького': ['словацького', 'головнапошта'],
    # renamed in views/scheme.erb, shortened to fit
    'коледжінформтехнологій': ['коледжінформаційнихтехнологій'],
    'бцукраїнськийкапітал': ['бізнесцентрукраїнськийкапітал'],
}

# A tram/trolleybus stop the drawing does not label is placed from its real position: a local fit
# from the pinned stops around it says where on the drawing it should be, and it takes the nearest
# free marker on its own line. Tested on stops already pinned, that picks the right marker 91% of
# the time, about 74 px off on the median; further than this from any such marker, it is not trusted.
LOCATE_WITHIN = 150  # poster px

# A stop with no pin of its own points at the nearest pinned stop this close, as the crow flies;
# closer than SAME_PLACE it is the same stop under another code, and gets the plain pin.
WALK_WITHIN = 500  # metres
SAME_PLACE = 100  # metres

# Where the nearest stop as the crow flies is not the one to walk to: name -> name to point at.
WALK_TO = {}

# Markers live in these groups; St. Anne's junction is drawn apart from the rest.
MARKER_GROUPS = ('scheme-stops', 'scheme-anna')

# Stops the name alone cannot place, pinned by hand: stop code -> (route it must be on, a point
# in poster coordinates the marker sits at). Snapped to the marker, so a redrawn map fails here
# rather than drifting.
STOP_PINS = {
    # Бандери, trolleybuses: one marker per direction; the triangles on the lower one point
    # right, to the centre (474 runs to Університет), the upper one's point left (49, outbound).
    474: (22, (3237.3, 3846.9)),
    49: (22, (3257.4, 3547.9)),
    # Бандери, trams 4/9: no label of their own; the 4/9 marker nearest the Бандери labels.
    555: (4, (3350.3, 3810.9)),
    557: (4, (3350.3, 3810.9)),
    # Станція Сихів is on the drawing twice: 385 is the stop that was Колодязна, 389 the other.
    385: (31, (6377.0, 5590.5)),
    389: (31, (6487.4, 5701.0)),
}

# Route lines, and the number on each line's end badge (trams 1-9, trolleybuses 22-38).
# Read off scheme-numbers-bold; badge fills differ from line strokes by a shade, so match nearest.
LINE_GROUPS = ('scheme-tmp-29', 'scheme-routes', 'scheme-tmp-30', 'scheme-anna')
ROUTE_COLOURS = {
    '#e41e0e': 1, '#915134': 2, '#4baf50': 3, '#009bd6': 4, '#933d90': 6, '#0c67b1': 7, '#929292': 8,
    '#0f5c1c': 9, '#359a7a': 22, '#ba7f5e': 23, '#e8e348': 24, '#e94d09': 25, '#afca06': 27,
    '#25328a': 29, '#f086a9': 30, '#078e2e': 31, '#e50063': 32, '#6f7e28': 33, '#9c0b01': 38,
}


def key(s):
    return ''.join(c for c in s.lower() if c.isalnum())


def load_glyphs():
    lines = open(SCHEME, encoding='utf8').read().split('\n')
    start = next(i for i, l in enumerate(lines) if '<g id="scheme-text">' in l)
    end = next(i for i in range(start, len(lines)) if lines[i].startswith('</g>'))
    glyphs = []
    for l in lines[start + 1:end]:
        m = re.search(r' d="([^"]+)"', l)
        if not m:
            continue
        f = re.search(r'fill="([^"]+)"', l)
        rec, bp = RecordingPen(), BoundsPen(None)
        parse_path(m.group(1), rec)
        parse_path(m.group(1), bp)
        if bp.bounds is None:
            continue
        x0, y0, x1, y1 = bp.bounds
        sig = json.dumps([(op, [(round(x - x0, 1), round(y - y0, 1)) for x, y in a]) for op, a in rec.value])
        glyphs.append(dict(fill=f.group(1) if f else None, bbox=(x0, y0, x1, y1), sig=sig, d=m.group(1)))
    for g in glyphs:
        g['cid'] = hashlib.sha1(g['sig'].encode()).hexdigest()[:8]
    return glyphs


def write_sheet(glyphs, path):
    cl = {}
    for g in glyphs:
        if g['fill'] == BLACK:
            cl.setdefault(g['cid'], []).append(g)
    order = sorted(cl, key=lambda c: -len(cl[c]))
    cells = []
    for i, c in enumerate(order):
        g = cl[c][0]
        x0, y0, x1, y1 = g['bbox']
        sc = 48 / max(y1 - y0, x1 - x0, 0.01)
        cells.append('<g transform="translate(%d,%d)"><g transform="translate(5,5) scale(%f) translate(%f,%f)">'
                     '<path d="%s" transform="matrix(1,0,0,-1,0,%f)"/></g><text x="5" y="62" font-size="11" fill="red">%s %s(%d)</text></g>'
                     % ((i % 12) * 110, (i // 12) * 70, sc, -x0, -(PAGE_H - y1), g['d'], PAGE_H, c, LETTERS.get(c, '?'), len(cl[c])))
    open(path, 'w').write('<svg xmlns="http://www.w3.org/2000/svg" width="1320" height="%d"><rect width="100%%" height="100%%" fill="#fff"/>%s</svg>'
                          % ((len(order) + 11) // 12 * 70, ''.join(cells)))


def group_lines(lines, group):
    start = next(i for i, l in enumerate(lines) if '<g id="%s">' % group in l)
    end = next(i for i in range(start, len(lines)) if lines[i].startswith('</g>'))
    return lines[start + 1:end]


def load_markers():
    """Marker centres, and the route numbers of the lines running through each."""
    lines = open(SCHEME, encoding='utf8').read().split('\n')
    markers = []
    for group in MARKER_GROUPS:
        markers += group_markers(group_lines(lines, group))
    route_lines = [(r, segs) for group in LINE_GROUPS for r, segs in group_routes(group_lines(lines, group))]
    routes = [{r for r, segs in route_lines if any(seg_dist(x, y, a, b) <= size / 2 + 1.5 for a, b in segs)}
              for x, y, size in markers]
    return [(x, y) for x, y, _ in markers], routes


def route_of(colour):
    rgb = lambda h: [int(h[i:i + 2], 16) for i in (1, 3, 5)]
    off = lambda c: sum((a - b) ** 2 for a, b in zip(rgb(c), rgb(colour)))
    best = min(ROUTE_COLOURS, key=off)
    return ROUTE_COLOURS[best] if off(best) < 300 else None


def group_routes(lines):
    for l in lines:
        stroke, d = re.search(r'stroke="(#[0-9a-f]{6})"', l), re.search(r' d="([^"]+)"', l)
        route = stroke and d and route_of(stroke.group(1))
        if route:
            yield route, flatten(d.group(1))


def flatten(d):
    """Path -> line segments, curves cut into eight."""
    rec = RecordingPen()
    parse_path(d, rec)
    segs, cur, start = [], None, None
    for op, args in rec.value:
        if op == 'moveTo':
            cur = start = args[0]
        elif op == 'curveTo':
            (p1, p2, p3), p0 = args, cur
            for k in range(1, 9):
                t, u = k / 8, 1 - k / 8
                q = tuple(u ** 3 * p0[i] + 3 * u * u * t * p1[i] + 3 * u * t * t * p2[i] + t ** 3 * p3[i] for i in (0, 1))
                segs.append((cur, q))
                cur = q
        elif op in ('lineTo', 'qCurveTo'):
            for q in args:
                segs.append((cur, q))
                cur = q
        elif op == 'closePath' and cur != start:
            segs.append((cur, start))
    return segs


def seg_dist(x, y, a, b):
    (ax, ay), (bx, by) = a, b
    dx, dy = bx - ax, by - ay
    t = max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy))) if dx or dy else 0
    return ((x - ax - t * dx) ** 2 + (y - ay - t * dy) ** 2) ** 0.5


def group_markers(lines):
    markers = []
    for l in lines:
        m = re.search(r' d="([^"]+)"', l)
        # a marker is a white shape (drawn again as an outline); the coloured bits are direction triangles
        if not m or 'stroke=' in l or 'fill="#ffffff"' not in l:
            continue
        bp = BoundsPen(None)
        parse_path(m.group(1), bp)
        x0, y0, x1, y1 = bp.bounds
        markers.append(((x0 + x1) / 2, (y0 + y1) / 2, max(x1 - x0, y1 - y0)))
    return markers


def text_words():
    """Labels set as <text class="map-label"> (renamed ones) -> words, measured with the font."""
    from fontTools.ttLib import TTFont
    font = TTFont(os.path.join(ROOT, 'public', 'fonts', 'MyriadPro', 'MyriadPro-Regular.otf'))
    cmap, hmtx, glyph_set = font.getBestCmap(), font['hmtx'], font.getGlyphSet()
    found = []
    for l in open(SCHEME, encoding='utf8'):
        m = re.search(r'<text class="map-label" transform="translate\(([-\d.]+) ([-\d.]+)\) scale\(([\d.]+) 1\)" '
                      r'font-size="([\d.]+)" fill="([^"]+)"[^>]*>([^<]+)</text>', l)
        if not m or m.group(5) != BLACK:
            continue
        x, y, sx, size = (float(v) for v in m.groups()[:4])
        for word in re.finditer(r'\S+', m.group(6)):
            at, lo, hi, top, bottom = 0, None, None, 0, 0
            for i, ch in enumerate(m.group(6)[:word.end()]):
                name = cmap[ord(ch)]
                bp = BoundsPen(glyph_set)
                glyph_set[name].draw(bp)
                if i >= word.start() and bp.bounds:
                    lo = at + bp.bounds[0] if lo is None else lo
                    hi, top, bottom = at + bp.bounds[2], max(top, bp.bounds[3]), min(bottom, bp.bounds[1])
                at += hmtx[name][0]
            k = size * sx / 1000
            found.append(dict(text=word.group(), x0=x + lo * k, x1=x + hi * k,
                              y0=PAGE_H - y + bottom * size / 1000, y1=PAGE_H - y + top * size / 1000))
    return found


def words(glyphs, letters):
    """Black glyphs -> words: glyphs on one line, close together."""
    black = [g for g in glyphs if g['fill'] == BLACK]
    for g in black:
        g['ch'] = letters.get(g['cid'], '?')
    parent = list(range(len(black)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    grid = collections.defaultdict(list)
    for i, g in enumerate(black):
        grid[(int(g['bbox'][0] // 20), int(g['bbox'][1] // 20))].append(i)
    for i, g in enumerate(black):
        x0, y0, x1, y1 = g['bbox']
        for dx in range(-2, 3):
            for dy in range(-2, 3):
                for j in grid.get((int(x0 // 20) + dx, int(y0 // 20) + dy), []):
                    if j <= i:
                        continue
                    a0, b0, a1, b1 = black[j]['bbox']
                    if max(a0 - x1, x0 - a1) < 5.0 and min(y1, b1) - max(y0, b0) > 0.45 * min(y1 - y0, b1 - b0):
                        parent[find(i)] = find(j)
    groups = collections.defaultdict(list)
    for i in range(len(black)):
        groups[find(i)].append(black[i])
    out = []
    for gs in groups.values():
        gs.sort(key=lambda g: g['bbox'][0])
        out.append(dict(text=''.join(g['ch'] for g in gs),
                        x0=min(g['bbox'][0] for g in gs), x1=max(g['bbox'][2] for g in gs),
                        y0=min(g['bbox'][1] for g in gs), y1=max(g['bbox'][3] for g in gs)))
    return out


def labels(toks):
    """Every way the words can read as a label: runs along one line, stacked up to 3 lines.

    `whole` is set when no word on the same line or aligned right above / below carries
    on from it, so "Університет" inside "Медичний / університет" does not count."""
    cy = lambda t: (t['y0'] + t['y1']) / 2
    nxt = {}
    for i, t in enumerate(toks):
        best = None
        for j, u in enumerate(toks):
            gap = u['x0'] - t['x1']
            if i != j and -1 < gap < 9 and abs(cy(u) - cy(t)) < 5 and (best is None or gap < best[0]):
                best = (gap, j)
        if best:
            nxt[i] = best[1]

    def merge(seq):
        ts = [toks[i] for i in seq]
        return dict(text=''.join(t['text'] for t in ts), toks=set(seq),
                    x0=min(t['x0'] for t in ts), x1=max(t['x1'] for t in ts),
                    y0=min(t['y0'] for t in ts), y1=max(t['y1'] for t in ts))

    runs = []
    for i in range(len(toks)):
        seq = [i]
        runs.append(merge(seq))
        while seq[-1] in nxt and len(seq) < 6:
            seq.append(nxt[seq[-1]])
            runs.append(merge(seq))

    def below(a, b):
        return (-2 < a['y0'] - b['y1'] < 12 and (abs(a['x0'] - b['x0']) < 3 or abs(a['x1'] - b['x1']) < 3
                or abs((a['x0'] + a['x1']) / 2 - (b['x0'] + b['x1']) / 2) < 3))

    out = list(runs)
    for a in runs:
        for b in runs:
            if below(a, b):
                ab = dict(text=a['text'] + b['text'], toks=a['toks'] | b['toks'],
                          x0=min(a['x0'], b['x0']), x1=max(a['x1'], b['x1']),
                          y0=min(a['y0'], b['y0']), y1=max(a['y1'], b['y1']))
                out.append(ab)
                for c in runs:
                    if below(b, c) and not (c['toks'] & ab['toks']):
                        out.append(dict(text=ab['text'] + c['text'], toks=ab['toks'] | c['toks'],
                                        x0=min(ab['x0'], c['x0']), x1=max(ab['x1'], c['x1']),
                                        y0=min(ab['y0'], c['y0']), y1=max(ab['y1'], c['y1'])))
    prev = {j: i for i, j in nxt.items()}
    for c in out:
        line_goes_on = any(nxt.get(i) not in c['toks'] and i in nxt or prev.get(i) not in c['toks'] and i in prev
                           for i in c['toks'])
        stacked = any(not (r['toks'] & c['toks']) and (below(r, c) or below(c, r)) for r in runs)
        c['whole'] = not line_goes_on and not stacked
    return out


def dist(box, x, y):
    dx = max(box['x0'] - x, 0, x - box['x1'])
    dy = max(box['y0'] - y, 0, y - box['y1'])
    return (dx * dx + dy * dy) ** 0.5


def poster(x, y):
    return round(x * SCHEME_SCALE + SCHEME_TX, 1), round((PAGE_H - y) * SCHEME_SCALE + SCHEME_TY, 1)


def where(stops, spread=0.004):
    """Name -> (lon, lat) where all stops of that name are close together (~300 m), else left out."""
    by = collections.defaultdict(list)
    for s in stops:
        by[key(s['name'])].append(s['location'])
    out = {}
    for k, locs in by.items():
        lats, lons = [l[0] for l in locs], [l[1] for l in locs]
        if max(lats) - min(lats) < spread and max(lons) - min(lons) < spread:
            out[k] = (sum(lons) / len(lons), sum(lats) / len(lats))
    return out


def untangle(pick, wanted, markers, geo, marker_routes, served):
    """Two labels side by side can sit equally close to both their markers (Курмановича and
    Каховська share one line of text-distance); swap them when the real stops lie the other way round."""
    def place(label):
        ks = [k for k in wanted[label][0] if k in geo]
        return geo[ks[0]] if ks else None

    def agree(a, ma, b, mb):  # >0: map points from a to b the way the street does
        (lo1, la1), (lo2, la2) = place(a), place(b)
        gx, gy = (lo2 - lo1) * 0.65, la2 - la1  # cos(49.8°) squeezes longitude
        (x1, y1), (x2, y2) = markers[ma], markers[mb]
        return gx * (x2 - x1) + gy * (y2 - y1)  # drawing's own y points north here

    def reach(label):  # its own markers, and any other one right by it on one of its lines
        out = dict((m, d) for d, m in wanted[label][1])
        lines = set().union(*(served[k] for k in wanted[label][0]))
        for m, xy in enumerate(markers):
            d = dist(wanted[label][2], *xy)
            if d < 25 and (not lines or marker_routes[m] & lines):
                out.setdefault(m, d)
        return out

    labels = [l for l in pick if place(l)]
    for i, a in enumerate(labels):
        for b in labels[i + 1:]:
            ma, mb = pick[a], pick[b]
            if agree(a, ma, b, mb) >= 0:
                continue
            others = set(pick.values()) - {ma, mb}
            da, db = reach(a), reach(b)
            if not (set(da) & set(db)):  # nothing near both: not neighbours
                continue
            options = sorted((da[x] + db[y], x, y) for x in da for y in db
                             if x != y and not {x, y} & others and agree(a, x, b, y) > 0)
            if options:
                _, pick[a], pick[b] = options[0]
                print('re-picked %s / %s by geography' % (wanted[a][0], wanted[b][0]), file=sys.stderr)


def electric_routes(stops):
    """Name -> numbers of the trams and trolleybuses (Т01, Т22, ...) its stops serve."""
    out = collections.defaultdict(set)
    for s in stops:
        out[key(s['name'])] |= {int(r[1:]) for r in s['routes'] if r[:1] in 'ТT' and r[1:].isdigit()}
    return out


def lines_of(stop):
    return {int(r[1:]) for r in stop['routes'] if r[:1] in 'ТT' and r[1:].isdigit()}


def metres(stop):
    """Stop position in metres east / north of the city centre."""
    lat, lon = stop['location']
    return (lon - 24.03) * 111320 * math.cos(math.radians(49.84)), (lat - 49.84) * 111320


def pins_of(stop, by_name, by_stop):
    """The spots the app pins this stop on, by the same rules as map_pins_for in app.rb."""
    if str(stop['code']) in by_stop:
        return [] if 'walk' in by_stop[str(stop['code'])] else by_stop[str(stop['code'])]['at']
    pins = by_name.get(key(stop['name']), [])
    ours = [p for p in pins if set(p[2]) & lines_of(stop)]
    return [p[:2] for p in ours or pins]


def fit_at(stop, pool, k=6):
    """Where on the poster `stop` would be, from an affine fit to the k pinned stops nearest it."""
    gx, gy = metres(stop)
    near = sorted(pool, key=lambda sp: math.dist(metres(sp[0]), (gx, gy)))[:k]
    out = []
    for axis in (0, 1):  # weighted least squares, solved by hand: [x, y, 1] . c = poster axis
        ata = [[0.0] * 3 for _ in range(3)]
        atb = [0.0] * 3
        for s, (pin,) in near:
            row = [*metres(s), 1.0]
            w = 1 / (20 + math.dist(row[:2], (gx, gy)))
            for i in range(3):
                atb[i] += w * row[i] * pin[axis]
                for j in range(3):
                    ata[i][j] += w * row[i] * row[j]
        for i in range(3):  # Gauss-Jordan
            piv = max(range(i, 3), key=lambda r: abs(ata[r][i]))
            ata[i], ata[piv], atb[i], atb[piv] = ata[piv], ata[i], atb[piv], atb[i]
            for r in range(3):
                if r != i:
                    f = ata[r][i] / ata[i][i]
                    ata[r] = [a - f * b for a, b in zip(ata[r], ata[i])]
                    atb[r] -= f * atb[i]
        c = [atb[i] / ata[i][i] for i in range(3)]
        out.append(c[0] * gx + c[1] * gy + c[2])
    return out


def stop_pins(stops, by_name, by_stop, spots, spot_routes):
    """Fill by_stop for the stops their name does not place: a tram/trolleybus stop on its own
    line's marker when the fit is close enough, anything else pointed at the nearest pinned stop."""
    placed = [(s, pins_of(s, by_name, by_stop)) for s in stops]
    known = [(s, p) for s, p in placed if lines_of(s) and len(p) == 1]
    claimed = {min(range(len(spots)), key=lambda i: math.dist(spots[i], p[0])) for _, p in known}
    for s, p in placed:
        if p or not lines_of(s):
            continue
        x, y = fit_at(s, known)
        free = [i for i in range(len(spots)) if i not in claimed and spot_routes[i] & lines_of(s)]
        d, i = min(((math.dist((x, y), spots[i]), i) for i in free), default=(math.inf, None))
        if d <= LOCATE_WITHIN:
            by_stop[str(s['code'])] = {'at': [list(spots[i])]}
        else:
            print('stop %d %s: no marker of its line where it should be' % (s['code'], s['name']), file=sys.stderr)

    pinned = [(s, pins_of(s, by_name, by_stop)) for s in stops]
    pinned = [(s, p) for s, p in pinned if p]
    for s in stops:
        if pins_of(s, by_name, by_stop):
            continue
        pool = [(t, p) for t, p in pinned if key(t['name']) == WALK_TO.get(key(s['name']), key(t['name']))]
        d, (to, at) = min(((math.dist(metres(s), metres(t)), (t, p)) for t, p in pool), key=lambda dp: dp[0])
        if d <= SAME_PLACE:
            by_stop[str(s['code'])] = {'at': at}
        elif d <= WALK_WITHIN:
            by_stop[str(s['code'])] = {'at': at, 'walk': {'code': to['code'], 'name': to['name'],
                                                          'name_en': to.get('eng_name') or '',
                                                          'metres': int(round(d / 10) * 10)}}


def merge_close(points, within=15):
    """Interchange markers are several squares in a row; one pin is enough for those."""
    out = []
    for x, y, routes in points:
        near = [p for p in out if abs(p[0] - x) <= within and abs(p[1] - y) <= within]
        if near:
            near[0][2] = sorted(set(near[0][2]) | routes)
        else:
            out.append([x, y, sorted(routes)])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stops', help='local copy of api.lad.lviv.ua/stops.json (default: download)')
    ap.add_argument('--sheet', help='write a contact sheet of the black glyph clusters here and stop')
    args = ap.parse_args()

    glyphs = load_glyphs()
    if args.sheet:
        write_sheet(glyphs, args.sheet)
        return

    unknown = {g['cid'] for g in glyphs if g['fill'] == BLACK and g['cid'] not in LETTERS}
    if unknown:
        sys.exit('outlines with no letter (add them to GLYPHS from a --sheet): %s' % sorted(unknown))

    toks = words(glyphs, LETTERS) + text_words()
    markers, marker_routes = load_markers()
    cands = labels(toks)

    raw = args.stops and open(args.stops).read() or urllib.request.urlopen('https://api.lad.lviv.ua/stops.json').read()
    stops = json.loads(raw)
    names = {key(s['name']) for s in stops}
    served = electric_routes(stops)

    # each marker belongs to the word it is closest to; a label owns the markers whose word is part of it
    owner = [min(range(len(toks)), key=lambda i: dist(toks[i], mx, my)) for mx, my in markers]

    # One marker per label on the drawing: two sides of a street are one marker there, and a
    # second pick is the neighbour's. Hand markers out nearest first so neighbours cannot share one.
    wanted = {}  # label's words -> (names it stands for, [(distance, marker)])
    for c in cands:
        k = key(c['text'])
        if k in ALIASES:
            ks = ALIASES[k]
        elif c['whole'] and k in names:
            ks = [k]
        else:
            continue
        near = [(dist(c, *markers[m]), m) for m in range(len(markers))]
        own = [(d, m) for d, m in near if d < 40 and owner[m] in c['toks']]
        near = [(d, m) for d, m in near if d < 25]  # a neighbour's word may sit closer to it
        # a marker on none of the name's tram/trolleybus lines is a neighbour's
        lines = set().union(*(served[k] for k in ks))
        if lines:
            own = [(d, m) for d, m in own if marker_routes[m] & lines]
            near = [(d, m) for d, m in near if marker_routes[m] & lines]
        mine = sorted(set(own) | set(near)) if lines else own or near
        if not mine:  # no marker by it at all: better no pin than one on whatever is next to the label
            print('no marker near %r' % c['text'], file=sys.stderr)
            continue
        wanted[frozenset(c['toks'])] = (ks, mine, c)

    # labels whose own line runs through the marker go first: Океан (buses only) must not take
    # the tram-3 marker Бойчука sits on just because its word is 2 units nearer
    def confirmed(label, m):
        return bool(marker_routes[m] & set().union(*(served[k] for k in wanted[label][0])))

    pick, taken = {}, set()
    for _, d, m, label in sorted((not confirmed(l, m), d, m, l) for l, (_, mine, _) in wanted.items() for d, m in mine):
        if label not in pick and m not in taken:
            pick[label] = m
            taken.add(m)
    for label in set(wanted) - set(pick):
        print('every marker near %r went to a closer label' % wanted[label][0], file=sys.stderr)
    untangle(pick, wanted, markers, where(stops), marker_routes, served)

    # A name served by two lines can sit on both (Бандери: trolleybuses 22/30 and trams 4/9 stop
    # apart): give the label one more marker for each of its lines the first one misses.
    chosen = {label: [m] for label, m in pick.items()}
    for label, m in sorted(pick.items(), key=lambda lm: min(d for d, _ in wanted[lm[0]][1])):
        lines = set().union(*(served[k] for k in wanted[label][0]))
        for d, extra in sorted(wanted[label][1]):
            missing = lines - set().union(*(marker_routes[x] for x in chosen[label]))
            if extra not in taken and marker_routes[extra] & missing:
                chosen[label].append(extra)
                taken.add(extra)

    found = collections.defaultdict(list)
    for label, ms in chosen.items():
        for k in wanted[label][0]:
            found[k] += [(*poster(*markers[m]), marker_routes[m]) for m in ms]

    result = {k: merge_close(sorted(v, key=lambda p: p[:2])) for k, v in sorted(found.items())}
    json.dump(result, open(OUT, 'w'), ensure_ascii=False, indent=1)

    by_stop = {}
    for code, (route, (px, py)) in sorted(STOP_PINS.items()):
        d, m = min((abs(poster(*xy)[0] - px) + abs(poster(*xy)[1] - py), m) for m, xy in enumerate(markers))
        if d > 10 or route not in marker_routes[m]:
            sys.exit('stop %d: no route %d marker at %s any more; redo STOP_PINS' % (code, route, (px, py)))
        by_stop[str(code)] = {'at': [list(poster(*markers[m]))]}
    stop_pins(stops, result, by_stop, [poster(*xy) for xy in markers], marker_routes)
    json.dump(by_stop, open(OUT_STOPS, 'w'), ensure_ascii=False, indent=1)
    print('%d stops placed by code, %d of them pointing at a stop nearby -> %s'
          % (len(by_stop), sum('walk' in v for v in by_stop.values()), os.path.relpath(OUT_STOPS, ROOT)))
    print('%d of %d stop names found on the drawing -> %s' % (len(result), len(names), os.path.relpath(OUT, ROOT)))


if __name__ == '__main__':
    main()
