#!/usr/bin/env python3
"""Find where every stop name sits on the 2026 network drawing in views/scheme_1.erb.

The drawing has no <text>: every label is a run of glyph outlines. This script
  1. clusters the black (Ukrainian) glyph paths by outline, so one cluster is one letter,
  2. spells the clusters out via GLYPHS below (read off a contact sheet by eye),
  3. rebuilds the words and the one-to-three line labels they form,
  4. pins each label to the stop marker nearest to it that serves the name's tram/trolleybus routes,
  5. writes data/map_labels.json: normalised stop name -> [[x, y, [route numbers]], ...] in poster
     coordinates; the app keeps the pins on the stop's own routes, as some names sit on two lines.

Redo it whenever the drawing changes (the cluster ids will change too; run with
--sheet to get a new contact sheet to read). Needs fontTools:  pip install fonttools

    python3 tools/extract_map_labels.py [--stops stops.json] [--sheet sheet.svg]
"""
import argparse, collections, json, os, re, sys, urllib.request
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.svgLib.path import parse_path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEME = os.path.join(ROOT, 'views', 'scheme_1.erb')
OUT = os.path.join(ROOT, 'data', 'map_labels.json')

# The drawing is placed on the poster by <g id="scheme" transform="translate(..) scale(..)">,
# and its paths carry matrix(1,0,0,-1,0,H) on top of that.
SCHEME_TX, SCHEME_TY, SCHEME_SCALE, PAGE_H = 623.71, 178.2, 3.065, 2267.7166

BLACK = '#1a1a18'  # Ukrainian names; English ones are #7a8890 and are not needed

# Cluster id -> letter, in the order of sheet.svg. Case is irrelevant to the match.
GLYPH_ROWS = [
    ([29, 1, 6, 7, 27, 12, 3, 30, 47, 72, 10, 11], 'анкиорвіелта'),
    ([40, 5, 67, 28, 4, 53, 31, 41, 76, 8, 9, 71], 'оьдссСячгйцП'),
    ([51, 87, 100, 82, 74, 75, 99, 26, 97, 116, 94, 65], 'уьмзКпУАхЛМБ'),
    ([113, 126, 77, 54, 95, 73, 108, 111, 66, 85, 55, 90], 'ГйТбВщРшїЗ.-'),
    ([92, 118, 120, 121, 129, 52, 125, 137, 138, 98, 119, 123], 'НО«»цубШдКжФ'),
    ([78, 107, 110, 139, 151, 14, 0, 2, 32, 39, 88, 152], 'бІДВваЯі№уаі'),
    ([161, 177, 178, 181, 20, 193, 69, 16, 33, 56, 86, 89], 'сфХ0укрі4ЮКі'),
    ([127, 128, 131, 132, 134, 140, 141, 142, 143, 144, 145, 146], "ющє'бх!одока"),
    ([147, 148, 149, 150, 160, 162, 163, 164, 165, 166, 174, 175], 'алльдерьКаз5'),
    ([179, 180, 184, 185, 187, 209, 190, 213, 214, 36, 194, 219], "Ч7З'бчНхТовЄ"),
]

# Labels the drawing spells differently from the API: abbreviated, or with a word more.
ALIASES = {
    'соборсвюра': ['соборсвятогоюра'],
    'церквасванни': ['церквасвятоїанни'],
    'палацкультуригнхоткевича': ['палацкультуригнатахоткевича'],
    'площасоборна': ['соборна'],
    'бкотика': ['котика', 'богданакотика'],
    'сихівськарайадміністрація': ['сихівськара'],
    'шевченківськарайадміністрація': ['шевченківськара'],
}

# Markers live in these groups; St. Anne's junction is drawn apart from the rest.
MARKER_GROUPS = ('scheme-stops', 'scheme-anna')

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
    cluster = {}
    for g in glyphs:
        g['cid'] = cluster.setdefault(g['sig'], len(cluster))
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
                     '<path d="%s" transform="matrix(1,0,0,-1,0,%f)"/></g><text x="5" y="62" font-size="11" fill="red">%d (%d)</text></g>'
                     % ((i % 12) * 110, (i // 12) * 70, sc, -x0, -(PAGE_H - y1), g['d'], PAGE_H, c, len(cl[c])))
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

    letters = {}
    for ids, chars in GLYPH_ROWS:
        assert len(ids) == len(chars), (ids, chars)
        letters.update(zip(ids, chars))
    unknown = {g['cid'] for g in glyphs if g['fill'] == BLACK and g['cid'] not in letters}
    if unknown:
        sys.exit('clusters with no letter (redo GLYPH_ROWS from a --sheet): %s' % sorted(unknown))

    toks = words(glyphs, letters)
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
    print('%d of %d stop names found on the drawing -> %s' % (len(result), len(names), os.path.relpath(OUT, ROOT)))


if __name__ == '__main__':
    main()
