#!/usr/bin/env python3
"""Captylo brand kit, direction 01 (variant B, "wider cut").

Single source of truth: every SVG and PNG in this folder is written by this script, so the
symbol, the wordmark, the app icon and the menu bar glyphs can never drift apart.

    python3 brand.py                   # Deep Tide (default): all SVGs, PNG exports, AppIcon.appiconset, overview.png, board.png
    python3 brand.py --palette iris    # the previous Iris kit, same files

Requirements: python3, numpy, skia-pathops (pip install numpy skia-pathops) and rsvg-convert
(librsvg, `brew install librsvg`) for the PNG exports.

Geometry is built from exact primitives (superellipses, circular arcs, lines) and merged with
skia-pathops booleans. The parameters below were measured by least-squares fitting the parametric
shapes to the owner's reference boards (see README.md), then rounded to clean values.
"""
import json
import math
import os
import re
import subprocess
import sys

import numpy as np
import pathops

HERE = os.path.dirname(os.path.abspath(__file__))
PNG = os.path.join(HERE, 'png')
APPICON = os.path.join(HERE, 'AppIcon.appiconset')

# ------------------------------------------------------------------------------------------ palette
# Two palettes share the same shapes. "tide" (Deep Tide, the owner's board 04) is the default;
# "iris" (Ink, Iris, Mist, Apricot) is the previous kit and stays reachable with --palette iris.
# Both write to the same files, so the folder always holds one palette at a time.
ABYSS, PETROL, GLACIER, FOG, SALT = '#10272C', '#214A52', '#9FE6DC', '#B7CCCB', '#F2F7F4'
IRIS, MIST, APRICOT = '#7165E8', '#C8C1F4', '#F2B99F'
WHITE = '#FFFFFF'
THEMES = {
    'tide': dict(
        label='Deep Tide',
        ink=ABYSS, ink_name='Abyss',      # primary: symbol, wordmark, dark plates
        light=SALT, light_name='Salt',    # primary light surface
        record='#F27878',                 # recording state only
        palette=[('Abyss', ABYSS), ('Petrol', PETROL), ('Glacier', GLACIER), ('Fog', FOG), ('Salt', SALT),
                 ('Record', '#F27878')],
        mood='the Deep Tide field (Abyss and Petrol water with Glacier light)',
    ),
    'iris': dict(
        label='Iris',
        ink='#202331', ink_name='Ink',
        light='#FAF9F6', light_name='Ivory',
        record='#F06464',
        palette=[('Ink', '#202331'), ('Iris', IRIS), ('Mist', MIST), ('Apricot', APRICOT), ('Ivory', '#FAF9F6'),
                 ('Record', '#F06464')],
        mood='the Iris, Mist and Apricot gradient',
    ),
}


def _palette_arg():
    for i, a in enumerate(sys.argv):
        if a == '--palette' and i + 1 < len(sys.argv):
            return sys.argv[i + 1]
        if a.startswith('--palette='):
            return a.split('=', 1)[1]
    return 'tide'


PALETTE_NAME = _palette_arg()
if PALETTE_NAME not in THEMES:
    sys.exit('unknown palette %r (choose from: %s)' % (PALETTE_NAME, ', '.join(THEMES)))
THEME = THEMES[PALETTE_NAME]
TIDE = PALETTE_NAME == 'tide'
INK = THEME['ink']          # primary dark (Abyss in Deep Tide, Ink in Iris)
IVORY = THEME['light']      # primary light surface (Salt in Deep Tide, Ivory in Iris)
RECORD = THEME['record']
PALETTE = THEME['palette']
# Deep Tide is shown 10% darker than the raw palette: the owner dimmed the background by 10% in the
# lab (a black overlay at 10%), so the plate and hero fields are multiplied by 0.9. Marks, streaks and
# the outer glow sit on top and are not dimmed.
TIDE_DIM = 0.10
# supporting neutrals per palette:
# (board rules, secondary text, light tile stroke, overview rule, overview panel, light swatch stroke)
NEUTRALS = (('#B9CBC9', '#5B6F72', '#D2DEDB', '#BFD0CE', '#F7FAF8', '#CFDCD9') if TIDE else
            ('#BDBBD6', '#6E7183', '#DDD9D2', '#C9C7DA', '#FCFBF9', '#D9D6D0'))

TAU = 2 * math.pi


# ======================================================================================== geometry kit
class Builder:
    """Path builder over pathops.Path that tracks the current point."""

    def __init__(self):
        self.p = pathops.Path()
        self.cur = None

    def move(self, x, y):
        self.p.moveTo(x, y)
        self.cur = (x, y)

    def line(self, x, y):
        if self.cur is None:
            return self.move(x, y)
        if math.hypot(x - self.cur[0], y - self.cur[1]) > 1e-9:
            self.p.lineTo(x, y)
            self.cur = (x, y)

    def cubic(self, c1, c2, e):
        self.p.cubicTo(c1[0], c1[1], c2[0], c2[1], e[0], e[1])
        self.cur = (e[0], e[1])

    def arc(self, cx, cy, r, a0, a1):
        """Circular arc from angle a0 to a1 (radians, y-down), sweep a1 - a0, as cubics of <= 90 degrees."""
        sweep = a1 - a0
        n = max(1, int(math.ceil(abs(sweep) / (math.pi / 2) - 1e-9)))
        d = sweep / n
        k = 4.0 / 3.0 * math.tan(d / 4)
        self.line(cx + r * math.cos(a0), cy + r * math.sin(a0))
        a = a0
        for _ in range(n):
            b = a + d
            self.cubic((cx + r * (math.cos(a) - k * math.sin(a)), cy + r * (math.sin(a) + k * math.cos(a))),
                       (cx + r * (math.cos(b) + k * math.sin(b)), cy + r * (math.sin(b) - k * math.cos(b))),
                       (cx + r * math.cos(b), cy + r * math.sin(b)))
            a = b

    def curve(self, f, df, t0, t1, seg=None):
        """Smooth parametric curve f(t) as cubics: exact end points and tangents, handle lengths
        least-squares fitted to the curve (error far below 0.01% of the size)."""
        if seg is None:
            seg = max(1, int(math.ceil(abs(t1 - t0) / (math.pi / 8))))
        self.line(*f(t0))
        for i in range(seg):
            a = t0 + (t1 - t0) * i / seg
            b = t0 + (t1 - t0) * (i + 1) / seg
            P0, P3 = np.array(f(a)), np.array(f(b))
            T0, T3 = np.array(df(a)) * (b - a), np.array(df(b)) * (b - a)
            A, rhs = [], []
            for t in np.linspace(0, 1, 9)[1:-1]:
                pt = np.array(f(a + (b - a) * t))
                B0, B1, B2, B3 = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t ** 2, t ** 3
                A.append(np.stack([B1 * T0, -B2 * T3], 1))
                rhs.append(pt - (B0 + B1) * P0 - (B2 + B3) * P3)
            (u, v), *_ = np.linalg.lstsq(np.concatenate(A), np.concatenate(rhs), rcond=None)
            self.cubic(tuple(P0 + u * T0), tuple(P3 - v * T3), tuple(P3))

    def close(self):
        self.p.close()
        self.cur = None


def se_fn(cx, cy, rx, ry, n):
    """Superellipse |x/rx|^n + |y/ry|^n = 1: point f(t) and derivative df(t)."""
    e = 2.0 / n

    def f(t):
        c, s = math.cos(t), math.sin(t)
        return (cx + rx * math.copysign(abs(c) ** e, c), cy + ry * math.copysign(abs(s) ** e, s))

    def df(t):
        # on the axes |c|^(e-1) diverges when n > 2; clamping keeps the tangent direction exact
        c, s = math.cos(t), math.sin(t)
        dx = rx * e * max(abs(c), 1e-9) ** (e - 1) * (-s)
        dy = ry * e * max(abs(s), 1e-9) ** (e - 1) * c
        return (dx, dy)
    return f, df


def superellipse(cx, cy, rx, ry, n=2.0):
    f, df = se_fn(cx, cy, rx, ry, n)
    b = Builder()
    b.curve(f, df, 0, TAU, seg=8)
    b.close()
    return b.p


def circle(cx, cy, r):
    b = Builder()
    b.arc(cx, cy, r, 0, TAU)
    b.close()
    return b.p


def polygon(pts):
    b = Builder()
    b.move(*pts[0])
    for q in pts[1:]:
        b.line(*q)
    b.close()
    return b.p


def fillet(p0, p1, p2, r):
    """Circular fillet at corner p1 between p0-p1 and p1-p2: (start, end, centre, a0, a1)."""
    p0, p1, p2 = [np.array(q, float) for q in (p0, p1, p2)]
    u, v = p0 - p1, p2 - p1
    lu, lv = np.linalg.norm(u), np.linalg.norm(v)
    u, v = u / lu, v / lv
    ang = math.acos(float(np.clip(np.dot(u, v), -1, 1)))
    dist = r / math.tan(ang / 2)
    assert dist <= min(lu, lv) + 1e-6, 'fillet does not fit'
    a, c = p1 + u * dist, p1 + v * dist
    centre = p1 + (u + v) / np.linalg.norm(u + v) * (r / math.sin(ang / 2))
    a0 = math.atan2(a[1] - centre[1], a[0] - centre[0])
    a1 = math.atan2(c[1] - centre[1], c[0] - centre[0])
    sw = (a1 - a0 + math.pi) % TAU - math.pi
    return a, c, centre, a0, a0 + sw


