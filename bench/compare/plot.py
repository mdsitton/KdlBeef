#!/usr/bin/env python3
"""Draws docs/benchmark.svg (chart) and docs/benchmark-table.svg (full results table) from results.md
(the Markdown tables run.sh prints), and docs/benchmark-typed.svg (typed serialization) from
typed-results.md (typed.sh).

    ./run.sh > results.md && ./typed.sh > typed-results.md && ./plot.py

(results.md and typed-results.md also carry hand-written notes above the tables; only the table rows
are read.) Plain SVG with its own light/dark colors (prefers-color-scheme), so it renders crisply on
GitHub in either theme. No dependencies. Adapted from TomlBeef's bench/compare/plot.py.
"""
import math
import os
import re
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results.md")
TYPED_RESULTS = os.path.join(HERE, "typed-results.md")
DOCS = os.path.join(HERE, "..", "..", "docs")
OUT = os.path.join(DOCS, "benchmark.svg")
TABLE_OUT = os.path.join(DOCS, "benchmark-table.svg")
TYPED_OUT = os.path.join(DOCS, "benchmark-typed.svg")

# Event parsers (no document) are compared with each other, against KdlBeef's event pass
EVENTS = {"KdlBeef events", "ckdl", "zig-kdl"}
LANGUAGE = {
    "KdlBeef": "Beef", "KdlBeef events": "Beef", "ckdl": "C", "kdlpp": "C++", "kdl-rs": "Rust",
    "gokdl2": "Go", "kdly": "Go", "kdl4j": "Java", "@bgotink/kdl": "JS", "kdljs": "JS",
    "KdlSharp": "C#", "ckdl (Python)": "Python", "kdl-py": "Python", "zig-kdl": "Zig",
    "dasel": "Go", "knus": "Rust",
}
DISPLAY = {"KdlBeef events": "KdlBeef (events)"}
REPO = {
    "KdlBeef": "mdsitton/KdlBeef", "KdlBeef events": "mdsitton/KdlBeef", "ckdl": "tjol/ckdl",
    "kdlpp": "tjol/ckdl", "kdl-rs": "kdl-org/kdl-rs", "gokdl2": "njreid/gokdl2", "kdly": "shimeoki/kdly",
    "kdl4j": "kdl-org/kdl4j", "@bgotink/kdl": "bgotink/kdl", "kdljs": "kdl-org/kdljs",
    "KdlSharp": "AndreyAkinshin/KdlSharp", "ckdl (Python)": "tjol/ckdl", "kdl-py": "tabatkins/kdlpy",
    "zig-kdl": "desttinghim/zig-kdl", "dasel": "TomWright/dasel", "knus": "TheLostLambda/knus",
}
# Why a library fails some of the (valid) inputs, for its footnote
FAIL_REASON = {
    "gokdl2": "its forced-KDL-2 streaming parse hits a buffer-refill bug",
    "zig-kdl": "parse errors or a wrong node count",
    "dasel": "rejects the identifier -->",
}
# Why a library times out, for its footnote
SLOW_REASON = {
    "dasel": "quadratic in #true/#false",
}
# Anything else a reader must know about a library's numbers
NOTE = {
    "knus": "reads only KDL v1, so it parses v1 translations of the inputs (ckdl-cat -1)",
}
# The per-cell time limit run.sh used (DNF cells count at input size / LIMIT)
LIMIT = float(os.environ.get("LIMIT", "60"))
INPUTS = os.path.join(HERE, "inputs")
INPUT_LABELS = {"ui": "UI markup", "config": "config", "strings": "strings", "numbers": "numbers",
                "html-standard": "HTML standard", "html-standard-compact": "HTML standard (compact)"}
INPUT_HEAD = {"ui": ("UI", "markup"), "config": ("config", ""), "strings": ("strings", ""),
              "numbers": ("numbers", ""), "html-standard": ("HTML", "standard"),
              "html-standard-compact": ("HTML std.", "compact")}

