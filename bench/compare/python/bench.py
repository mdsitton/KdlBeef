"""Python KDL benchmark: bench.py <kdlpy|ckdl> <parse|write> <file> <min-samples>

  kdlpy - kdl-py (tabatkins): kdl.parse(text) into its dataclass document (typed values kept:
          nativeUntaggedValues/nativeTaggedValues off); write is Document.print()
  ckdl  - ckdl's Cython binding: ckdl.parse(text, version="2") into its Document; write is dump()

Prints the node count as a check line. Timings follow the shared rule (see measure and ../run.sh).
"""
import sys
import time


def measure(min_samples, op):
    warm = time.perf_counter_ns()
    while True:
        op()
        if time.perf_counter_ns() - warm >= 1_000_000_000:
            break
    start = time.perf_counter_ns()
    samples = []
    while True:
        t0 = time.perf_counter_ns()
        op()
        samples.append(time.perf_counter_ns() - t0)
        ordered = sorted(samples)
        n = len(ordered)
        median = ordered[n // 2] if n % 2 else (ordered[n // 2 - 1] + ordered[n // 2]) / 2
        if n >= min_samples and sum(median * 0.9 <= s <= median * 1.1 for s in samples) >= 0.6 * n:
            return median, n, True
        if n >= 1000 or time.perf_counter_ns() - start >= 10_000_000_000:
            return median, n, False


def main():
    if len(sys.argv) < 5:
        print("usage: bench.py <kdlpy|ckdl> <parse|write> <file> <min-samples>", file=sys.stderr)
        sys.exit(2)
    lib, mode, path, min_samples = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    with open(path, "rb") as f:
        text = f.read().decode("utf-8")

    if lib == "kdlpy":
        import kdl
        config = kdl.ParseConfig(nativeUntaggedValues=False, nativeTaggedValues=False)
        parse = lambda: kdl.parse(text, config)
        write = lambda doc: doc.print()
        count = lambda nodes: sum(1 + count(n.nodes) for n in nodes)
    elif lib == "ckdl":
        import ckdl
        parse = lambda: ckdl.parse(text, version="2")
        write = lambda doc: doc.dump()
        count = lambda nodes: sum(1 + count(n.children) for n in nodes)
    else:
        print("unknown library", lib, file=sys.stderr)
        sys.exit(2)

    try:
        doc = parse()
    except Exception as e:
        print("parse error:", e, file=sys.stderr)
        sys.exit(1)
    print(f"nodes: {count(doc.nodes)}")
    size = len(text.encode())
    if mode == "parse":
        median, n, converged = measure(min_samples, parse)
    else:
        out = [""]

        def op():
            out[0] = write(doc)

        median, n, converged = measure(min_samples, op)
        size = len(out[0].encode())
    ms = median / 1e6
    print(f"{ms:.3f} ms/op {size / 1048576 / (ms / 1000):.1f} MB/s (n={n}, {'converged' if converged else 'capped'})")


if __name__ == "__main__":
    main()