def rounded_polygon(pts, radii):
    """Polygon with a circular fillet of radius radii[i] at vertex i (convex or concave corners)."""
    n = len(pts)
    b = Builder()
    for i in range(n):
        r = radii[i]
        if r <= 0:
            b.line(*pts[i])
            continue
        a, c, C, a0, a1 = fillet(pts[i - 1], pts[i], pts[(i + 1) % n], r)
        b.line(*a)
        b.arc(C[0], C[1], r, a0, a1)
    b.close()
    return b.p


def rrect(x0, y0, x1, y1, r):
    rr = r if isinstance(r, (list, tuple)) else [r] * 4
    return rounded_polygon([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], rr)


def union(*paths):
    out = pathops.Path()
    for p in paths:
        out = pathops.op(out, p, pathops.PathOp.UNION)
    return out


def diff(a, *bs):
    for b in bs:
        a = pathops.op(a, b, pathops.PathOp.DIFFERENCE)
    return a


class _TPen:
    def __init__(self, pen, m):
        self.pen, self.m = pen, m

    def _t(self, p):
        a, b, c, d, e, f = self.m
        return (a * p[0] + c * p[1] + e, b * p[0] + d * p[1] + f)

    def moveTo(self, p):
        self.pen.moveTo(self._t(p))

    def lineTo(self, p):
        self.pen.lineTo(self._t(p))

    def curveTo(self, *ps):
        self.pen.curveTo(*[self._t(p) for p in ps])

    def qCurveTo(self, *ps):
        self.pen.qCurveTo(*[self._t(p) for p in ps])

    def closePath(self):
        self.pen.closePath()

    def endPath(self):
        self.pen.endPath()


def transform(path, s=1.0, tx=0.0, ty=0.0, sy=None):
    out = pathops.Path()
    path.draw(_TPen(out.getPen(), (s, 0, 0, s if sy is None else sy, tx, ty)))
    return out


def bbox(path):
    return path.bounds  # (xmin, ymin, xmax, ymax)


def _bisect(g, a, b, it=80):
    ga = g(a)
    assert ga * g(b) <= 0, 'no root in bracket'
    for _ in range(it):
        m = (a + b) / 2
        gm = g(m)
        if ga * gm <= 0:
            b = m
        else:
            a, ga = m, gm
    return (a + b) / 2


def svg_d(path, nd=2):
    def f(v):
        s = '%.*f' % (nd, v)
        if '.' in s:
            s = s.rstrip('0').rstrip('.')
        return '0' if s in ('-0', '') else s
    out = []
    for verb, pts in path.segments:
        if verb == 'moveTo':
            out.append('M%s %s' % (f(pts[0][0]), f(pts[0][1])))
        elif verb == 'lineTo':
            out.append('L%s %s' % (f(pts[0][0]), f(pts[0][1])))
        elif verb == 'curveTo':
            out.append('C' + ' '.join('%s %s' % (f(x), f(y)) for x, y in pts))
        elif verb == 'qCurveTo':
            out.append('Q' + ' '.join('%s %s' % (f(x), f(y)) for x, y in pts))
        elif verb in ('closePath', 'endPath'):
            out.append('Z')
    return ''.join(out)


# ============================================================================================ the mark
# The C, in units of R (the outer vertical radius), outer shape centred on (0, 0), y pointing down.
#   outer    superellipse, half-width asp, half-height 1, exponent n (slightly fuller than an ellipse)
#   counter  soft superellipse (crx, cry, cn) sitting a little right of the centre
#   mouth    horizontal slot of half-height h, centred at y = sdy, from the counter out to the right
#   ends     terminals cut at x = xt, corners rounded with radius r (one round end if thinner than 2r)
#   neck     convex fillet rn where the counter turns into the slot (the "drop" under each terminal)
#   cut      straight parallel gap, width cut_w, cut_angle below horizontal, centre line cut_d from the
#            centre towards the lower left: it enters the left contour just below mid-height, passes
#            just under the counter and leaves the bottom contour before the lower terminal.
MARK = dict(asp=1.11, n=2.14, crx=0.41, cry=0.35, cn=2.15, cdx=0.028, cdy=-0.009, h=0.16, sdy=-0.013,
            r=0.31, rn=0.18, xt=0.86, cut_angle=29.0, cut_d=0.515, cut_w=0.178)


def mark(R=1.0, cx=0.0, cy=0.0, **over):
    """The Captylo C scaled to outer radius R and centred (outer shape) on (cx, cy)."""
    p = dict(MARK)
    p.update(over)
    asp, n = p['asp'], p['n']
    fo, dfo = se_fn(0, 0, asp, 1.0, n)
    fc, dfc = se_fn(p['cdx'], p['cdy'], p['crx'], p['cry'], p['cn'])

    def normal(df, t, sign):  # sign +1: inward for a curve traversed with increasing t
        dx_, dy_ = df(t)
        L = math.hypot(dx_, dy_)
        return (-dy_ / L * sign, dx_ / L * sign)

    def off(f, df, t, d, sign):
        q, nn = f(t), normal(df, t, sign)
        return (q[0] + d * nn[0], q[1] + d * nn[1])

    r, rn, xt, h, sdy = p['r'], p['rn'], p['xt'], p['h'], p['sdy']
    y_u, y_l = sdy - h, sdy + h
    xc = xt - r
    ends, necks = {}, {}
    for sgn, (lo, hi) in ((-1, (-math.pi / 2 + 1e-6, -1e-6)), (+1, (1e-6, math.pi / 2 - 1e-6))):
        yline = y_u if sgn < 0 else y_l
        t = _bisect(lambda t: off(fo, dfo, t, r, 1)[0] - xc, lo, hi)
        C = off(fo, dfo, t, r, 1)
        if (C[1] - (yline + sgn * r)) * sgn <= 0:
            ends[sgn] = ('two', t, C)
        else:
            t = _bisect(lambda t: off(fo, dfo, t, r, 1)[1] - (yline + sgn * r), lo, hi)
            ends[sgn] = ('one', t, off(fo, dfo, t, r, 1))
        lo2, hi2 = (-math.pi / 2, -1e-6) if sgn < 0 else (1e-6, math.pi / 2)
        yn = yline + sgn * rn
        t = _bisect(lambda t: off(fc, dfc, t, rn, -1)[1] - yn, lo2, hi2)
        necks[sgn] = (t, off(fc, dfc, t, rn, -1))
    b = Builder()
    ku, tu, Cu = ends[-1]
    kl, tl, Cl = ends[+1]
    Tu, Tl = fo(tu), fo(tl)
    b.move(*Tu)
    b.curve(fo, dfo, tu, tl - TAU, seg=12)          # outer contour, over the top, round the left
    a0 = math.atan2(Tl[1] - Cl[1], Tl[0] - Cl[0])
    if kl == 'two':                                   # lower terminal end
        b.arc(Cl[0], Cl[1], r, a0, 0.0)
        b.line(xt, y_l + r)
        b.arc(xc, y_l + r, r, 0.0, -math.pi / 2)
    else:
        b.arc(Cl[0], Cl[1], r, a0, -math.pi / 2)
    tn, Nl = necks[+1]
    b.line(Nl[0], y_l)                                # slot, lower edge
    Tcl = fc(tn)
    b.arc(Nl[0], Nl[1], rn, -math.pi / 2, math.atan2(Tcl[1] - Nl[1], Tcl[0] - Nl[0]))
    tnu, Nu = necks[-1]
    b.curve(fc, dfc, tn, tnu + TAU)                   # counter
    Tcu = fc(tnu)
    b.arc(Nu[0], Nu[1], rn, math.atan2(Tcu[1] - Nu[1], Tcu[0] - Nu[0]), math.pi / 2)
    a1 = math.atan2(Tu[1] - Cu[1], Tu[0] - Cu[0])
    if ku == 'two':                                   # upper terminal end
        b.line(xc, y_u)
        b.arc(xc, y_u - r, r, math.pi / 2, 0.0)
        b.line(xt, Cu[1])
        b.arc(Cu[0], Cu[1], r, 0.0, a1)
    else:
        b.line(Cu[0], y_u)
        b.arc(Cu[0], Cu[1], r, math.pi / 2, a1 if a1 < math.pi / 2 else a1 - TAU)
    b.close()
    shape = pathops.simplify(b.p)
    if p['cut_w'] > 0:
        tr = math.radians(p['cut_angle'])
        ux, uy = math.cos(tr), math.sin(tr)
        nx, ny = -uy, ux
        mx, my = nx * p['cut_d'], ny * p['cut_d']
        w2, L = p['cut_w'] / 2, 5.0
        shape = diff(shape, polygon([(mx - ux * L - nx * w2, my - uy * L - ny * w2), (mx + ux * L - nx * w2, my + uy * L - ny * w2),
                                     (mx + ux * L + nx * w2, my + uy * L + ny * w2), (mx - ux * L + nx * w2, my - uy * L + ny * w2)]))
    return transform(shape, R, cx, cy)


def mark_fit(box, **over):
    """Mark scaled and centred so its bounding box is centred in box = (x, y, w, h) with height h."""
    x, y, w, h = box
    unit = mark(1.0, **over)
    x0, y0, x1, y1 = bbox(unit)
    R = h / (y1 - y0)
    return transform(unit, R, x + w / 2 - (x0 + x1) / 2 * R, y + h / 2 - (y0 + y1) / 2 * R)