W = 920
TABLE_W = 1124  # the results table needs more room: six parse columns and six write columns
FONT = "system-ui, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"


def split(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def read_results():
    """Returns (libraries, parse, write, parse timeouts, write timeouts): parse[input][library] and
    write[input][library] are MB/s or None (FAIL or DNF); timeouts[(input, library)] is the speed
    bound for a DNF cell, input size / LIMIT. A library with no writer (n/a) has no key in the rows."""
    sections, current = {}, None
    for line in open(RESULTS):
        if line.startswith("### "):
            current = line[4:].split(" ")[0]
            sections[current] = []
        elif current and line.startswith("|") and not line.startswith("|---"):
            sections[current].append(split(line))
    libraries = sections["Parsing"][0][1:]

    def table(rows):
        out, timeouts = {}, {}
        for cells in rows[1:]:
            name = cells[0]
            out[name] = {}
            for p, v in zip(libraries, cells[1:]):
                if v == "n/a":
                    continue
                out[name][p] = float(v) if re.match(r"^[0-9.]+$", v) else None
                if v == "DNF":
                    timeouts[(name, p)] = os.path.getsize(os.path.join(INPUTS, name + ".kdl")) / 1048576.0 / LIMIT
        return out, timeouts

    parse, parse_timeouts = table(sections["Parsing"])
    write, write_timeouts = table(sections["Writing"])
    return libraries, parse, write, parse_timeouts, write_timeouts


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, cls, anchor="start"):
    return f'<text x="{x:.1f}" y="{y:.1f}" class="{cls}" text-anchor="{anchor}">{esc(s)}</text>'


def relative_speeds(libraries, table, timeouts, base_of):
    """Each library's speed relative to its baseline (base_of(library)): the geometric mean over the
    inputs it handled of its MB/s divided by the baseline's. A timed-out input counts at its speed
    bound, which favors that library; failed inputs are left out. Returns {library: (ratio, inputs)}."""
    speeds = {}
    for p in libraries:
        ratios = []
        for name, row in table.items():
            v = row.get(p) if row.get(p) is not None else timeouts.get((name, p))
            if v:
                ratios.append(v / row[base_of(p)])
        if ratios:
            speeds[p] = (math.exp(sum(math.log(r) for r in ratios) / len(ratios)), len(ratios))
    return speeds


def listing(items):
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1]


def caveat(p, table, timeouts, section=""):
    """Footnote text for a library that failed or timed out on some inputs, else None."""
    failed = [INPUT_LABELS.get(i, i) for i, row in table.items() if p in row and row[p] is None and (i, p) not in timeouts]
    slow = [INPUT_LABELS.get(i, i) for i, row in table.items() if (i, p) in timeouts]
    parts = []
    if failed:
        reason = FAIL_REASON.get(p, "rejected as invalid")
        passed = [INPUT_LABELS.get(i, i) for i, row in table.items() if row.get(p)]
        what = "all but " + listing(passed) if len(failed) > len(passed) else listing(failed)
        parts.append(f"failed {what} ({reason}; left out of its average)")
    if slow:
        why = f"{SLOW_REASON[p]}; " if p in SLOW_REASON else ""
        parts.append(f"did not finish {listing(slow)} within {LIMIT:.0f} s ({why}counted at that bound)")
    if p in NOTE:
        parts.append(NOTE[p])
    return f"{DISPLAY.get(p, p)}{section} " + "; ".join(parts) + "." if parts else None


