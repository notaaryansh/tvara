"""Geometric pattern generators for the tvara icon designer.

Each function returns a PIL.Image of fixed canvas size (default 1024) with
the pattern centered and color-themed via fg/bg. All shared transforms
(zoom, rotation, pan) are applied uniformly via `_apply_transform` so
adding a new pattern only means computing primitive shapes in
"design coordinates" — a unit square centered on the canvas — and
returning them as a list of draw calls. The transform layer handles the
rest.

The export pipeline downstream expects a square RGB image at 1024×1024.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Callable, Iterable, Sequence

import numpy as np
from PIL import Image, ImageDraw


CANVAS = 1024


# ---------------------------------------------------------------------------
# Drawing primitives in "design space"
# ---------------------------------------------------------------------------
#
# Patterns describe themselves as a sequence of (kind, params) tuples in a
# coordinate space centered at (0, 0) with extent roughly [-1, 1]. The
# transform layer below scales that to the canvas, applies pan / zoom /
# rotation, and rasterizes via PIL.


@dataclass
class Stroke:
    points: np.ndarray  # shape (N, 2), design coords
    width: float
    closed: bool = False


@dataclass
class Circle:
    cx: float
    cy: float
    r: float
    width: float = 0.0  # 0 = filled


@dataclass
class Dot:
    cx: float
    cy: float
    r: float


Primitive = Stroke | Circle | Dot


# ---------------------------------------------------------------------------
# Transform + raster
# ---------------------------------------------------------------------------


def _apply_transform(
    prims: Sequence[Primitive],
    zoom: float,
    rotation_deg: float,
    pan_x: float,
    pan_y: float,
    canvas: int = CANVAS,
) -> list[Primitive]:
    """Map design-space primitives to canvas-space.

    zoom: 1.0 fills ~80% of the canvas; >1 zooms in, <1 pulls back.
    rotation_deg: applied around the design-space origin.
    pan_x / pan_y: in design-space units; positive pushes the image
    right / down respectively after rotation.
    """
    half = canvas / 2
    scale = half * 0.8 * zoom  # 1 design unit = 80% half-canvas at zoom=1
    theta = math.radians(rotation_deg)
    cos_t, sin_t = math.cos(theta), math.sin(theta)

    def _xform_point(x: float, y: float) -> tuple[float, float]:
        # Rotate then pan, then map to canvas.
        rx = x * cos_t - y * sin_t
        ry = x * sin_t + y * cos_t
        rx += pan_x
        ry += pan_y
        return half + rx * scale, half + ry * scale

    out: list[Primitive] = []
    for p in prims:
        if isinstance(p, Stroke):
            pts = np.array([_xform_point(x, y) for x, y in p.points])
            out.append(Stroke(points=pts, width=p.width * scale * 0.01,
                              closed=p.closed))
        elif isinstance(p, Circle):
            cx, cy = _xform_point(p.cx, p.cy)
            out.append(Circle(cx=cx, cy=cy, r=p.r * scale,
                              width=p.width * scale * 0.01))
        elif isinstance(p, Dot):
            cx, cy = _xform_point(p.cx, p.cy)
            out.append(Dot(cx=cx, cy=cy, r=p.r * scale))
    return out


def _rasterize(
    prims: Sequence[Primitive],
    fg: str,
    bg: str,
    canvas: int = CANVAS,
) -> Image.Image:
    img = Image.new("RGB", (canvas, canvas), bg)
    draw = ImageDraw.Draw(img)
    for p in prims:
        if isinstance(p, Stroke):
            if len(p.points) < 2:
                continue
            w = max(1, int(round(p.width)))
            xy = [(float(x), float(y)) for x, y in p.points]
            if p.closed:
                xy.append(xy[0])
            draw.line(xy, fill=fg, width=w, joint="curve")
        elif isinstance(p, Circle):
            if p.width <= 0:
                draw.ellipse(
                    [p.cx - p.r, p.cy - p.r, p.cx + p.r, p.cy + p.r],
                    fill=fg,
                )
            else:
                draw.ellipse(
                    [p.cx - p.r, p.cy - p.r, p.cx + p.r, p.cy + p.r],
                    outline=fg, width=max(1, int(round(p.width))),
                )
        elif isinstance(p, Dot):
            draw.ellipse(
                [p.cx - p.r, p.cy - p.r, p.cx + p.r, p.cy + p.r],
                fill=fg,
            )
    return img


def render(
    prims: Sequence[Primitive],
    fg: str,
    bg: str,
    zoom: float,
    rotation_deg: float,
    pan_x: float,
    pan_y: float,
    canvas: int = CANVAS,
) -> Image.Image:
    """Apply transform + rasterize. Entry point each pattern uses."""
    transformed = _apply_transform(prims, zoom, rotation_deg, pan_x, pan_y, canvas)
    return _rasterize(transformed, fg, bg, canvas)


# ---------------------------------------------------------------------------
# Pattern generators
# ---------------------------------------------------------------------------


def phyllotaxis(
    n_points: int,
    angle_deg: float,
    spread: float,
    dot_size: float,
) -> list[Primitive]:
    """Sunflower-seed packing. The angle 137.508° (golden angle) gives the
    classic spiral; small deviations create dramatically different shapes."""
    angle_rad = math.radians(angle_deg)
    prims: list[Primitive] = []
    # Scale so the outermost seed sits at radius 1 in design space.
    if n_points <= 1:
        return prims
    c = spread / math.sqrt(n_points - 1)
    for i in range(n_points):
        r = c * math.sqrt(i)
        theta = i * angle_rad
        x = r * math.cos(theta)
        y = r * math.sin(theta)
        # Smaller dots toward center for depth.
        scale = 0.5 + 0.5 * (i / max(1, n_points - 1))
        prims.append(Dot(cx=x, cy=y, r=dot_size * 0.005 * scale))
    return prims


def flower_of_life(
    rings: int,
    stroke: float,
    circle_radius: float,
) -> list[Primitive]:
    """Overlapping circles on a hex grid — classical sacred geometry shape."""
    prims: list[Primitive] = []
    r = circle_radius * 0.01
    centers: set[tuple[float, float]] = {(0.0, 0.0)}
    # Walk a hex ring at each distance step.
    for ring in range(1, rings + 1):
        # Start at the "east" vertex of this ring.
        for side in range(6):
            base_angle = math.pi / 3 * side
            next_angle = math.pi / 3 * (side + 2)
            for j in range(ring):
                x = (ring * math.cos(base_angle)
                     + j * math.cos(next_angle))
                y = (ring * math.sin(base_angle)
                     + j * math.sin(next_angle))
                centers.add((round(x, 6), round(y, 6)))
    for cx, cy in centers:
        prims.append(Circle(cx=cx * r * math.sqrt(3),
                            cy=cy * r * math.sqrt(3),
                            r=r, width=stroke))
    return prims


def lissajous(
    a: float,
    b: float,
    delta_deg: float,
    samples: int,
    line_width: float,
) -> list[Primitive]:
    """Parametric x = sin(a t + δ), y = sin(b t). Integer ratios produce
    closed curves; near-integer ratios slowly precess into knot-like shapes."""
    delta = math.radians(delta_deg)
    t = np.linspace(0, 2 * math.pi, samples)
    x = np.sin(a * t + delta)
    y = np.sin(b * t)
    pts = np.column_stack([x, y])
    return [Stroke(points=pts, width=line_width, closed=False)]


def mandala(
    n_fold: int,
    petals: int,
    inner_r: float,
    outer_r: float,
    line_width: float,
) -> list[Primitive]:
    """N-fold radial pattern built from a small "ray" repeated and rotated.
    Each petal is two arcs (the petal outline) plus a central line."""
    prims: list[Primitive] = []
    # The ray itself, in design coords, pointing along +x.
    ray_count = max(2, petals)
    arc_samples = 64
    for i in range(n_fold):
        theta = 2 * math.pi * i / n_fold
        ct, st = math.cos(theta), math.sin(theta)
        # Inner-to-outer radial line.
        line_pts = np.array([
            [inner_r * ct, inner_r * st],
            [outer_r * ct, outer_r * st],
        ])
        prims.append(Stroke(points=line_pts, width=line_width))
        # Petal arcs: two arcs joined at a tip.
        for k in range(ray_count):
            frac = (k + 1) / (ray_count + 1)
            r = inner_r + frac * (outer_r - inner_r)
            # Arc spanning ±(petal half-angle) at radius r.
            half = (math.pi / n_fold) * 0.6
            s = np.linspace(-half, half, arc_samples)
            x = r * np.cos(theta + s)
            y = r * np.sin(theta + s)
            prims.append(Stroke(points=np.column_stack([x, y]),
                                width=line_width))
    return prims


def truchet(
    grid_n: int,
    seed: int,
    stroke: float,
    fill_density: float,
) -> list[Primitive]:
    """Random quarter-arc tiles. fill_density picks between two tile
    orientations — at 0.5 the layout is maximally random, at 0 or 1 it
    becomes a regular weave."""
    prims: list[Primitive] = []
    rng = np.random.default_rng(seed)
    cell = 2.0 / grid_n  # cells in [-1, 1] design space
    half = cell / 2
    arc_samples = 24
    for i in range(grid_n):
        for j in range(grid_n):
            x0 = -1 + i * cell + half
            y0 = -1 + j * cell + half
            choose = rng.random() < fill_density
            # Two quarter-circles in opposite corners.
            if choose:
                corners = [(-half, -half), (half, half)]
            else:
                corners = [(half, -half), (-half, half)]
            for cx, cy in corners:
                # Arc centered at corner, radius = half.
                # Angle range depends on which corner.
                if cx < 0 and cy < 0:
                    a0, a1 = 0, math.pi / 2
                elif cx > 0 and cy < 0:
                    a0, a1 = math.pi / 2, math.pi
                elif cx > 0 and cy > 0:
                    a0, a1 = math.pi, 3 * math.pi / 2
                else:
                    a0, a1 = 3 * math.pi / 2, 2 * math.pi
                s = np.linspace(a0, a1, arc_samples)
                x = (x0 + cx) + half * np.cos(s)
                y = (y0 + cy) + half * np.sin(s)
                prims.append(Stroke(points=np.column_stack([x, y]),
                                    width=stroke))
    return prims


def hypotrochoid(
    R: float,
    r: float,
    d: float,
    samples: int,
    revolutions: float,
    line_width: float,
) -> list[Primitive]:
    """Spirograph curve — a point at distance d from the center of a small
    circle (radius r) rolling inside a large circle (radius R)."""
    if r <= 0:
        return []
    t = np.linspace(0, 2 * math.pi * revolutions, samples)
    x = (R - r) * np.cos(t) + d * np.cos(((R - r) / r) * t)
    y = (R - r) * np.sin(t) - d * np.sin(((R - r) / r) * t)
    # Normalize to fit within design [-1, 1] roughly.
    m = max(np.max(np.abs(x)), np.max(np.abs(y)), 1e-6)
    x /= m
    y /= m
    return [Stroke(points=np.column_stack([x, y]), width=line_width)]


def sierpinski_triangle(
    depth: int,
    line_width: float,
) -> list[Primitive]:
    """Recursive triangle subdivision."""
    prims: list[Primitive] = []
    # Outer triangle vertices.
    h = math.sqrt(3) / 2
    v0 = np.array([0.0, -h * 0.7])
    v1 = np.array([-0.7, h * 0.5])
    v2 = np.array([0.7, h * 0.5])

    def recurse(a, b, c, level):
        if level == 0:
            tri = np.array([a, b, c, a])
            prims.append(Stroke(points=tri, width=line_width, closed=False))
            return
        ab = (a + b) / 2
        bc = (b + c) / 2
        ca = (c + a) / 2
        recurse(a, ab, ca, level - 1)
        recurse(ab, b, bc, level - 1)
        recurse(ca, bc, c, level - 1)

    recurse(v0, v1, v2, depth)
    return prims


# ---------------------------------------------------------------------------
# Convenience: a single dispatch table the UI can iterate over.
# ---------------------------------------------------------------------------

# Each entry: name -> (generator, default_params dict). The Streamlit UI
# binds sliders to params and calls the generator.
PATTERNS: dict[str, dict] = {
    "Phyllotaxis": {
        "fn": phyllotaxis,
        "defaults": {
            "n_points": (50, 2000, 600, 10),
            "angle_deg": (130.0, 140.0, 137.508, 0.01),
            "spread": (0.5, 3.0, 1.0, 0.01),
            "dot_size": (0.5, 10.0, 2.5, 0.1),
        },
    },
    "Flower of Life": {
        "fn": flower_of_life,
        "defaults": {
            "rings": (1, 6, 3, 1),
            "stroke": (1.0, 10.0, 3.0, 0.1),
            "circle_radius": (15.0, 60.0, 30.0, 0.5),
        },
    },
    "Lissajous": {
        "fn": lissajous,
        "defaults": {
            "a": (1.0, 12.0, 5.0, 0.1),
            "b": (1.0, 12.0, 4.0, 0.1),
            "delta_deg": (0.0, 360.0, 90.0, 1.0),
            "samples": (500, 5000, 2000, 100),
            "line_width": (1.0, 10.0, 3.0, 0.1),
        },
    },
    "Mandala": {
        "fn": mandala,
        "defaults": {
            "n_fold": (3, 24, 8, 1),
            "petals": (2, 12, 5, 1),
            "inner_r": (0.0, 0.6, 0.1, 0.01),
            "outer_r": (0.3, 1.0, 0.9, 0.01),
            "line_width": (1.0, 10.0, 3.0, 0.1),
        },
    },
    "Truchet": {
        "fn": truchet,
        "defaults": {
            "grid_n": (4, 24, 10, 1),
            "seed": (0, 9999, 42, 1),
            "stroke": (1.0, 10.0, 3.0, 0.1),
            "fill_density": (0.0, 1.0, 0.5, 0.01),
        },
    },
    "Hypotrochoid": {
        "fn": hypotrochoid,
        "defaults": {
            "R": (3.0, 12.0, 7.0, 0.1),
            "r": (1.0, 6.0, 3.0, 0.1),
            "d": (1.0, 8.0, 4.0, 0.1),
            "samples": (1000, 10000, 5000, 100),
            "revolutions": (1.0, 30.0, 10.0, 0.5),
            "line_width": (1.0, 10.0, 2.0, 0.1),
        },
    },
    "Sierpinski Triangle": {
        "fn": sierpinski_triangle,
        "defaults": {
            "depth": (1, 7, 5, 1),
            "line_width": (1.0, 10.0, 2.0, 0.1),
        },
    },
}