# ========================================================================================= wordmark
# Letters in design units: x-height 500, baseline y = 0, y pointing down. Measured on the owner's
# integrated wordmark (heavy rounded geometric sans, single-storey a, t with a flat top and a foot,
# y with a hooked tail) and rounded to a small set of shared values.
WM = dict(
    stem=158, rs=36,                                   # vertical stem, stem corner radius
    rxo=269, ryo=258, no=2.1, rxi=109, ryi=98, ni=2.05, ring_cy=-250,   # bowls (o, a, p): overshoot 8
    a_stem=119,                                        # a: stem starts this far right of the bowl centre
    desc=188,                                          # p: descender
    t_top=-638, t_ct=136, t_ft=147, t_left=57, t_right=254, t_rbl=121, t_rin=16,
    y_aw=170, y_slope=0.363, y_tb=200, y_xr=545, y_te=41, y_Ro=264, y_Ri=90, y_tt=139, y_rs=38, y_rt=30,
    l_top=-667,
    # spacing. The study sets the letters so tight that l/o and t/y touch; these gaps keep that
    # density with clean separations (every neighbouring pair stays at least ~20 units apart).
    gap_ap=30,       # a stem to p stem
    gap_pt=45,       # p bowl (widest point) to t stem
    gap_ty=4,        # t crossbar end to y arm (top corners, they spread apart below)
    gap_yl=4,        # y right arm top corner (sharp construction point) to l
    gap_lo=22,       # l to o
    c_h=2 * 258 / 500,   # height of the C relative to the x-height: the same as the bowls of a, p, o
                         # (2 * ryo, overshoot included), so the word reads as one line. The study
                         # set it at 1.18 and the owner found the C too big.
    c_gap=20,        # C (right edge of its terminals) to the a's bowl
)


def wm_positions():
    w = WM
    p_cx = w['a_stem'] + w['stem'] + w['gap_ap'] + w['stem'] + w['a_stem']
    t_x = p_cx + w['rxo'] + w['gap_pt']
    y_x = t_x + w['t_right'] + w['gap_ty']
    l_x = y_x + w['y_xr'] + w['gap_yl']
    o_cx = l_x + w['stem'] + w['gap_lo'] + w['rxo']
    return dict(p_cx=p_cx, t_x=t_x, y_x=y_x, l_x=l_x, o_cx=o_cx)


def _ring(cx):
    w = WM
    return diff(superellipse(cx, w['ring_cy'], w['rxo'], w['ryo'], w['no']),
                superellipse(cx, w['ring_cy'], w['rxi'], w['ryi'], w['ni']))


def glyph_a(cx):
    w = WM
    sx = cx + w['a_stem']
    return union(_ring(cx), rrect(sx, -500, sx + w['stem'], 0, w['rs']))


def glyph_p(cx):
    w = WM
    sx = cx - w['a_stem'] - w['stem']
    return union(_ring(cx), rrect(sx, -500, sx + w['stem'], w['desc'], w['rs']))


def glyph_o(cx):
    return _ring(cx)


def glyph_l(x):
    w = WM
    return rrect(x, w['l_top'], x + w['stem'], 0, w['rs'])


def glyph_t(tx):
    w = WM
    xs, X, B = tx + w['stem'], -500, 0
    tr = tx + w['t_right']
    pts = [(tx, w['t_top']), (xs, w['t_top']), (xs, X), (tr, X), (tr, X + w['t_ct']), (xs, X + w['t_ct']),
           (xs, B - w['t_ft']), (tr, B - w['t_ft']), (tr, B), (tx, B), (tx, X + w['t_ct']),
           (tx - w['t_left'], X + w['t_ct']), (tx - w['t_left'], X), (tx, X)]
    rs, ri = w['rs'], w['t_rin']
    rad = [rs, rs, ri, rs, rs, ri, ri, rs, rs, w['t_rbl'], ri, rs, rs, ri]
    return rounded_polygon(pts, rad)


def glyph_y(xl):
    """Two arms with flat rounded tops; the right arm turns into a hooked tail (a ring sector)."""
    w = WM
    X = -500
    aw, sL, sR = w['y_aw'], w['y_slope'], -w['y_slope']
    xr = xl + w['y_xr']
    rs, rt, Ro, Ri, tt, y_tb = w['y_rs'], w['y_rt'], w['y_Ro'], w['y_Ri'], w['y_tt'], w['y_tb']
    x_te = xl + w['y_te']
    cphi = 1 / math.sqrt(1 + sR * sR)
    nrm = np.array([1.0, -sR]) * cphi                 # unit normal of the right arm, pointing right/down
    co = np.array([xr + sR * (y_tb - Ro - X) - Ro / cphi, y_tb - Ro])        # outer hook centre
    ci = np.array([xr - aw + sR * (y_tb - tt - Ri - X) - Ri / cphi, y_tb - tt - Ri])  # inner hook centre
    To, Ti = co + Ro * nrm, ci + Ri * nrm
    ang0 = math.atan2(nrm[1], nrm[0])
    TL, TR = (xr - aw, X), (xr, X)
    a1, c1, C1, s1, e1 = fillet(Ti, TL, TR, rs)
    a2, c2, C2, s2, e2 = fillet(TL, TR, To, rs)
    BL, UL = (x_te, y_tb), (x_te, y_tb - tt)
    a3, c3, C3, s3, e3 = fillet((co[0], y_tb), BL, UL, rt)
    a4, c4, C4, s4, e4 = fillet(BL, UL, (ci[0], y_tb - tt), rt)
    b = Builder()
    b.move(*c1)
    b.line(*a2)
    b.arc(C2[0], C2[1], rs, s2, e2)
    b.line(*To)
    b.arc(co[0], co[1], Ro, ang0, math.pi / 2)
    b.line(*a3)
    b.arc(C3[0], C3[1], rt, s3, e3)
    b.line(*a4)
    b.arc(C4[0], C4[1], rt, s4, e4)
    b.line(ci[0], y_tb - tt)
    b.arc(ci[0], ci[1], Ri, math.pi / 2, ang0)
    b.line(*a1)
    b.arc(C1[0], C1[1], rs, s1, e1)
    b.close()
    right = b.p
    # left arm: its edges run into the right arm's inner edge (crotch and V), overlapping it slightly
    ov = 0.02 * aw
    xin = lambda y: xr - aw + sR * (y - X) + ov
    yc = X + (xr - aw + ov - (xl + aw)) / (sL - sR)
    yv = X + (xr - aw + ov - xl) / (sL - sR)
    left = rounded_polygon([(xl, X), (xl + aw, X), (xin(yc), yc), (xin(yv), yv)], [rs, rs, 0, 0])
    return union(right, left)


def wordmark(**mark_over):
    """The full wordmark as one path, in design units (baseline 0, x-height 500)."""
    w = WM
    q = wm_positions()
    letters = [glyph_a(0), glyph_p(q['p_cx']), glyph_t(q['t_x']), glyph_y(q['y_x']), glyph_l(q['l_x']),
               glyph_o(q['o_cx'])]
    # the C: height c_h * x-height, centred on the x-height band, terminals c_gap left of the a
    unit = mark(1.0, **mark_over)
    x0, y0, x1, y1 = bbox(unit)
    R = w['c_h'] * 500 / (y1 - y0)
    right = -w['rxo'] - w['c_gap']
    c = transform(unit, R, right - x1 * R, -250 - (y0 + y1) / 2 * R)
    return union(c, *letters)


# ============================================================================================ SVG io
def fmt(v):
    s = '%.2f' % v
    s = s.rstrip('0').rstrip('.') if '.' in s else s
    return '0' if s in ('-0', '') else s


def svg_doc(w, h, body, vb=None, title='', desc='', px=None):
    vb = vb or (0, 0, w, h)
    pw, ph = (px if px else (w, h))
    head = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="%s" height="%s">\n' %
            (' '.join(fmt(v) for v in vb), fmt(pw), fmt(ph)))
    if title:
        head += '  <title>%s</title>\n' % title
    if desc:
        head += '  <desc>%s</desc>\n' % desc
    return head + body + '</svg>\n'


def write(name, text):
    path = os.path.join(HERE, name)
    with open(path, 'w') as fh:
        fh.write(text)
    return path


def path_el(p, fill, extra=''):
    return '  <path d="%s" fill="%s"%s/>\n' % (svg_d(p), fill, extra)


# ======================================================================================== symbol files
SYMBOL_BOX = (112, 112, 800, 800)   # the mark's bounding box is centred in this box, 800 units tall
TILE_R = 120                          # tile corner radius on the 1024 tile (as on the board)
TILE_MARK = 0.54                      # mark height relative to the tile


def symbol_svgs():
    m = mark_fit(SYMBOL_BOX)
    desc = 'Captylo app symbol: a heavy round C with a diagonal cut. Generated by brand.py.'
    write('symbol.svg', svg_doc(1024, 1024, path_el(m, INK), title='Captylo symbol', desc=desc, px=(512, 512)))
    write('symbol-white.svg', svg_doc(1024, 1024, path_el(m, WHITE), title='Captylo symbol (white)', desc=desc, px=(512, 512)))
    s = 1024 * TILE_MARK
    mt = mark_fit(((1024 - s) / 2, (1024 - s) / 2, s, s))
    ink = '  <rect width="1024" height="1024" rx="%d" fill="%s"/>\n' % (TILE_R, INK) + path_el(mt, WHITE)
    write('symbol-on-ink.svg', svg_doc(1024, 1024, ink, title='Captylo symbol on %s' % THEME['ink_name'], desc=desc, px=(512, 512)))
    ivory = ('  <rect x="3" y="3" width="1018" height="1018" rx="%d" fill="%s" stroke="%s" stroke-width="6"/>\n'
             % (TILE_R - 3, IVORY, NEUTRALS[2])) + path_el(mt, INK)
    write('symbol-on-ivory.svg', svg_doc(1024, 1024, ivory, title='Captylo symbol on %s' % THEME['light_name'], desc=desc, px=(512, 512)))