def relative_panel(title, subtitle, groups, table, timeouts, top, footnotes, section=""):
    """Horizontal bars: average speed relative to a baseline, one block per (heading, members, baseline)
    group, fastest first. Libraries that failed inputs get a footnote in footnotes (a dict keyed by the
    plain caveat, the shown text with section after the library's name) unless noted already."""
    out = []
    name_x, bar_x, bar_w = 90, 360, 300
    row_h, bar_h = 25, 16
    y = top
    out.append(text(40, y, title, "title"))
    y += 22
    out.append(text(40, y, subtitle, "subtitle"))
    y += 18
    for heading, members, base in groups:
        speeds = relative_speeds(members, table, timeouts, lambda p: base)
        peak = max(1.0, max(r for r, _ in speeds.values()))
        y += 22
        out.append(text(40, y, heading.upper(), "group"))
        y += 8
        for p in sorted(speeds, key=lambda p: -speeds[p][0]):
            ratio, _ = speeds[p]
            cy = y + row_h / 2
            ours = p.startswith("KdlBeef")
            name = DISPLAY.get(p, p)
            note_text = caveat(p, table, timeouts)
            if note_text:
                name += "*"
                footnotes.setdefault(note_text, "* " + caveat(p, table, timeouts, section))
            out.append(text(40, cy + 5, LANGUAGE[p], "lang"))
            out.append(f'<text x="{name_x}" y="{cy + 5:.1f}"><tspan class="{"label ours" if ours else "label"}">{esc(name)}</tspan>'
                       f'<tspan class="repo" dx="8">{esc(REPO[p])}</tspan></text>')
            w = max(2.0, bar_w * ratio / peak)
            out.append(f'<rect x="{bar_x}" y="{cy - bar_h / 2:.1f}" width="{w:.1f}" height="{bar_h}" rx="3" class="{"bar-ours" if ours else "bar"}"/>')
            shown = f"{ratio:.2f}×" if ratio >= 0.1 else f"{ratio:.3f}×"
            if ours:
                note = "baseline"
            elif ratio > 1:
                note = f"{ratio:.1f}× faster than {DISPLAY.get(base, base)}"
            else:
                note = f"{DISPLAY.get(base, base)} {1 / ratio:.0f}× faster" if 1 / ratio >= 10 \
                    else f"{DISPLAY.get(base, base)} {1 / ratio:.1f}× faster"
            out.append(f'<text x="{bar_x + w + 8:.1f}" y="{cy + 5:.1f}" class="small">'
                       f'<tspan class="{"value ours" if ours else "value"}">{shown}</tspan>'
                       f'<tspan class="note-plain" dx="8">{esc(note)}</tspan></text>')
            y += row_h
    return out, y


def head_to_head_panel(parse, write, top):
    """Per input: KdlBeef against the fastest other library, as a pair of labeled MB/s bars, once for
    reading into a document and once for writing it. Each input's bars are scaled to its own fastest."""
    out = []
    label_x = 200
    columns = ((220, "READ INTO A DOCUMENT", parse), (575, "WRITE THE DOCUMENT", write))
    bar_w, bar_h, gap, row_h = 180, 13, 4, 46
    y = top
    out.append(text(40, y, "KdlBeef against the fastest alternative, per input", "title"))
    y += 22
    out.append(text(40, y, "MB/s · for each input, the fastest other library that builds a document from it "
                    "(or writes one) · bars scaled per input", "subtitle"))
    y += 34
    for x, heading, _ in columns:
        out.append(text(x, y, heading, "group"))
    y += 12
    for name in parse:
        out.append(f'<line x1="40" y1="{y:.1f}" x2="{W - 40}" y2="{y:.1f}" class="rule"/>')
        mid = y + row_h / 2
        out.append(text(label_x, mid + 5, INPUT_LABELS.get(name, name), "label", "end"))
        for x, _, table in columns:
            results = table[name]
            rivals = {p: v for p, v in results.items() if p not in EVENTS and not p.startswith("KdlBeef") and v}
            rival = max(rivals, key=rivals.get)
            pair = (("KdlBeef", results["KdlBeef"], True), (rival, rivals[rival], False))
            peak = max(v for _, v, _ in pair)
            by = mid - bar_h - gap / 2
            for lib, v, is_ours in pair:
                w = max(2.0, bar_w * v / peak)
                out.append(f'<rect x="{x}" y="{by:.1f}" width="{w:.1f}" height="{bar_h}" rx="2" class="{"bar-ours" if is_ours else "bar"}"/>')
                value = f"{v:.1f}" if v < 100 else f"{v:.0f}"
                out.append(f'<text x="{x + w + 7:.1f}" y="{by + 11:.1f}" class="small">'
                           f'<tspan class="{"value ours" if is_ours else "value"}">{value}</tspan>'
                           f'<tspan class="{"libname ours" if is_ours else "libname"}" dx="6">{esc(lib)}</tspan></text>')
                by += bar_h + gap
        y += row_h
    out.append(f'<line x1="40" y1="{y:.1f}" x2="{W - 40}" y2="{y:.1f}" class="rule"/>')
    return out, y + 8


