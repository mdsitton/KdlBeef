#!/usr/bin/env python3
"""Writes the comparison benchmark inputs into inputs/ (git-ignored). Deterministic (fixed seed).

Real-world inputs come from the official KDL repository's benchmark documents (the HTML standard as
KDL, tests/kdl-spec/tests/benchmarks, fetched by ../../tests/fetch-spec.sh). Generated inputs cover
the shapes a UI framework and configuration files produce. Everything is KDL 2.0.
"""
import os
import random
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "inputs")
SPEC_BENCH = os.path.join(HERE, "..", "..", "tests", "kdl-spec", "tests", "benchmarks")


def write(name, text):
    with open(os.path.join(OUT, name + ".kdl"), "w", newline="\n") as f:
        f.write(text)
    print(f"{name:22} {len(text.encode()):>10} bytes")


WIDGETS = ("label", "button", "textbox", "checkbox", "slider", "image", "icon", "spacer")
WORDS = "save open close settings profile search filter apply cancel help about name email".split()


def ui(rng):
    """A UI framework's markup: deep nested containers of widgets with properties, the occasional
    type annotation, comment and slashdashed node. ~5 MB."""
    out = []

    def widget(depth):
        kind = rng.choice(WIDGETS)
        pad = "    " * depth
        word = rng.choice(WORDS)
        if kind == "label":
            out.append(f'{pad}label "{word.title()}:" style=bold size=(px){rng.randrange(10, 24)}\n')
        elif kind == "button":
            out.append(f'{pad}button "{word.title()}" id="btn-{rng.randrange(100000)}" on-click={word} '
                       f'enabled={"#true" if rng.random() < 0.9 else "#false"}\n')
        elif kind == "textbox":
            out.append(f'{pad}textbox id="{word}-{rng.randrange(1000)}" placeholder="Enter {word}" '
                       f'max-length={rng.randrange(8, 256)}\n')
        elif kind == "checkbox":
            out.append(f'{pad}checkbox "{word}" checked={"#true" if rng.random() < 0.5 else "#false"}\n')
        elif kind == "slider":
            out.append(f"{pad}slider min=0 max={rng.randrange(10, 1000)} value={rng.random() * 10:.3f} step=0.5\n")
        elif kind == "image":
            out.append(f'{pad}image src="assets/{word}_{rng.randrange(100)}.png" width=(px){rng.randrange(16, 512)} '
                       f"height=(px){rng.randrange(16, 512)}\n")
        elif kind == "icon":
            out.append(f"{pad}icon {word} tint=0x{rng.randrange(0x1000000):06X}\n")
        else:
            out.append(f"{pad}spacer (px){rng.randrange(4, 32)}\n")

    def container(depth, budget):
        pad = "    " * depth
        kind = rng.choice(("column", "row", "stack", "grid"))
        extra = f" columns={rng.randrange(2, 6)}" if kind == "grid" else ""
        if rng.random() < 0.05:
            out.append(f"{pad}// {' '.join(rng.choice(WORDS) for _ in range(6))}\n")
        slash = "/-" if rng.random() < 0.02 else ""
        out.append(f"{pad}{slash}{kind} spacing={rng.randrange(0, 16)} padding=(px){rng.randrange(0, 24)}{extra} {{\n")
        for _ in range(rng.randrange(2, 7)):
            if depth < 7 and budget > 1 and rng.random() < 0.35:
                container(depth + 1, budget // 2)
            else:
                widget(depth + 1)
        out.append(f"{pad}}}\n")

    out.append("// Generated UI markup\n")
    windows = 0
    while sum(map(len, out)) < 5_000_000:
        out.append(f'window "Window {windows}" width=1280 height=720 resizable=#true {{\n')
        for _ in range(8):
            container(1, 64)
        out.append("}\n")
        windows += 1
    return "".join(out)


def config(rng):
    """Flat configuration: many small nodes with arguments and properties. ~3 MB."""
    out = []
    for i in range(40000):
        out.append(f'package "pkg-{i}" version="{rng.randrange(10)}.{rng.randrange(50)}.{rng.randrange(100)}" '
                   f'optional={"#true" if i % 7 == 0 else "#false"}\n')
        out.append(f'    dependency "dep-{rng.randrange(40000)}" "^{rng.randrange(5)}.{rng.randrange(20)}"\n'
                   if i % 3 == 0 else "")
        out.append(f"setting key-{i} {rng.randrange(1_000_000)} ratio={rng.random():.4f}\n")
    return "".join(out)


def strings(rng):
    """String-heavy: quoted strings with escapes, raw strings and multi-line strings. ~4 MB."""
    out = []
    for i in range(20000):
        out.append(f'text "Line {i} with an escape\\t and a \\"quote\\" \\u{{1F600}} and more text here"\n')
        out.append(f'path #"C:\\Program Files\\App {i}\\bin"#\n')
        out.append('doc """\n    First line of a multi-line string\n    second line, indented\n        third\n    """\n')
    return "".join(out)


def numbers(rng):
    """Numeric arguments in every form: decimal, float, exponent, hex, octal, binary, underscores. ~4 MB."""
    out = []
    for i in range(30000):
        out.append(f"n {rng.randrange(-10**9, 10**9)} {rng.random() * 1000:.6f} {rng.random():.3e} "
                   f"0x{rng.randrange(0x10000):04x} 0o{rng.randrange(0o1000):o} 0b{rng.randrange(256):b} "
                   f"1_000_{rng.randrange(1000):03d}\n")
    return "".join(out)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in ("html-standard", "html-standard-compact"):
        source = os.path.join(SPEC_BENCH, name + ".kdl")
        if not os.path.exists(source):
            raise SystemExit(f"{source} missing: run tests/fetch-spec.sh first")
        shutil.copyfile(source, os.path.join(OUT, name + ".kdl"))
        print(f"{name:22} {os.path.getsize(source):>10} bytes (kdl-org/kdl benchmark)")
    rng = random.Random(1)
    write("ui", ui(rng))
    write("config", config(rng))
    write("strings", strings(rng))
    write("numbers", numbers(rng))


if __name__ == "__main__":
    main()