# ====================================================================================== wordmark files
WM_SCALE = 0.2   # nominal px per design unit in the SVG width/height (x-height = 100 px)


def wordmark_svgs():
    w = wordmark()
    x0, y0, x1, y1 = bbox(w)
    x0, y0, x1, y1 = math.floor(x0), math.floor(y0), math.ceil(x1), math.ceil(y1)
    vb = (x0, y0, x1 - x0, y1 - y0)
    px = ((x1 - x0) * WM_SCALE, (y1 - y0) * WM_SCALE)
    desc = 'Captylo wordmark, outlined (no font needed). Design units: x-height 500, baseline y = 0. Generated by brand.py.'
    write('wordmark.svg', svg_doc(0, 0, path_el(w, INK), vb=vb, px=px, title='Captylo wordmark', desc=desc))
    write('wordmark-white.svg', svg_doc(0, 0, path_el(w, WHITE), vb=vb, px=px, title='Captylo wordmark (white)', desc=desc))
    # inverse plate: proportions of the board (side padding 15% of the word, x-height centred)
    ww = x1 - x0
    padx = 0.15 * ww
    ph = 0.46 * ww
    top = -250 - ph / 2
    pvb = (x0 - padx, top, ww + 2 * padx, ph)
    body = '  <rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="%s"/>\n' % (
        fmt(pvb[0]), fmt(pvb[1]), fmt(pvb[2]), fmt(pvb[3]), fmt(0.055 * ph), INK) + path_el(w, WHITE)
    write('wordmark-inverse.svg', svg_doc(0, 0, body, vb=pvb, px=(pvb[2] * WM_SCALE, pvb[3] * WM_SCALE),
                                          title='Captylo wordmark (inverse)', desc=desc))
    return vb


# ============================================================================================ app icon
SQUIRCLE = ('M627.36 100c103.83 0 155.75 0 195.41 20.21a185.4 185.4 0 0 1 81.02 81.02c20.21 39.66 20.21 91.58 20.21 '
            '195.41L924 627.36c0 103.83 0 155.75 -20.21 195.41a185.4 185.4 0 0 1 -81.02 81.02c-39.66 20.21 -91.58 20.21 '
            '-195.41 20.21L396.64 924c-103.83 0 -155.75 0 -195.41 -20.21a185.4 185.4 0 0 1 -81.02 -81.02c-20.21 -39.66 '
            '-20.21 -91.58 -20.21 -195.41L100 396.64c0 -103.83 0 -155.75 20.21 -195.41a185.4 185.4 0 0 1 81.02 -81.02c39.66 '
            '-20.21 91.58 -20.21 195.41 -20.21Z')

# Gradient field of the plate: an 11 x 11 colour grid over the body (rows top to bottom), sampled from
# the reference icon (median colours, the area under the C inpainted, lightly smoothed). It is drawn as
# an exact bilinear interpolation: each row is a horizontal linear gradient, and the next row is laid
# over it through a 0 -> 1 vertical opacity ramp. Pure vector gradients, no bitmap, no filter.
# Reading it: Iris runs on the diagonal from the upper left through the counter to the lower right,
# Apricot holds the lower left and the upper right, rose and lilac sit in between, the corners frost.
IRIS_FIELD_GRID = [
    'CFC9FB A4A0FC 908DFC 9D95FC B7A9FC CEBCFC DFC9FC F0D8F5 FCE8E8 FEEDDF FEECDA',
    'B3AAFC 968FFC 8582FC 8A85FB 9D92FB B3A1FB C7AEFB DDBEF3 F7D4DD FDE0D0 FEE6D2',
    'C2B4FD A89CFC 9089FB 847FF9 8980F8 9B8BF8 B197F6 C8A4ED E6BBD8 FBD3C6 FEE0CC',
    'D7C5FD C1AEFD A99BFC 978BF7 8F83F5 9283F4 A58DF0 BB99E8 D6A9D9 F6C6C8 FDDECF',
    'EAD1FA D9C2FA BBA5F9 A390F4 8F80F2 8277F1 9682EE AD8FE9 CAA2E1 EEC1D3 FADEDB',
    'F9E0E9 E8C3E7 C09BEC A98CEB 8F7CED 7C6FEB 8B79EB A489EB CEAAE7 E6BAE1 EDC7E7',
    'FDE1D5 F5C6CE D5A3D3 B68FDE 987DE9 8E74E8 8C75E7 9B80E8 B793E9 C29FF0 D4B4F7',
    'FED9C5 FBC6BB E7A7BA C994CE B188DF A780E6 9177E8 8673EA 8978EE 9C8BF8 BBAAFC',
    'FEDBC4 FDCCB8 F3B5B8 D59BCB BB8DDD A482E7 8975EB 7168EC 746FF0 8681F9 A59CFC',
    'FEE5D0 FED9C3 FBCBC6 E6B4D8 C69CE7 A68AEF 8E7DF2 7D75F4 7977F8 8684FC A5A0FC',
    'FEECE0 FEE8D6 FEE2D8 F8D6E8 E6C5F6 CEB6FB B8A6FB A198FC 9390FC A1A0FC C8C5FB',
]


def _rgb(h):
    h = h.lstrip('#')
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], float)


def _hex(c):
    return ''.join('%02X' % int(round(min(255.0, max(0.0, v)))) for v in c)


def water_grid(nx, ny, base, blooms=(), bands=(), aspect=1.0, dim=TIDE_DIM):
    """Deep Tide colour grid (rows of hex, top to bottom) for grid_field. u runs 0..1 left to right,
    v 0..1 top to bottom; distances are measured in units of the height (u is scaled by aspect).
      base    ((du, dv), [(t, hex), ...]): a linear ramp along the direction (du, dv), t from 0 to 1
      blooms  [(u, v, radius, strength, hex)]: Gaussian light mixed over the ramp, in order
      bands   [((u0, v0), (u1, v1), half_width, strength, hex)]: soft light bands along a line (waves)
    Then every colour is dimmed by `dim` (a black overlay, as the lab's background dimmer)."""
    (du, dv), stops = base
    lo, hi = min(0, du) + min(0, dv), max(0, du) + max(0, dv)
    rows = []
    for j in range(ny):
        v = j / (ny - 1)
        row = []
        for i in range(nx):
            u = i / (nx - 1)
            t = ((u * du + v * dv) - lo) / (hi - lo)
            for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
                if t <= t1 or (t1, c1) == stops[-1]:
                    k = min(1.0, max(0.0, (t - t0) / (t1 - t0)))
                    k = k * k * (3 - 2 * k)
                    c = _rgb(c0) + (_rgb(c1) - _rgb(c0)) * k
                    break
            for (a, b), (e, f), hw, s, col in bands:
                ax, ay, ex, ey = a * aspect, b, e * aspect, f
                nxl, nyl = -(ey - ay), ex - ax
                ln = math.hypot(nxl, nyl)
                dd = ((u * aspect - ax) * nxl + (v - ay) * nyl) / ln
                c = c + (_rgb(col) - c) * s * math.exp(-dd * dd / (2 * hw * hw))
            for bu, bv, r, s, col in blooms:
                d2 = ((u - bu) * aspect) ** 2 + (v - bv) ** 2
                c = c + (_rgb(col) - c) * s * math.exp(-d2 / (2 * r * r))
            row.append(_hex(c * (1 - dim)))
        rows.append(' '.join(row))
    return rows


# Deep glacier: the saturated teal between Petrol and Glacier. Mixing Petrol straight into Glacier goes
# grey in sRGB; laying this under each Glacier bloom keeps the light clear, as light in deep water.
TIDE_DEEP = '#2A8581'
# Deep Tide plate: dark water lit from below right. Abyss holds the upper left, the ramp deepens into
# Petrol towards the lower right, where Glacier light blooms through the water; a Fog haze sits in the
# upper right and on the left edge where the first streak enters, and two faint Glacier waves run
# parallel to the streaks. The counter and the cut read as Petrol, so the white C keeps full contrast.
TIDE_FIELD_GRID = water_grid(
    11, 11,
    base=((0.62, 0.38), [(0.0, ABYSS), (0.35, '#132F35'), (0.7, PETROL), (1.0, '#2A5A62')]),
    bands=[((0.0, 0.92), (1.0, 0.50), 0.07, 0.36, TIDE_DEEP),
           ((0.0, 0.30), (1.0, -0.12), 0.06, 0.14, TIDE_DEEP)],
    blooms=[(1.06, 1.06, 0.40, 0.80, TIDE_DEEP),
            (1.04, 1.04, 0.22, 0.90, GLACIER),
            (0.66, 0.86, 0.18, 0.22, GLACIER),
            (1.0, -0.04, 0.22, 0.40, TIDE_DEEP),
            (0.98, -0.02, 0.14, 0.22, FOG),
            (-0.04, 0.50, 0.17, 0.20, FOG)])