def table_panel(libraries, parse, write, timeouts, write_timeouts, top):
    """The full results: one row per library (document builders, then event parsers, each ordered by
    average parse speed), one column per input for parsing and again for writing, MB/s per cell. The
    fastest cell of each column within its group is bold, and every cell is shaded by its speed
    relative to that best (log scale)."""
    out = []
    name_x, first_col, col_w, row_h = 40, 330, 60, 30
    width = TABLE_W
    inputs = list(parse.keys())
    write_x = first_col + len(inputs) * col_w + 16
    y = top
    out.append(text(40, y, "Full results", "title"))
    y += 22
    out.append(text(40, y, "MB/s, higher is better (parsing: of input; writing: of output) · bold = best in its group · "
                    "shading = relative to that best (log scale)", "subtitle"))
    y += 44
    for x0, heading in ((first_col, "PARSING (MB/s)"), (write_x, "WRITING (MB/s)")):
        out.append(text(x0 + len(inputs) * col_w / 2, y - 16, heading, "group", "middle"))
        for c, name in enumerate(inputs):
            top_line, bottom_line = INPUT_HEAD.get(name, (name, ""))
            cx = x0 + c * col_w + col_w / 2
            if bottom_line:
                out.append(text(cx, y, top_line, "colhead", "middle"))
                out.append(text(cx, y + 14, bottom_line, "colhead", "middle"))
            else:
                out.append(text(cx, y + 14, top_line, "colhead", "middle"))
    y += 20
    groups = (("BUILDS A DOCUMENT", [p for p in libraries if p not in EVENTS], "KdlBeef"),
              ("EVENTS ONLY, NO DOCUMENT", [p for p in libraries if p in EVENTS], "KdlBeef events"))
    for group, members, base in groups:
        speeds = relative_speeds(members, parse, timeouts, lambda p: base)
        y += 20
        out.append(text(name_x, y, group, "group"))
        y += 6
        best = {(x0, i): max((t[i].get(p) or 0 for p in members), default=0)
                for x0, t in ((first_col, parse), (write_x, write)) for i in inputs}
        for p in sorted(members, key=lambda p: -speeds.get(p, (0, 0))[0]):
            ours = p.startswith("KdlBeef")
            out.append(f'<line x1="40" y1="{y:.1f}" x2="{width - 40}" y2="{y:.1f}" class="rule"/>')
            if ours:
                out.append(f'<rect x="40" y="{y:.1f}" width="{width - 80}" height="{row_h}" class="row-ours"/>')
            mid = y + row_h / 2
            star = "*" if caveat(p, parse, timeouts) or caveat(p, write, write_timeouts) else ""
            out.append(f'<text x="{name_x}" y="{mid + 4.5:.1f}"><tspan class="lang">{esc(LANGUAGE[p])}</tspan>'
                       f'<tspan x="{name_x + 46}" class="{"label ours" if ours else "label"}">{esc(DISPLAY.get(p, p) + star)}</tspan>'
                       f'<tspan class="repo" dx="7">{esc(REPO[p])}</tspan></text>')
            for x0, table in ((first_col, parse), (write_x, write)):
                for c, name in enumerate(inputs):
                    x = x0 + c * col_w
                    if p not in table[name]:
                        out.append(text(x + col_w - 7, mid + 4, "—", "cell-missing", "end"))
                        continue
                    v = table[name][p]
                    if v is None:
                        label = "DNF" if (name, p) in (timeouts if table is parse else write_timeouts) else "FAIL"
                        out.append(text(x + col_w - 6, mid + 4, label, "cell-missing", "end"))
                        continue
                    # Shade: 1.0 at the column's best, fading over a 100× range
                    level = max(0.0, 1.0 + math.log10(v / best[(x0, name)]) / 2.0)
                    out.append(f'<rect x="{x + 2}" y="{y + 3:.1f}" width="{col_w - 4}" height="{row_h - 6}" rx="3" '
                               f'class="heat" fill-opacity="{0.06 + 0.34 * level:.2f}"/>')
                    cls = "cell" + (" best" if v == best[(x0, name)] else "") + (" ours" if ours else "")
                    out.append(text(x + col_w - 7, mid + 4.5, f"{v:.1f}" if v < 100 else f"{v:.0f}", cls, "end"))
            y += row_h
        out.append(f'<line x1="40" y1="{y:.1f}" x2="{width - 40}" y2="{y:.1f}" class="rule"/>')
    divider_x = write_x - 8
    out.insert(0, f'<line x1="{divider_x}" y1="{top + 58}" x2="{divider_x}" y2="{y}" class="rule"/>')
    y += 22
    out.append(text(40, y, f"Each value is the median of 3 processes · FAIL = parse error or wrong node count · DNF = did "
                    f"not finish within {LIMIT:.0f} s · — = no writer · * see the notes under the chart", "footnote"))
    return out, y + 8


