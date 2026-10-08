#!/usr/bin/env python3
"""Find where every stop name sits on the 2026 network drawing in views/scheme_1.erb.

The drawing has no <text>: every label is a run of glyph outlines. This script
  1. clusters the black (Ukrainian) glyph paths by outline, so one cluster is one letter,
  2. spells the clusters out via GLYPHS below (read off a contact sheet by eye),
  3. rebuilds the words and the one-to-three line labels they form,
  4. pins each label to the stop marker(s) nearest to it,
  5. writes data/map_labels.json: normalised stop name -> [[x, y], ...] in poster coordinates.

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


def load_markers():
    lines = open(SCHEME, encoding='utf8').read().split('\n')
    markers = []
    for group in MARKER_GROUPS:
        start = next(i for i, l in enumerate(lines) if '<g id="%s">' % group in l)
        end = next(i for i in range(start, len(lines)) if lines[i].startswith('</g>'))
        markers += group_markers(lines[start + 1:end])
    return markers


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
        markers.append(((x0 + x1) / 2, (y0 + y1) / 2))
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


def untangle(pick, wanted, markers, geo):
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

    def reach(label):  # its own markers, and any other one right by it
        out = dict((m, d) for d, m in wanted[label][1])
        for m, xy in enumerate(markers):
            d = dist(wanted[label][2], *xy)
            if d < 25:
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


def merge_close(points, within=15):
    """Interchange markers are several squares in a row; one pin is enough for those."""
    out = []
    for p in points:
        if all(abs(p[0] - q[0]) > within or abs(p[1] - q[1]) > within for q in out):
            out.append(p)
    return [list(p) for p in out]


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
    markers = load_markers()
    cands = labels(toks)

    raw = args.stops and open(args.stops).read() or urllib.request.urlopen('https://api.lad.lviv.ua/stops.json').read()
    stops = json.loads(raw)
    names = {key(s['name']) for s in stops}

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
        mine = [(dist(c, *markers[m]), m) for m in range(len(markers)) if owner[m] in c['toks']]
        mine = [(d, m) for d, m in mine if d < 40]
        if not mine:  # a neighbour's word sits closer to the marker; take it if it is right by the label
            mine = [(d, m) for d, m in ((dist(c, *markers[m]), m) for m in range(len(markers))) if d < 25]
        if not mine:  # no marker by it at all: better no pin than one on whatever is next to the label
            print('no marker near %r' % c['text'], file=sys.stderr)
            continue
        wanted[frozenset(c['toks'])] = (ks, mine, c)

    pick, taken = {}, set()
    for d, m, label in sorted((d, m, l) for l, (_, mine, _) in wanted.items() for d, m in mine):
        if label not in pick and m not in taken:
            pick[label] = m
            taken.add(m)
    for label in set(wanted) - set(pick):
        print('every marker near %r went to a closer label' % wanted[label][0], file=sys.stderr)
    untangle(pick, wanted, markers, where(stops))

    found = collections.defaultdict(set)
    for label, m in pick.items():
        for k in wanted[label][0]:
            found[k].add(markers[m])

    result = {k: merge_close([poster(x, y) for x, y in sorted(v)]) for k, v in sorted(found.items())}
    json.dump(result, open(OUT, 'w'), ensure_ascii=False, indent=1)
    print('%d of %d stop names found on the drawing -> %s' % (len(result), len(names), os.path.relpath(OUT, ROOT)))


if __name__ == '__main__':
    main()