FIELD_GRID = TIDE_FIELD_GRID if TIDE else IRIS_FIELD_GRID

# Icon details per palette. Deep Tide: Glacier glow and halo, a Glacier-tinted frost that is fainter
# than on the pastel plate (white frost would turn milky on dark water), an Abyss mark shadow.
ICON_STYLE = dict(
    tide=dict(halo=(GLACIER, '#CDEFEA', GLACIER), halo2=FOG, base='#1F454C', frost=GLACIER, frost_op=('0.17', '0.12'),
              rim=(SALT, '0.7', '0.3', '0.65'), shadow=('#04141A', '0.42', '0.34'), mark_end=SALT),
    iris=dict(halo=(IRIS, '#B7A8F6', IRIS), halo2=APRICOT, base='#A99BF8', frost='#FFFFFF', frost_op=('0.38', '0.22'),
              rim=('#FFFFFF', '0.95', '0.6', '0.9'), shadow=('#3A2DB8', '0.30', '0.22'), mark_end='#F6F4FF'),
)[PALETTE_NAME]
STREAK_GLOW, STREAK_CORE = (GLACIER, SALT) if TIDE else (WHITE, WHITE)
# Light streaks (silk lines), as cubic curves in body coordinates: (points, width, opacity).
# As on the reference, one streak rises from the left edge into the back of the C, the other leaves
# through the mouth and rises to the right edge; their hidden ends sit under the white mark.
FIELD_STREAKS = [
    (((-0.02, 0.47), (0.08, 0.43), (0.18, 0.38), (0.32, 0.33)), 0.0045, 1.0),
    (((0.64, 0.57), (0.78, 0.50), (0.90, 0.45), (1.02, 0.40)), 0.0045, 1.0),
]


def grid_field(pid, x, y, w, h, grid):
    """Bilinear colour field over the rectangle (x, y, w, h) from a grid of hex rows. Returns (defs, group)."""
    rows = [r.split() for r in grid]
    ny, nx = len(rows), len(rows[0])
    d, g = [], []
    for j, row in enumerate(rows):
        d.append('  <linearGradient id="%s-r%d" x1="%s" y1="0" x2="%s" y2="0" gradientUnits="userSpaceOnUse">'
                 % (pid, j, fmt(x), fmt(x + w)))
        d.append(''.join('<stop offset="%s" stop-color="#%s"/>' % (fmt(i / (nx - 1)), c) for i, c in enumerate(row)))
        d.append('</linearGradient>\n')
    dy = h / (ny - 1)
    for j in range(ny - 1):
        y0, y1 = y + j * dy, y + (j + 1) * dy
        e0 = y - 1 if j == 0 else y0            # the outer bands reach past the edge
        # overlap (a third of a band, so it holds at 16 px too): the next band's opaque edge lands on equal colour
        e1 = y + h + 1 if j == ny - 2 else y1 + dy / 3
        d.append('  <linearGradient id="%s-v%d" x1="0" y1="%s" x2="0" y2="%s" gradientUnits="userSpaceOnUse">'
                 '<stop offset="0" stop-color="#FFF" stop-opacity="0"/><stop offset="1" stop-color="#FFF"/></linearGradient>\n'
                 % (pid, j, fmt(y0), fmt(y1)))
        d.append('  <mask id="%s-m%d" mask-type="alpha" style="mask-type:alpha" maskUnits="userSpaceOnUse" x="%s" y="%s" width="%s" height="%s">'
                 '<rect x="%s" y="%s" width="%s" height="%s" fill="url(#%s-v%d)"/></mask>\n'
                 % (pid, j, fmt(x - 1), fmt(e0), fmt(w + 2), fmt(e1 - e0), fmt(x - 1), fmt(e0), fmt(w + 2), fmt(e1 - e0), pid, j))
        rect = '<rect x="%s" y="%s" width="%s" height="%s" fill="url(#%s-r%%d)"%%s/>' % (fmt(x - 1), fmt(e0), fmt(w + 2), fmt(e1 - e0), pid)
        g.append('  ' + rect % (j, '') + rect % (j + 1, ' mask="url(#%s-m%d)"' % (pid, j)) + '\n')
    return ''.join(d), ''.join(g)


def field_defs(pid, x, y, s, streaks=FIELD_STREAKS, streak_blur=1.0):
    """Defs + group for the plate's gradient field mapped onto the square (x, y, s). Returns (defs, group)."""
    dd_, gg_ = grid_field(pid, x, y, s, s, FIELD_GRID)
    d, g = [dd_], [gg_]
    if streaks:
        d.append('  <filter id="%s-glow" x="%s" y="%s" width="%s" height="%s" filterUnits="userSpaceOnUse" '
                 'color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="%s"/></filter>\n'
                 % (pid, fmt(x - s * 0.1), fmt(y - s * 0.1), fmt(s * 1.2), fmt(s * 1.2), fmt(s * 0.012)))
        d.append('  <filter id="%s-soft" x="%s" y="%s" width="%s" height="%s" filterUnits="userSpaceOnUse" '
                 'color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="%s"/></filter>\n'
                 % (pid, fmt(x - s * 0.1), fmt(y - s * 0.1), fmt(s * 1.2), fmt(s * 1.2), fmt(s * 0.0015 * streak_blur)))
        for pts, wdt, op in streaks:
            (a, b1, b2, c) = [(x + p[0] * s, y + p[1] * s) for p in pts]
            dd = 'M%s %sC%s %s %s %s %s %s' % (fmt(a[0]), fmt(a[1]), fmt(b1[0]), fmt(b1[1]), fmt(b2[0]), fmt(b2[1]), fmt(c[0]), fmt(c[1]))
            g.append('  <path d="%s" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="%s" '
                     'stroke-linecap="round" filter="url(#%s-glow)"/>\n' % (dd, STREAK_GLOW, fmt(op * 0.55), fmt(wdt * s * 6), pid))
            g.append('  <path d="%s" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="%s" '
                     'stroke-linecap="round" filter="url(#%s-soft)"/>\n' % (dd, STREAK_CORE, fmt(op), fmt(wdt * s), pid))
    return ''.join(d), ''.join(g)


ICON_MARK_H = 0.58     # mark height relative to the 824 body (the board: about 57% of the plate width)
ICON_MARK_DY = 0.006    # optical: the mark sits a hair below the plate centre


def icon_svg(size='master'):
    """1024 macOS icon. size: 'master' (64 px and up), '32' or '16' (hinted small masters)."""
    small = size != 'master'
    over = {}
    if size == '32':
        over = dict(cut_w=0.22, h=0.2)                 # cut about 1.3 px, mouth about 2.4 px at 32 px
    elif size == '16':
        over = dict(cut_w=0, h=0.24, rn=0.16)          # at 16 px a 1 px cut only muddies the C: plain C
    mh = 824 * (ICON_MARK_H + (0.06 if size == '32' else 0.14 if size == '16' else 0))
    m = mark(1.0, **over)
    bx0, by0, bx1, by1 = bbox(m)
    if small:                                            # snap the C's height and top edge to whole pixels
        px = 1024 / int(size)
        mh = round(mh / px) * px
    R = mh / (by1 - by0)
    cx = 512 - (bx0 + bx1) / 2 * R
    cy = 512 + ICON_MARK_DY * 824 - (by0 + by1) / 2 * R
    if small:
        top = cy + by0 * R
        cy += round(top / px) * px - top
        left = cx + bx0 * R
        cx += round(left / px) * px - left
    m = transform(m, R, cx, cy)
    streaks = [] if size == '16' else FIELD_STREAKS if not small else FIELD_STREAKS[:1]
    fdefs, fgroup = field_defs('f', 100, 100, 824, streaks=streaks, streak_blur=3 if small else 1)
    rim_w = 7 if not small else 16 if size == '32' else 0
    parts = []
    parts.append('  <defs>\n')
    parts.append('  <path id="squircle" d="%s"/>\n' % SQUIRCLE)
    parts.append('  <clipPath id="body"><use href="#squircle"/></clipPath>\n')
    parts.append(fdefs)
    st = ICON_STYLE
    parts.append('  <linearGradient id="halo" x1="100" y1="100" x2="924" y2="924" gradientUnits="userSpaceOnUse">\n'
                 '    <stop offset="0" stop-color="%s"/>\n    <stop offset="0.5" stop-color="%s"/>\n'
                 '    <stop offset="1" stop-color="%s"/>\n  </linearGradient>\n' % st['halo'])
    parts.append('  <linearGradient id="halo2" x1="100" y1="0" x2="924" y2="0" gradientUnits="userSpaceOnUse">\n'
                 '    <stop offset="0" stop-color="%s" stop-opacity="0"/>\n    <stop offset="0.55" stop-color="%s" stop-opacity="0"/>\n'
                 '    <stop offset="1" stop-color="%s"/>\n  </linearGradient>\n' % ((st['halo2'],) * 3))
    parts.append('  <filter id="outerGlow" x="0" y="0" width="1024" height="1024" filterUnits="userSpaceOnUse" '
                 'color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="30"/></filter>\n')
    parts.append('  <filter id="frost" x="0" y="0" width="1024" height="1024" filterUnits="userSpaceOnUse" '
                 'color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="%d"/></filter>\n' % (16 if not small else 22))
    parts.append('  <filter id="markShadow" x="0" y="0" width="1024" height="1024" filterUnits="userSpaceOnUse" '
                 'color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="%d"/></filter>\n' % (16 if not small else 10))
    parts.append('  <linearGradient id="markFill" x1="0" y1="%s" x2="0" y2="%s" gradientUnits="userSpaceOnUse">\n'
                 '    <stop offset="0" stop-color="#FFFFFF"/>\n    <stop offset="1" stop-color="%s"/>\n  </linearGradient>\n'
                 % (fmt(cy + by0 * R), fmt(cy + by1 * R), st['mark_end']))
    rc, r0, r1, r2 = st['rim']
    parts.append('  <linearGradient id="rim" x1="100" y1="100" x2="924" y2="924" gradientUnits="userSpaceOnUse">\n'
                 '    <stop offset="0" stop-color="%s" stop-opacity="%s"/>\n'
                 '    <stop offset="0.5" stop-color="%s" stop-opacity="%s"/>\n'
                 '    <stop offset="1" stop-color="%s" stop-opacity="%s"/>\n  </linearGradient>\n' % (rc, r0, rc, r1, rc, r2))
    parts.append('  </defs>\n')
    # soft outer glow (Glacier in Deep Tide, Iris and Apricot in Iris; kept faint: it lives in the margin,
    # like Apple's shadow)
    if not small:
        parts.append('  <g opacity="0.5" filter="url(#outerGlow)"><use href="#squircle" fill="url(#halo)"/>'
                     '<use href="#squircle" fill="url(#halo2)"/></g>\n')
    # opaque base with the plain shape's own antialiasing, so the body edge is exactly as opaque as the squircle
    parts.append('  <use href="#squircle" fill="%s"/>\n' % st['base'])
    parts.append('  <g clip-path="url(#body)">\n')
    parts.append(fgroup)
    # frosted edge: a soft light inner glow along the rim, strongest at the corners
    if size != '16':
        parts.append('  <use href="#squircle" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="%d" filter="url(#frost)"/>\n'
                     % (st['frost'], st['frost_op'][0] if not small else st['frost_op'][1], 36 if not small else 60))
    if rim_w:
        parts.append('  <use href="#squircle" fill="none" stroke="url(#rim)" stroke-width="%d"/>\n' % rim_w)
    parts.append('  </g>\n')
    # the mark: white, lifted by a soft shadow in the plate's deepest colour
    parts.append('  <path d="%s" fill="%s" opacity="%s" transform="translate(0 %d)" filter="url(#markShadow)"/>\n'
                 % (svg_d(m), st['shadow'][0], st['shadow'][1] if not small else st['shadow'][2], 12 if not small else 8))
    parts.append('  <path d="%s" fill="url(#markFill)"/>\n' % svg_d(m))
    title = {'master': 'Captylo app icon', '32': 'Captylo app icon, 32 px master', '16': 'Captylo app icon, 16 px master'}[size]
    desc = ('macOS icon grid: 1024 canvas, 824 body at (100, 100), continuous-corner squircle. The body is opaque. '
            'Filters use sRGB interpolation. Generated by brand.py.')
    return svg_doc(1024, 1024, ''.join(parts), title=title, desc=desc, px=(1024, 1024) if not small else (int(size), int(size)))


