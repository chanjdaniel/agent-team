#!/usr/bin/env python3
"""A task's tickets as one self-contained HTML page of their dependency graph, for team-tickets --html.

Usage: python3 -I ticket_graph.py --task T<n> --title <text> --as-of <text> --digest <hex> --out <file>
  (the ticket list on stdin exactly as team-tickets --json prints it; writes the page to <file> and
  prints its width and height in CSS pixels, "<W> <H>", on stdout)

The page is one inline SVG, its size the page's (html, body { margin: 0 }), with no script, link,
image, font or other network reference, every ticket's text escaped. It draws:
  - a header: "T<n> <title>" in bold, the counts of tickets, phases, levels and the widest level,
    the serial total and the critical path, and "As of <as-of> UTC.", wrapped to the page;
  - a legend of the states' colours and the critical path's red border;
  - each phase, in ascending order, as a band headed "phase <n>", its rows its levels: a ticket's
    level is 0 with no blocker in its own phase, else one more than its same-phase blockers'
    highest, so a ticket blocked only by an earlier phase starts its phase; rows are labelled
    "level <k>", k counted from 1 down the whole page;
  - each ticket as a 280-pixel box of class "ticket" with its number in bold, its state, its slug
    (its "-" read as spaces) wrapped at 28 characters, and a waiting ticket's "waits for:" text in
    italic, every box of a row as tall as the row's tallest, filled by its state's colour;
  - one arrow per Blocked by: entry, an SVG path of class "edge" of M and L commands only, from a
    port on its blocker's bottom side to one on its ticket's top side (the ports spread evenly
    along each side, ordered by the x of the next item the edge reaches), running vertically
    through a 20-pixel slot of its own in each row it passes, so no edge crosses a box;
  - the critical path, each ticket weighing 1: per phase, a ticket's length is its weight plus
    its longest same-phase blocker's (ties to the lowest number), the phase's path ending at its
    longest ticket (ties to the lowest number), the task's path the phases' in order, their
    lengths summed; its boxes and edges red.
A row's items, its tickets by number then its slots by their edge's blocker and ticket, are
ordered by 4 rounds of a pass down the rows and a pass up, each row stably sorted by the mean
position of each item's neighbours in the row before (an item with none keeps its position), then
packed 28 pixels apart, each row centred on the widest, right of a 70-pixel label column.
Exit codes: 0 written, 1 input it cannot read (one line on stderr), 2 a malformed command line.
"""
import argparse
import html
import json
import math
import sys

BOX_W, PAD, FONT, LINE, BOX_CHARS = 280, 12, 15, 20, 28
TITLE_FONT, TITLE_LINE = 18, 24
SLOT_W, GAP_X, GAP_Y, MARGIN, LABEL_W, MIN_W = 20, 28, 56, 24, 70, 640
BAND_PAD, BAND_HEAD, BAND_GAP, LEGEND_H = 12, 28, 16, 24
CHAR_EM = 0.6
COLOURS = {"done": "#d1fae5", "running": "#dbeafe", "ready": "#fef9c3",
           "waiting": "#fde68a", "blocked": "#f3f4f6"}
BORDER, RED, GREY = "#9ca3af", "#dc2626", "#9ca3af"
ROUNDS = 4


class Unreadable(Exception):
    pass


def num(v):
    """A coordinate as the page writes it: whole when it is, else to one decimal."""
    r = round(v, 1)
    return str(int(r)) if r == int(r) else f"{r:.1f}"


def esc(text):
    return html.escape(text, quote=True)


def wrap(text, chars):
    """Text broken at spaces into lines of at most chars characters, a longer word split with a
    trailing "-", so nothing is cut."""
    lines, line = [], ""
    for word in text.split():
        while len(word) > chars:
            if line:
                lines.append(line)
                line = ""
            lines.append(word[:chars - 1] + "-")
            word = word[chars - 1:]
        if not word:
            continue
        if not line:
            line = word
        elif len(line) + 1 + len(word) <= chars:
            line += " " + word
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def plural(count, noun):
    return f"{count:g} {noun}" + ("" if count == 1 else "s")