def read_typed():
    """typed-results.md as rows of (library, language, read ms, write ms); a time that is not a number
    ("n/a", "FAIL", "DNF") stays text."""
    rows = [l for l in open(TYPED_RESULTS) if l.startswith("|") and not l.startswith("|---")]
    number = lambda v: float(v) if re.match(r"^[0-9.]+$", v) else v
    return [(c[0], c[1], number(c[3]), number(c[5])) for c in map(split, rows[1:])]


def typed_panel(top):
    """Typed serialization (typed-results.md, written by typed.sh): ms to read ui.kdl into native types
    and to write them back, one column each, fastest first, compared with KdlBeef. KdlBeef's read
    variants (with and without source positions) both appear; its write once."""
    rows = read_typed()
    out = []
    col_w, name_w, bar_w, row_h, bar_h = (W - 80) // 2, 200, 110, 20, 12
    y = top
    out.append(text(40, y, "Typed serialization: KDL to native types and back", "title"))
    y += 22
    out.append(text(40, y, "ui.kdl, 5 MB: 63,681 windows, containers and widgets · ms per operation, lower is better "
                    "· every library binds the same values", "subtitle"))
    y += 30
    bottom = y
    columns = (("READ · text → objects", 2, lambda lib: True),
               ("WRITE · objects → text", 3, lambda lib: not lib.startswith("KdlBeef (")))
    base_read = next(r[2] for r in rows if r[0] == "KdlBeef")
    base_write = next(r[3] for r in rows if r[0] == "KdlBeef")
    for c, (heading, index, show) in enumerate(columns):
        x0 = 40 + c * (col_w + 20)
        out.append(text(x0, y, heading, "group"))
        shown = [r for r in rows if show(r[0])]
        numbers = [r[index] for r in shown if isinstance(r[index], float)]
        scale = bar_w / max(numbers)
        base = base_read if index == 2 else base_write
        by = y + 14
        rank = lambda r: (0, r[index]) if isinstance(r[index], float) else (1, 0)
        for lib, language, *times in sorted(shown, key=rank):
            ms = times[index - 2]
            ours = lib.startswith("KdlBeef")
            out.append(f'<text x="{x0 + name_w - 8}" y="{by + 10:.1f}" class="small" text-anchor="end">'
                       f'<tspan class="{"libname ours" if ours else "libname"}">{esc(lib)}</tspan>'
                       f'<tspan class="lang" dx="5">{esc(language)}</tspan></text>')
            bar_x = x0 + name_w
            if not isinstance(ms, float):
                out.append(text(bar_x + 2, by + 10, ms, "cell-missing"))
            else:
                w = max(2.0, ms * scale)
                out.append(f'<rect x="{bar_x}" y="{by:.1f}" width="{w:.1f}" height="{bar_h}" rx="2" '
                           f'class="{"bar-ours" if ours else "bar"}"/>')
                compare = "" if lib == "KdlBeef" else (f"{ms / base:.1f}× slower" if ms > base * 1.05
                                                       else f"{base / ms:.1f}× faster" if ms < base / 1.05 else "≈")
                value = f"{ms:.1f}" if ms < 100 else f"{ms:.0f}"
                out.append(f'<text x="{bar_x + w + 6:.1f}" y="{by + 10:.1f}" class="small">'
                           f'<tspan class="{"value ours" if ours else "value"}">{value}</tspan>'
                           f'<tspan class="note-plain" dx="6">{compare}</tspan></text>')
            by += row_h
        bottom = max(bottom, by)
    y = bottom + 12
    notes = (
        "KdlBeef: KdlSerializer.Read records source positions for located errors; \"no positions\" reads the "
        "document without them.",
        "Mappings: KdlBeef [KdlObject] (compile time), kdl-rs serde derive, gokdl2 struct tags, KdlSharp attributes "
        "(reflection).",
        "Only KdlBeef keeps each container's mixed children in order and the (px) annotations; kdl-rs and gokdl2 "
        "group children",
        "by kind, and KdlSharp cannot map the document by itself (its harness walks the tree). See typed-results.md.",
    )
    for note in notes:
        out.append(text(40, y, note, "footnote"))
        y += 18
    return out, y