# ========================================================================================== menu bar
MENUBAR_OVER = dict(cut_w=0.19, h=0.2)   # cut about 1.5 px and mouth about 3 px at @1x


def menubar_mark():
    """Template glyph on an 18 x 18 pt canvas: 16 pt tall, terminal flats on a whole point."""
    m = mark(1.0, **MENUBAR_OVER)
    x0, y0, x1, y1 = bbox(m)
    R = 16 / (y1 - y0)
    return transform(m, R, 16.75 - x1 * R, 1 - y0 * R)


def menubar_rec_dot():
    """Recording cue: a Record dot filling the counter (centre and radius in pt)."""
    p = dict(MARK, **MENUBAR_OVER)
    m = mark(1.0, **MENUBAR_OVER)
    x0, y0, x1, y1 = bbox(m)
    R = 16 / (y1 - y0)
    tx, ty = 16.75 - x1 * R, 1 - y0 * R
    return tx + p['cdx'] * R, ty + p['cdy'] * R, 0.62 * min(p['crx'], p['cry']) * R


def menubar_svgs():
    m = menubar_mark()
    desc = 'Captylo menu bar glyph (template image: black on transparent, 18 x 18 pt). Generated by brand.py.'
    write('menubar.svg', svg_doc(18, 18, path_el(m, '#000000'), title='Captylo menu bar', desc=desc))
    cx, cy, r = menubar_rec_dot()
    dot = '  <circle cx="%s" cy="%s" r="%s" fill="%s"/>\n' % (fmt(cx), fmt(cy), fmt(r), '%s')
    write('menubar-recording.svg', svg_doc(18, 18, path_el(m, '#000000') + dot % RECORD, title='Captylo menu bar, recording',
                                           desc='Captylo menu bar glyph while recording: the template C plus a Record dot in '
                                                'the counter. Ship the C as a template image and draw the dot in Record '
                                                '(%s) on top, or use menubar-recording-template.svg. Generated by brand.py.' % RECORD))
    write('menubar-recording-template.svg', svg_doc(18, 18, path_el(m, '#000000') + dot % '#000000',
                                                    title='Captylo menu bar, recording (template)',
                                                    desc='All-black template version of the recording glyph. Generated by brand.py.'))


# ========================================================================================= glass hero
IRIS_HERO_GRID = [   # 21 x 9, sampled from the glass hero on the integrated wordmark board
    '533F8E 4B3D88 494298 5351C0 716FF0 8D84FB A897FC BCA7FC D1BAFD E1CCFD EFDAFD FAE5FC FADFFC FCDAF3 FED4E7 FED2D9 FED1CB FED2BF FED1BA FED4BC FEDBC5',
    '724CAC 5C4298 4B3E8D 434299 5256C4 7170ED 8A82F9 A898FC C0ADFC D8C6FD DBC2FC D8B2FC DFB0FC E8AEF2 F2B1E2 F9B6D0 FABCBE FDC0B0 FEC6AD FED1B7 FEDBC4',
    'AD80E6 8F66D4 6149AD 453F96 ABA9E8 9191E2 9D9AF1 B0AAFB BCB3FC B8ACFB C0B0F8 CEB7F6 D9B8F1 E4BBEA F3C8DE FDD8D6 FEE4D9 FDBAAC FECDB5 FED6BE FEC5AE',
    'CEACFC AC94F8 A28EF8 8076ED A19EE6 7072C9 6B6FCC 7475D9 7E7BDF 877EE1 9583DE AC91DF C199D9 D6A3D2 F0B9C6 FED0C6 FEE2D4 FEDCCE FEDCCE FEC3B2 FBBAAB',
    'B197F7 A591F5 A48CEF B798F0 DFD2FD A298EC 7471CF 6460C0 6360C1 6C62C4 8775CC 9A7BC6 B78CC6 C990C4 DFA2BD F0BCC3 E9C2DE CA9ADE D8A9DC FACAD1 FEE3D7',
    'C2A3F7 CDAAF7 E3BAF2 FAD2E6 FAE2E5 E2BADD B99EEB 8D81E0 857BDB 8778D8 9079D1 A47FD2 B48DD2 BB8DD2 B68FDB B694E8 BEA5F4 8E75EE B18DEB E9BCE2 FEE2DE',
    'EBBBED F2C8E4 FEE2DE FED6C0 FED8CF EDB9D1 CCA3E4 B097EF A594F1 A592EF A990ED B191EA AA8CE9 A188EB 9485EF 8D86F4 9E97FC 7F74F3 C4A6FC DEC2FD E7BFF6',
    'FED7D8 FEEADB FED3B7 FEC3AC FEB7AB F5AEC9 E0A6E6 C29DF4 B69FFA C0A7FB A891F9 8F7DF2 7C71ED 6D69E6 6867E6 7372EE 928CFC ADA5FC A198FC AA97FC C0A1FC',
    'FEEFDF FEDAC1 FECEB4 FEC9B4 FEC9BB FECBD0 F7C8E9 EED2FB DACAFD BAAAFD A297FD 948AFC 9289FB 9D94FC C5B7FD B2A5FD 9B93FC 8A85FC 8C86FD A295FC B6A0FC',
]
# Deep Tide hero (21 x 9, 1520 x 620): as the lab banner, near-black Abyss water in the upper left,
# Petrol in the middle, Glacier light welling up from the lower right with a Fog haze beside it, and
# glassy waves rising to the right along the silk lines.
TIDE_HERO_GRID = water_grid(
    21, 9, aspect=1520 / 620,
    base=((0.7, 0.3), [(0.0, '#0B1E22'), (0.3, ABYSS), (0.7, PETROL), (1.0, '#2B5C64')]),
    bands=[((0.0, 1.25), (1.0, 0.55), 0.13, 0.30, GLACIER),
           ((0.0, 0.62), (1.0, -0.10), 0.10, 0.12, FOG)],
    blooms=[(1.0, 1.1, 0.55, 0.95, GLACIER),
            (0.70, 1.05, 0.40, 0.45, FOG),
            (0.02, 1.05, 0.30, 0.20, PETROL)])