def read_tickets(stream):
    try:
        tickets = json.load(stream)
    except ValueError as err:
        raise Unreadable(f"the ticket list is not JSON: {err}") from err
    if not isinstance(tickets, list):
        raise Unreadable("the ticket list is not a JSON list")
    by = {}
    for t in tickets:
        if not isinstance(t, dict):
            raise Unreadable("a ticket is not a JSON object")
        n = t.get("ticket")
        if not (isinstance(n, str) and len(n) == 2 and n.isdigit()) or n in by:
            raise Unreadable(f"a ticket's number is not a two-digit number of its own: {n!r}")
        if not isinstance(t.get("slug"), str) or t.get("state") not in COLOURS:
            raise Unreadable(f"ticket {n} has no slug or no known state")
        if not (isinstance(t.get("phase"), int) and t["phase"] >= 1):
            raise Unreadable(f"ticket {n}'s phase is not a whole number from 1")
        if not (isinstance(t.get("blocked_by"), list) and all(isinstance(b, str) for b in t["blocked_by"])):
            raise Unreadable(f"ticket {n}'s blocked_by is not a list of ticket numbers")
        if t.get("waits_for") is not None and not isinstance(t["waits_for"], str):
            raise Unreadable(f"ticket {n}'s waits_for is not text")
        by[n] = t
    for n, t in by.items():
        for b in t["blocked_by"]:
            if b not in by:
                raise Unreadable(f"ticket {n}'s blocker {b} is no ticket of the list")
            if by[b]["phase"] > t["phase"]:
                raise Unreadable(f"ticket {n}'s blocker {b} is in a later phase")
    return by


class Graph:
    """The layout: levels, rows, items, their order and coordinates."""

    def __init__(self, by):
        self.by = by
        self.ids = sorted(by)
        self.phases = sorted({t["phase"] for t in by.values()})
        self.levels()
        self.weights()
        self.critical_path()
        self.items_and_order()

    def same_phase_blockers(self, n):
        t = self.by[n]
        return [b for b in t["blocked_by"] if self.by[b]["phase"] == t["phase"]]

    def levels(self):
        level, visiting = {}, set()

        def lv(n):
            if n in level:
                return level[n]
            if n in visiting:
                raise Unreadable(f"a cycle of blockers through ticket {n}")
            visiting.add(n)
            same = self.same_phase_blockers(n)
            level[n] = 1 + max(lv(b) for b in same) if same else 0
            return level[n]

        for n in self.ids:
            lv(n)
        self.level = level
        self.row_of, self.phase_rows, offset = {}, {}, 0
        for p in self.phases:
            in_p = [n for n in self.ids if self.by[n]["phase"] == p]
            for n in in_p:
                self.row_of[n] = offset + level[n]
            depth = max(level[n] for n in in_p) + 1
            self.phase_rows[p] = list(range(offset, offset + depth))
            offset += depth
        self.rows = offset

    def weights(self):
        self.weight = {n: 1 for n in self.ids}
        self.unit = "ticket"

    def critical_path(self):
        self.crit, self.crit_edges, self.phase_paths = set(), set(), []
        for p in self.phases:
            in_p = sorted((n for n in self.ids if self.by[n]["phase"] == p), key=lambda n: (self.level[n], n))
            length, prev = {}, {}
            for n in in_p:
                same = self.same_phase_blockers(n)
                if same:
                    b = min(same, key=lambda b: (-length[b], b))
                    length[n], prev[n] = length[b] + self.weight[n], b
                else:
                    length[n], prev[n] = self.weight[n], None
            end = min(in_p, key=lambda n: (-length[n], n))
            chain, n = [], end
            while n is not None:
                chain.append(n)
                n = prev[n]
            chain.reverse()
            self.crit.update(chain)
            self.crit_edges.update(zip(chain, chain[1:]))
            self.phase_paths.append((p, length[end], chain))

    def items_and_order(self):
        by, row_of = self.by, self.row_of
        self.edges = sorted((b, n) for n in self.ids for b in by[n]["blocked_by"])
        self.blocks = {n: [m for m in self.ids if n in by[m]["blocked_by"]] for n in self.ids}
        items = {r: [] for r in range(self.rows)}
        for n in self.ids:
            items[row_of[n]].append(("t", n))
        for e in self.edges:
            for r in range(row_of[e[0]] + 1, row_of[e[1]]):
                items[r].append(("s", e, r))
        pos = {it: i for r in items for i, it in enumerate(items[r])}

        def neighbours(it, r, before):
            """The items of the row before (above on a pass down, below on a pass up) that it
            joins to."""
            if it[0] == "s":
                b, n = it[1]
                if before == "above":
                    return [("s", it[1], r - 1) if row_of[b] < r - 1 else ("t", b)]
                return [("s", it[1], r + 1) if row_of[n] > r + 1 else ("t", n)]
            n = it[1]
            if before == "above":
                return [("t", b) if row_of[b] == r - 1 else ("s", (b, n), r - 1) for b in by[n]["blocked_by"]]
            return [("t", m) if row_of[m] == r + 1 else ("s", (n, m), r + 1) for m in self.blocks[n]]

        def sort_row(r, before):
            def key(it):
                near = [pos[x] for x in neighbours(it, r, before)]
                return sum(near) / len(near) if near else pos[it]
            items[r].sort(key=key)
            for i, it in enumerate(items[r]):
                pos[it] = i

        for _ in range(ROUNDS):
            for r in range(1, self.rows):
                sort_row(r, "above")
            for r in range(self.rows - 2, -1, -1):
                sort_row(r, "below")
        self.items = items