def style():
    return f"""
  <style>
    svg {{ font-family: {FONT}; }}
    .bg {{ fill: #ffffff; }}
    .title {{ font-size: 19px; font-weight: 650; fill: #1f2328; }}
    .subtitle, .footer, .axis {{ font-size: 12.5px; fill: #656d76; }}
    .group {{ font-size: 11px; font-weight: 650; letter-spacing: 0.08em; fill: #656d76; }}
    .label {{ font-size: 13.5px; fill: #1f2328; }}
    .lang {{ font-size: 11px; fill: #8c959f; }}
    .ours {{ font-weight: 700; }}
    .value {{ font-size: 12.5px; fill: #424a53; font-variant-numeric: tabular-nums; }}
    .value.ours {{ fill: #c2410c; }}
    .small {{ font-size: 12px; fill: #424a53; }}
    .note-plain {{ fill: #8c959f; }}
    .footnote {{ font-size: 12px; fill: #656d76; }}
    .repo {{ font-size: 11.5px; fill: #8c959f; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }}
    .bar {{ fill: #afb8c1; }}
    .bar-ours {{ fill: #ea580c; }}
    .rule {{ stroke: #d8dee4; stroke-width: 1; }}
    .libname {{ fill: #656d76; }}
    .libname.ours {{ fill: #c2410c; font-weight: 650; }}
    .colhead {{ font-size: 11px; font-weight: 600; fill: #424a53; }}
    .cell {{ font-size: 12px; fill: #424a53; font-variant-numeric: tabular-nums; }}
    .cell.best {{ font-weight: 700; fill: #1f2328; }}
    .cell.ours {{ fill: #c2410c; }}
    .cell-missing {{ font-size: 10px; fill: #8c959f; }}
    .heat {{ fill: #2da44e; }}
    .row-ours {{ fill: #ea580c; fill-opacity: 0.07; }}
    @media (prefers-color-scheme: dark) {{
      .bg {{ fill: #0d1117; }}
      .title, .label {{ fill: #e6edf3; }}
      .subtitle, .footer, .axis, .group {{ fill: #8d96a0; }}
      .lang, .note-plain {{ fill: #6e7681; }}
      .footnote {{ fill: #8d96a0; }}
      .repo {{ fill: #6e7681; }}
      .value, .small {{ fill: #c9d1d9; }}
      .value.ours {{ fill: #fb923c; }}
      .bar {{ fill: #3d444d; }}
      .bar-ours {{ fill: #f97316; }}
      .rule {{ stroke: #262c36; }}
      .libname {{ fill: #8d96a0; }}
      .libname.ours {{ fill: #fb923c; }}
      .colhead {{ fill: #c9d1d9; }}
      .cell {{ fill: #c9d1d9; }}
      .cell.best {{ fill: #f0f6fc; }}
      .cell.ours {{ fill: #fb923c; }}
      .cell-missing {{ fill: #6e7681; }}
      .heat {{ fill: #3fb950; }}
      .row-ours {{ fill: #f97316; fill-opacity: 0.10; }}
    }}
  </style>"""