HERO_GRID = TIDE_HERO_GRID if TIDE else IRIS_HERO_GRID
# Hero details: silk glow and core (colour, opacity), capsule sheen (colour, top, middle, bottom
# opacity), capsule edge and wordmark shadow. On dark water a white sheen turns the glass milky, so
# Deep Tide tints it Glacier and keeps it thinner.
HERO_STYLE = dict(
    tide=dict(glow=(GLACIER, '0.6'), core=(SALT, '0.9'), sheen=(GLACIER, '0.16', '0.05', '0.1'),
              edge=(SALT, '0.45'), shadow=(ABYSS, '0.3')),
    iris=dict(glow=(WHITE, '0.8'), core=(WHITE, '1'), sheen=(WHITE, '0.26', '0.12', '0.2'),
              edge=(WHITE, '0.75'), shadow=('#3A2DB8', '0.18')),
)[PALETTE_NAME]


def glass_hero_svg(W=1520, H=620):
    """White wordmark in a clear glass capsule over the animated gradient field (website hero, board)."""
    hs = HERO_STYLE
    w = wordmark()
    x0, y0, x1, y1 = bbox(w)
    cap_w, cap_h = W * 0.63, H * 0.63
    cap_x, cap_y = (W - cap_w) / 2, (H - cap_h) / 2
    s = cap_w * 0.8 / (x1 - x0)                       # wordmark width: 80% of the capsule (as on the board)
    tx = W / 2 - (x0 + x1) / 2 * s
    ty = H / 2 + 250 * s - 0.02 * H                   # x-height band centred (a hair above centre)
    wm = transform(w, s, tx, ty)
    rx = cap_h * 0.16
    d = []
    d.append('  <defs>\n')
    # the silk field: colour grid sampled from the board's hero (lettering inpainted), bilinear
    gd, gg = grid_field('hero', 0, 0, W, H, HERO_GRID)
    d.append(gd)
    g = [gg]
    # silk: bright lines along the folds of the reference (they run behind the capsule)
    silk = [((-0.02, 0.31), (0.07, 0.29), (0.14, 0.31), (0.30, 0.48)), ((-0.02, 0.84), (0.08, 0.74), (0.16, 0.64), (0.30, 0.56)),
            ((0.70, 0.46), (0.84, 0.36), (0.92, 0.30), (1.02, 0.24)), ((0.60, 1.02), (0.76, 0.84), (0.88, 0.74), (1.02, 0.70))]
    d.append('  <filter id="silkBlur" x="0" y="0" width="%d" height="%d" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">'
             '<feGaussianBlur stdDeviation="26"/></filter>\n' % (W, H))
    d.append('  <filter id="lineBlur" x="0" y="0" width="%d" height="%d" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">'
             '<feGaussianBlur stdDeviation="1.4"/></filter>\n' % (W, H))
    d.append('  <filter id="lineGlow" x="0" y="0" width="%d" height="%d" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">'
             '<feGaussianBlur stdDeviation="7"/></filter>\n' % (W, H))
    for k, pts in enumerate(silk):
        (a, b1, b2, c) = [(p[0] * W, p[1] * H) for p in pts]
        dd = 'M%s %sC%s %s %s %s %s %s' % tuple(fmt(v) for v in (a[0], a[1], b1[0], b1[1], b2[0], b2[1], c[0], c[1]))
        (sg, sgo), (sc, sco) = hs['glow'], hs['core']
        g.append('  <path d="%s" fill="none" stroke="%s" stroke-opacity="0.16" stroke-width="%d" filter="url(#silkBlur)"/>\n' % (dd, sg, 60))
        g.append('  <path d="%s" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="12" filter="url(#lineGlow)"/>\n' % (dd, sg, sgo))
        g.append('  <path d="%s" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="3.4" filter="url(#lineBlur)"/>\n' % (dd, sc, sco))
    d.append('  <clipPath id="cap"><rect x="%s" y="%s" width="%s" height="%s" rx="%s"/></clipPath>\n'
             % (fmt(cap_x), fmt(cap_y), fmt(cap_w), fmt(cap_h), fmt(rx)))
    d.append('  <filter id="frosted" x="0" y="0" width="%d" height="%d" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">'
             '<feGaussianBlur stdDeviation="22"/></filter>\n' % (W, H))
    d.append('  <linearGradient id="capSheen" x1="0" y1="%s" x2="0" y2="%s" gradientUnits="userSpaceOnUse">'
             '<stop offset="0" stop-color="%s" stop-opacity="%s"/><stop offset="0.5" stop-color="%s" stop-opacity="%s"/>'
             '<stop offset="1" stop-color="%s" stop-opacity="%s"/></linearGradient>\n'
             % ((fmt(cap_y), fmt(cap_y + cap_h)) + sum(((hs['sheen'][0], o) for o in hs['sheen'][1:]), ())))
    d.append('  <filter id="wmShadow" x="0" y="0" width="%d" height="%d" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">'
             '<feGaussianBlur stdDeviation="10"/></filter>\n' % (W, H))
    d.append('  <g id="field">\n' + ''.join(g) + '  </g>\n')
    d.append('  </defs>\n')
    body = ''.join(d)
    body += '  <use href="#field"/>\n'
    body += '  <g clip-path="url(#cap)"><use href="#field" filter="url(#frosted)"/>'
    body += '<rect x="%s" y="%s" width="%s" height="%s" fill="url(#capSheen)"/></g>\n' % (fmt(cap_x), fmt(cap_y), fmt(cap_w), fmt(cap_h))
    body += ('  <rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="2"/>\n'
             % ((fmt(cap_x + 1), fmt(cap_y + 1), fmt(cap_w - 2), fmt(cap_h - 2), fmt(rx - 1)) + hs['edge']))
    body += '  <path d="%s" fill="%s" opacity="%s" transform="translate(0 6)" filter="url(#wmShadow)"/>\n' % (
        (svg_d(wm),) + hs['shadow'])
    body += path_el(wm, WHITE)
    return svg_doc(W, H, body, title='Captylo wordmark on glass', px=(W / 2, H / 2),
                   desc='White Captylo wordmark in a clear glass capsule over %s. Generated by brand.py.' % THEME['mood'])


# ============================================================================================ exports
def rsvg(src, out, w=None, h=None, zoom=None):
    cmd = ['rsvg-convert']
    if w:
        cmd += ['-w', str(int(w))]
    if h:
        cmd += ['-h', str(int(h))]
    if zoom:
        cmd += ['-z', str(zoom)]
    subprocess.run(cmd + [os.path.join(HERE, src), '-o', out], check=True)


APPICON_SIZES = [('16x16', '1x', 16), ('16x16', '2x', 32), ('32x32', '1x', 32), ('32x32', '2x', 64),
                 ('128x128', '1x', 128), ('128x128', '2x', 256), ('256x256', '1x', 256), ('256x256', '2x', 512),
                 ('512x512', '1x', 512), ('512x512', '2x', 1024)]


def icon_source(px):
    return 'icon-16.svg' if px <= 16 else 'icon-32.svg' if px <= 32 else 'icon.svg'


def exports():
    os.makedirs(PNG, exist_ok=True)
    for name in ('symbol', 'symbol-white', 'symbol-on-ink', 'symbol-on-ivory'):
        for s in (512, 1024):
            rsvg(name + '.svg', os.path.join(PNG, '%s-%d.png' % (name, s)), w=s, h=s)
    for name in ('wordmark', 'wordmark-white', 'wordmark-inverse', 'wordmark-glass'):
        for z in (2, 4):
            rsvg(name + '.svg', os.path.join(PNG, '%s@%dx.png' % (name, z)), zoom=z)
    for s in (1024, 512, 256, 128, 64):
        rsvg('icon.svg', os.path.join(PNG, 'icon-%d.png' % s), w=s, h=s)
    rsvg('icon-32.svg', os.path.join(PNG, 'icon-32.png'), w=32, h=32)
    rsvg('icon-16.svg', os.path.join(PNG, 'icon-16.png'), w=16, h=16)
    for name in ('menubar', 'menubar-recording', 'menubar-recording-template'):
        rsvg(name + '.svg', os.path.join(PNG, '%s.png' % name), w=18, h=18)
        rsvg(name + '.svg', os.path.join(PNG, '%s@2x.png' % name), w=36, h=36)
    # asset catalog
    os.makedirs(APPICON, exist_ok=True)
    images = []
    for size, scale, px in APPICON_SIZES:
        fn = 'icon_%s%s.png' % (size, '' if scale == '1x' else '@2x')
        rsvg(icon_source(px), os.path.join(APPICON, fn), w=px, h=px)
        images.append({'filename': fn, 'idiom': 'mac', 'scale': scale, 'size': size})
    with open(os.path.join(APPICON, 'Contents.json'), 'w') as fh:
        fh.write(json.dumps({'images': images, 'info': {'author': 'xcode', 'version': 1}}, indent=2, separators=(',', ' : ')) + '\n')


# ===================================================================================== contact sheets
LABEL_FONT = "font-family=\"'Avenir Next', 'Helvetica Neue', Arial, sans-serif\""


def nest(svg_text, x, y, w, h, prefix):
    """Inline a generated SVG document at (x, y, w, h), prefixing its ids so several can coexist."""
    ids = re.findall(r'id="([^"]+)"', svg_text)
    for i in sorted(set(ids), key=len, reverse=True):
        svg_text = svg_text.replace('id="%s"' % i, 'id="%s-%s"' % (prefix, i))
        svg_text = svg_text.replace('url(#%s)' % i, 'url(#%s-%s)' % (prefix, i))
        svg_text = svg_text.replace('href="#%s"' % i, 'href="#%s-%s"' % (prefix, i))
    vb = re.search(r'viewBox="([^"]+)"', svg_text).group(1)
    inner = svg_text[svg_text.index('>', svg_text.index('<svg')) + 1: svg_text.rindex('</svg>')]
    inner = re.sub(r'\s*<title>.*?</title>|\s*<desc>.*?</desc>', '', inner, flags=re.S)
    return '<svg x="%s" y="%s" width="%s" height="%s" viewBox="%s" overflow="visible">%s</svg>\n' % (
        fmt(x), fmt(y), fmt(w), fmt(h), vb, inner)