def box_lines(t):
    """A box's lines below its first: the slug, then a waiting ticket's condition, each with its
    class."""
    lines = [("slug", line) for line in wrap(t["slug"].replace("-", " "), BOX_CHARS)]
    if t["state"] == "waiting" and t.get("waits_for"):
        lines += [("waits", line) for line in wrap("waits for: " + t["waits_for"], BOX_CHARS)]
    return lines


def header_text(g, task):
    k, p, r = len(g.ids), len(g.phases), g.rows
    widest = max(sum(1 for it in g.items[row] if it[0] == "t") for row in range(r))
    serial = sum(g.weight.values())
    total = sum(length for _, length, _ in g.phase_paths)
    if len(g.phase_paths) == 1:
        path = " → ".join(g.phase_paths[0][2])
    else:
        path = "; ".join(f"phase {ph} {' → '.join(chain)} ({length:g})" for ph, length, chain in g.phase_paths)
    return [
        f"{plural(k, 'ticket')} in {plural(p, 'phase')}, {plural(r, 'level')}; widest level {plural(widest, 'ticket')}.",
        f"Serial {plural(serial, g.unit)}; critical path {plural(total, g.unit)}: {path}.",
    ]


def render(by, task, title, as_of, digest):
    g = Graph(by) if by else None
    svg = []

    # Widths: each row's items packed, the page as wide as the widest row needs, at least MIN_W.
    if g:
        row_w = {r: sum(BOX_W if it[0] == "t" else SLOT_W for it in g.items[r]) + GAP_X * (len(g.items[r]) - 1)
                 for r in range(g.rows)}
        inner_w = max(row_w.values())
        W = max(MIN_W, 2 * MARGIN + 2 * BAND_PAD + LABEL_W + inner_w)
    else:
        W = MIN_W

    # The header.
    first = f"{task} {title}".strip() if title else task
    title_lines = wrap(first, math.floor((W - 2 * MARGIN) / (TITLE_FONT * CHAR_EM)))
    chars = math.floor((W - 2 * MARGIN) / (FONT * CHAR_EM))
    rest = header_text(g, task) if g else [f"No tickets in {task}'s open worktrees."]
    rest.append(f"As of {as_of} UTC.")
    y = MARGIN
    for line in title_lines:
        svg.append(f'<text class="header" x="{MARGIN}" y="{y + TITLE_FONT}" font-size="{TITLE_FONT}" '
                   f'font-weight="700">{esc(line)}</text>')
        y += TITLE_LINE
    for text in rest:
        for line in wrap(text, chars):
            svg.append(f'<text class="header" x="{MARGIN}" y="{y + FONT}">{esc(line)}</text>')
            y += LINE

    if g:
        y = draw_graph(g, svg, W, y, row_w, inner_w)
    H = y + MARGIN

    markers = "".join(
        f'<marker id="{name}" viewBox="0 0 10 10" refX="10" refY="5" markerUnits="userSpaceOnUse" '
        f'markerWidth="10" markerHeight="10" orient="auto"><path d="M0,0L10,5L0,10z" fill="{colour}"/></marker>'
        for name, colour in (("arrow-grey", GREY), ("arrow-red", RED)))
    page = (
        '<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
        f'<meta name="team-tickets-digest" content="{esc(digest)}">'
        f'<title>{esc(task)} tickets</title>'
        '<style>html, body { margin: 0; background: #fff } svg { display: block }</style></head><body>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
        f'font-family="ui-sans-serif, system-ui, sans-serif" font-size="{FONT}" fill="#111827">'
        f'<defs>{markers}</defs>\n' + "\n".join(svg) + "\n</svg>\n</body></html>\n")
    return page, W, H