def write_svg(path, width, height, body, label):
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" '
           f'aria-label="{esc(label)}">', style(),
           f'<rect class="bg" x="0" y="0" width="{width}" height="{height}" rx="10"/>']
    svg += body + ["</svg>"]
    with open(path, "w") as f:
        f.write("\n".join(svg) + "\n")
    print(f"wrote {os.path.relpath(path)}")


FOOTER = ("Linux x86-64, single thread · 1 s warm-up, then samples until 60% are within ±10% of their median · "
          "median of 3 processes · bench/compare")


def main():
    libraries, parse, write, timeouts, write_timeouts = read_results()
    footnotes = {}  # plain caveat -> the footnote shown, so failures common to both panels are noted once
    documents = [p for p in libraries if p not in EVENTS]
    panel1, y = relative_panel(
        "Parsing: average speed relative to KdlBeef",
        f"geometric mean over {len(parse)} inputs of each library's MB/s ÷ KdlBeef's · higher is better · KdlBeef = 1×",
        (("Builds a document", documents, "KdlBeef"),
         ("Events only, no document", [p for p in libraries if p in EVENTS], "KdlBeef events")),
        parse, timeouts, 44, footnotes)
    writers = [p for p in documents if any(p in row for row in write.values())]
    panel2, y = relative_panel(
        "Writing a parsed document: average speed relative to KdlBeef",
        "geometric mean of each library's MB/s of output ÷ KdlBeef's · libraries with a writer · higher is better",
        (("Writes a document", writers, "KdlBeef"),), write, write_timeouts, y + 56, footnotes, " (writing)")
    panel3, y = head_to_head_panel(parse, write, y + 56)
    body = panel1 + panel2 + panel3
    for note in footnotes.values():
        for i, line in enumerate(textwrap.wrap(note, 135)):
            y += 20 if i == 0 else 16
            body.append(text(40 if i == 0 else 50, y, line, "footnote"))
    height = y + 44
    body.append(text(40, height - 16, FOOTER, "footer"))
    write_svg(OUT, W, height, body, "KdlBeef parsing and writing throughput compared with other KDL libraries")

    body, y = table_panel(libraries, parse, write, timeouts, write_timeouts, 44)
    write_svg(TABLE_OUT, TABLE_W, y + 24, body, "Full KDL benchmark results: MB/s per library and input")

    if os.path.exists(TYPED_RESULTS):
        body, y = typed_panel(44)
        height = y + 26
        body.append(text(40, height - 16, FOOTER.replace("bench/compare", "typed.sh"), "footer"))
        write_svg(TYPED_OUT, W, height, body, "KdlBeef typed serialization compared with other KDL libraries")


if __name__ == "__main__":
    main()
