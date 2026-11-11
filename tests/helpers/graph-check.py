"""Each edge segment of a team-tickets --html page that passes through a ticket box's interior.

Usage: python3 -I graph-check.py <page.html>
Reads the page's SVG: its boxes, the rect elements of class "ticket", and its edges, the path
elements of class "edge", whose d holds M and L commands only. For each straight segment of an
edge that overlaps a box shrunk by 1 pixel on every side (Liang-Barsky clipping), so a segment
that only starts or ends on a box's border is none, it prints
"segment <x1>,<y1> -> <x2>,<y2> crosses box <ticket> at <x>,<y>".
Prints "<edges> edges, <boxes> boxes" last; exits 1 when any segment crosses a box, or when the
page has no SVG or an edge's d holds another command.
"""

import re
import sys
import xml.etree.ElementTree as ET

NS = "{http://www.w3.org/2000/svg}"


def crosses(x1, y1, x2, y2, box):
    bx, by, bw, bh = box
    lo, hi = 0.0, 1.0
    dx, dy = x2 - x1, y2 - y1
    for p, q in ((-dx, x1 - (bx + 1)), (dx, (bx + bw - 1) - x1), (-dy, y1 - (by + 1)), (dy, (by + bh - 1) - y1)):
        if p == 0:
            if q < 0:
                return False
        elif p < 0:
            lo = max(lo, q / p)
        else:
            hi = min(hi, q / p)
    return lo < hi


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        page = f.read()
    start, end = page.find("<svg"), page.find("</svg>")
    if start < 0 or end < 0:
        print("the page has no SVG")
        return 1
    svg = ET.fromstring(page[start:end + len("</svg>")])
    boxes = [(r.get("data-ticket"), tuple(float(r.get(k)) for k in ("x", "y", "width", "height")))
             for r in svg.iter(NS + "rect") if r.get("class") == "ticket"]
    edges = [p for p in svg.iter(NS + "path") if p.get("class") == "edge"]
    bad = 0
    for edge in edges:
        d = edge.get("d")
        if not re.fullmatch(r"M[-0-9.]+,[-0-9.]+( L[-0-9.]+,[-0-9.]+)+", d):
            print(f"an edge's d is not M and L commands only: {d}")
            return 1
        points = [tuple(map(float, xy.split(","))) for xy in re.findall(r"[-0-9.]+,[-0-9.]+", d)]
        for (x1, y1), (x2, y2) in zip(points, points[1:]):
            for ticket, box in boxes:
                if crosses(x1, y1, x2, y2, box):
                    bad += 1
                    print(f"segment {x1:g},{y1:g} -> {x2:g},{y2:g} crosses box {ticket} at {box[0]:g},{box[1]:g}")
    print(f"{len(edges)} edges, {len(boxes)} boxes")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