def label(x, y, text, size=15, fill=INK, spacing=2.6, weight=500, anchor='start'):
    return ('  <text x="%s" y="%s" %s font-size="%s" font-weight="%d" letter-spacing="%s" fill="%s" text-anchor="%s">%s</text>\n'
            % (fmt(x), fmt(y), LABEL_FONT, fmt(size), weight, fmt(spacing), fill, anchor, text))


def wordmark_c_centre():
    """Centre and R of the C inside the wordmark (design units)."""
    w = WM
    unit = mark(1.0)
    x0, y0, x1, y1 = bbox(unit)
    R = w['c_h'] * 500 / (y1 - y0)
    return -w['rxo'] - w['c_gap'] - x1 * R, -250 - (y0 + y1) / 2 * R, R


def b_column(icon_text):
    """The B column of the wider-cut study, rebuilt from the vectors at the study's own coordinates
    (1536 x 1024 board). Positions come from fitting the reference: symbol centre/R, the wordmark's
    C and x-height, the icon plates."""
    out = []
    out.append(label(553, 100, 'B / WIDER', size=17, spacing=3.2))
    out.append(path_el(transform(mark(1.0), 140.6, 780.2, 260.2), INK))
    # wordmark: x-height 61.7 px, its C centred where the reference C sits
    s = 61.7 / 500
    ccx, ccy, _ = wordmark_c_centre()
    out.append(path_el(transform(wordmark(), s, 612.9 - ccx * s, 477.7 - ccy * s), INK))
    # app icon: the 824 body on the reference plate (640..902, 562..818)
    k = 262 / 824
    out.append(nest(icon_text, 640 - 100 * k, 562 - 100 * k, 1024 * k, 1024 * k, 'bi'))
    out.append(path_el(transform(mark(1.0), 42.4, 693.5, 897.6), INK))
    k2 = 91 / 824
    out.append(nest(icon_text, 796 - 100 * k2, 852 - 100 * k2, 1024 * k2, 1024 * k2, 'si'))
    return ''.join(out)


def overview_png(icon_text):
    """Reference B column (left) next to the vector rebuild (right), same scale."""
    cx0, cy0, cw, ch = 525, 70, 485, 900
    z = 2
    W = (cw * 2 + 60) * z
    H = (ch + 70) * z
    ref = os.path.join(HERE, 'wider-cut-study.png')
    body = '  <rect width="%d" height="%d" fill="%s"/>\n' % (W, H, IVORY)
    body += label(30 * z, 40 * z, 'REFERENCE  -  WIDER CUT STUDY, COLUMN B', size=13 * z, spacing=2.4 * z)
    body += label((cw + 60) * z, 40 * z, 'VECTOR MASTER  -  GENERATED BY BRAND.PY', size=13 * z, spacing=2.4 * z)
    body += ('<svg x="%d" y="%d" width="%d" height="%d" viewBox="%d %d %d %d"><image href="%s" width="1536" height="1024"/></svg>\n'
             % (20 * z, 60 * z, cw * z, ch * z, cx0, cy0, cw, ch, ref))
    body += ('<svg x="%d" y="%d" width="%d" height="%d" viewBox="%d %d %d %d"><rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>%s</svg>\n'
             % ((cw + 40) * z, 60 * z, cw * z, ch * z, cx0, cy0, cw, ch, cx0, cy0, cw, ch, NEUTRALS[4], b_column(icon_text)))
    body += '  <line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="2"/>\n' % (
        (cw + 30) * z, 60 * z, (cw + 30) * z, (ch + 60) * z, NEUTRALS[3])
    tmp = os.path.join(HERE, '.overview.svg')
    with open(tmp, 'w') as fh:
        fh.write(svg_doc(W, H, body))
    subprocess.run(['rsvg-convert', tmp, '-o', os.path.join(HERE, 'overview.png')], check=True)
    os.remove(tmp)


def board_png(icon_text, glass_text):
    """The integrated wordmark board (1536 x 1024), rebuilt with the vectors: positive, glass,
    inverse, app icon, symbol and tiles, palette."""
    line, grey = NEUTRALS[0], NEUTRALS[1]
    b = ['  <rect width="1536" height="1024" fill="%s"/>\n' % IVORY]
    b.append(label(47, 43, 'CAPTYLO / INTEGRATED WORDMARK', size=14.5))
    b.append('  <line x1="422" y1="38" x2="1490" y2="38" stroke="%s" stroke-width="1.2"/>\n' % line)
    w = wordmark()
    x0, y0, x1, y1 = bbox(w)

    def place(x, y, width, fill):  # wordmark with its bbox left/top at (x, y), given width
        s = width / (x1 - x0)
        return path_el(transform(w, s, x - x0 * s, y - y0 * s), fill), s
    el, s = place(61, 132, 630, INK)
    b.append(el)
    b.append('<clipPath id="heroClip"><rect x="740" y="55" width="752" height="303" rx="14"/></clipPath>\n')
    b.append('<g clip-path="url(#heroClip)">' + nest(glass_text, 740, 55 - (752 * 620 / 1520 - 303) / 2, 752, 752 * 620 / 1520, 'gl') + '</g>\n')
    b.append('  <line x1="47" y1="373" x2="1490" y2="373" stroke="%s" stroke-width="1.2"/>\n' % line)
    b.append(label(48, 408, 'INVERSE WORDMARK', size=14.5))
    b.append('  <line x1="266" y1="403" x2="767" y2="403" stroke="%s" stroke-width="1.2"/>\n' % line)
    b.append('  <rect x="47" y="426" width="720" height="255" rx="14" fill="%s"/>\n' % INK)
    sw = 556 / (x1 - x0)
    b.append(path_el(transform(w, sw, 407 - (x0 + x1) / 2 * sw, 553.5 + 250 * sw), WHITE))
    b.append('  <line x1="795" y1="395" x2="795" y2="697" stroke="%s" stroke-width="1.2"/>\n' % line)
    b.append(label(823, 408, 'APP ICON', size=14.5))
    b.append('  <line x1="930" y1="403" x2="1490" y2="403" stroke="%s" stroke-width="1.2"/>\n' % line)
    k = 265 / 824
    b.append(nest(icon_text, 1135 - 512 * k, 556 - 512 * k, 1024 * k, 1024 * k, 'ic'))
    b.append('  <line x1="47" y1="713" x2="1490" y2="713" stroke="%s" stroke-width="1.2"/>\n' % line)
    b.append(label(48, 746, 'APP SYMBOL', size=14.5))
    b.append('  <line x1="190" y1="741" x2="667" y2="741" stroke="%s" stroke-width="1.2"/>\n' % line)
    b.append(path_el(mark_fit((62, 775, 184, 175)), INK))
    b.append('  <line x1="300" y1="780" x2="300" y2="940" stroke="%s" stroke-width="1.2"/>\n' % line)
    t = 143 / 1024
    for i, name in enumerate(('symbol-on-ink.svg', 'symbol-on-ivory.svg')):
        with open(os.path.join(HERE, name)) as fh:
            b.append(nest(fh.read(), 340 + i * 172, 786, 1024 * t, 1024 * t, 'tile%d' % i))
    b.append('  <line x1="695" y1="733" x2="695" y2="970" stroke="%s" stroke-width="1.2"/>\n' % line)
    b.append(label(723, 746, 'COLOR PALETTE', size=14.5))
    b.append('  <line x1="893" y1="741" x2="1490" y2="741" stroke="%s" stroke-width="1.2"/>\n' % line)
    for i, (name, hexv) in enumerate(PALETTE):
        x = 722 + i * 131
        stroke = ' stroke="%s" stroke-width="1.2"' % NEUTRALS[5] if name == THEME['light_name'] else ''
        b.append('  <rect x="%d" y="766" width="116" height="127" rx="6" fill="%s"%s/>\n' % (x, hexv, stroke))
        b.append(label(x + 1, 926, name, size=16, spacing=0.4))
        b.append(label(x + 1, 951, hexv, size=15, spacing=1.2, fill=grey, weight=400))
    tmp = os.path.join(HERE, '.board.svg')
    with open(tmp, 'w') as fh:
        fh.write(svg_doc(1536, 1024, ''.join(b)))
    subprocess.run(['rsvg-convert', '-z', '2', tmp, '-o', os.path.join(HERE, 'board.png')], check=True)
    os.remove(tmp)


# =============================================================================================== main
def main():
    symbol_svgs()
    wordmark_svgs()
    icon_text = icon_svg('master')
    write('icon.svg', icon_text)
    write('icon-32.svg', icon_svg('32'))
    write('icon-16.svg', icon_svg('16'))
    menubar_svgs()
    glass_text = glass_hero_svg()
    write('wordmark-glass.svg', glass_text)
    if '--svg-only' in sys.argv:
        return
    exports()
    overview_png(icon_text)
    board_png(icon_text, glass_text)
    print('done: SVGs, png/, AppIcon.appiconset/, overview.png, board.png')


if __name__ == '__main__':
    main()