def draw_graph(g, svg, W, y, row_w, inner_w):
    """Draw the legend, the bands, the boxes and the edges below the header at y; return the
    graph's bottom."""
    # The legend.
    y += 12
    x = MARGIN
    for state, colour in COLOURS.items():
        w = len(state) * FONT * CHAR_EM + 20
        svg.append(f'<g class="legend"><rect x="{num(x)}" y="{y}" width="{num(w)}" height="{LEGEND_H}" rx="4" '
                   f'fill="{colour}" stroke="{BORDER}"/><text x="{num(x + 10)}" y="{y + 17}">{state}</text></g>')
        x += w + 8
    w = len("critical path") * FONT * CHAR_EM + 20
    svg.append(f'<g class="legend"><rect x="{num(x)}" y="{y}" width="{num(w)}" height="{LEGEND_H}" rx="4" '
               f'fill="#fff" stroke="{RED}" stroke-width="2.5"/><text x="{num(x + 10)}" y="{y + 17}">critical path</text></g>')
    y += LEGEND_H + 20

    # Rows: each box as tall as its row's tallest, the bands around their phases' rows.
    lines = {n: box_lines(g.by[n]) for n in g.ids}
    row_h = [max(2 * PAD + LINE * (1 + len(lines[it[1]])) for it in g.items[r] if it[0] == "t")
             for r in range(g.rows)]
    row_y = {}
    area_x = MARGIN + BAND_PAD + LABEL_W
    area_w = W - area_x - MARGIN - BAND_PAD
    bands = []
    for p in g.phases:
        top = y
        y += BAND_HEAD + 16
        rows = g.phase_rows[p]
        for i, r in enumerate(rows):
            row_y[r] = y
            y += row_h[r] + (GAP_Y if i < len(rows) - 1 else 0)
        y += 16
        bands.append((p, top, y))
        y += BAND_GAP
    bottom = y - BAND_GAP
    # Each band: its head (rounded on top only) under its outline.
    band_w = W - 2 * MARGIN
    for p, top, end in bands:
        svg.append(f'<g class="phase"><rect x="{MARGIN}" y="{top}" width="{band_w}" height="{BAND_HEAD}" rx="8" fill="#eef2ff"/>'
                   f'<rect x="{MARGIN}" y="{top + BAND_HEAD - 8}" width="{band_w}" height="8" fill="#eef2ff"/>'
                   f'<rect x="{MARGIN}" y="{top}" width="{band_w}" height="{end - top}" rx="8" fill="none" stroke="#c7d2fe"/>'
                   f'<text x="{MARGIN + BAND_PAD}" y="{top + 19}" font-weight="700">phase {p}</text></g>')
    xy = {}
    for r in range(g.rows):
        svg.append(f'<text class="level" x="{MARGIN + BAND_PAD}" y="{row_y[r] + PAD + FONT}" fill="#6b7280">level {r + 1}</text>')
        x = area_x + (area_w - row_w[r]) / 2
        for it in g.items[r]:
            w = BOX_W if it[0] == "t" else SLOT_W
            xy[it] = (x, row_y[r], w, row_h[r])
            x += w + GAP_X

    # The boxes.
    for n in g.ids:
        t = g.by[n]
        x, y0, w, h = xy[("t", n)]
        red = n in g.crit
        svg.append(f'<g class="box"><rect class="ticket" data-ticket="{n}" x="{num(x)}" y="{y0}" width="{w}" height="{h}" '
                   f'rx="6" fill="{COLOURS[t["state"]]}" stroke="{RED if red else BORDER}" stroke-width="{2.5 if red else 1}"/>')
        base = y0 + PAD + FONT
        svg.append(f'<text class="head" x="{num(x + PAD)}" y="{base}"><tspan font-weight="700">{n}</tspan> {t["state"]}</text>')
        for i, (kind, line) in enumerate(lines[n], 1):
            italic = ' font-style="italic"' if kind == "waits" else ""
            svg.append(f'<text class="{kind}" x="{num(x + PAD)}" y="{base + i * LINE}"{italic}>{esc(line)}</text>')
        svg.append("</g>")

    # The edges, each leaving its blocker's bottom and entering its ticket's top at ports ordered
    # by the x of the item the edge reaches next, grey ones first.
    def centre(it):
        x, _, w, _ = xy[it]
        return x + w / 2

    def next_item(e, r):
        """The item of edge e in row r: its slot there, or the ticket at that end."""
        b, n = e
        if r == g.row_of[b]:
            return ("t", b)
        if r == g.row_of[n]:
            return ("t", n)
        return ("s", e, r)

    out_e = {n: sorted((e for e in g.edges if e[0] == n), key=lambda e: (centre(next_item(e, g.row_of[n] + 1)), e))
             for n in g.ids}
    in_e = {n: sorted((e for e in g.edges if e[1] == n), key=lambda e: (centre(next_item(e, g.row_of[n] - 1)), e))
            for n in g.ids}
    paths = []
    for e in g.edges:
        b, n = e
        bx, byy, bw, bh = xy[("t", b)]
        k = out_e[b].index(e)
        pts = [(bx + bw * (k + 1) / (len(out_e[b]) + 1), byy + bh)]
        for r in range(g.row_of[b] + 1, g.row_of[n]):
            sx, sy, sw, sh = xy[("s", e, r)]
            pts += [(sx + sw / 2, sy), (sx + sw / 2, sy + sh)]
        tx, ty, tw, _ = xy[("t", n)]
        k = in_e[n].index(e)
        pts.append((tx + tw * (k + 1) / (len(in_e[n]) + 1), ty))
        red = e in g.crit_edges
        d = "M" + " L".join(f"{num(px)},{num(py)}" for px, py in pts)
        paths.append((red, f'<path class="edge" data-edge="{b}-{n}" d="{d}" fill="none" stroke="{RED if red else GREY}" '
                           f'stroke-width="{2.5 if red else 1.4}" stroke-linejoin="round" '
                           f'marker-end="url(#{"arrow-red" if red else "arrow-grey"})"/>'))
    svg += [p for red, p in paths if not red] + [p for red, p in paths if red]
    return bottom


def main():
    parser = argparse.ArgumentParser(prog="ticket_graph.py", description="A task's tickets as an HTML page.")
    for name in ("--task", "--title", "--as-of", "--digest", "--out"):
        parser.add_argument(name, required=True)
    args = parser.parse_args()
    try:
        by = read_tickets(sys.stdin)
        page, W, H = render(by, args.task, args.title, args.as_of, args.digest)
    except Unreadable as err:
        print(f"ticket_graph.py: {err}", file=sys.stderr)
        return 1
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(page)
    print(f"{W} {H}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
