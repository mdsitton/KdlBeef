// JavaScript KDL benchmark: node bench.mjs <bgotink|kdljs> <parse|write> <file> <min-samples>
//   bgotink - @bgotink/kdl: parse(text) into its format-preserving document; write is format(doc)
//   kdljs   - kdljs (kdl-org): parse(text) into plain objects; write is format(output)
// Prints the node count as a check line. Timings follow the shared rule (see measure and ../run.sh);
// the 1 s warm-up also lets V8 optimize the parser.
import { readFileSync } from "node:fs";
import * as bgotink from "@bgotink/kdl";
import * as kdljs from "kdljs";

function measure(minSamples, op) {
  const warm = process.hrtime.bigint();
  do op();
  while (process.hrtime.bigint() - warm < 1_000_000_000n);
  const start = process.hrtime.bigint();
  const samples = [];
  for (;;) {
    const t0 = process.hrtime.bigint();
    op();
    samples.push(Number(process.hrtime.bigint() - t0));
    const sorted = [...samples].sort((a, b) => a - b);
    const n = sorted.length;
    const median = n % 2 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
    if (n >= minSamples && samples.filter((s) => s >= median * 0.9 && s <= median * 1.1).length >= 0.6 * n)
      return { median, n, converged: true };
    if (n >= 1000 || process.hrtime.bigint() - start >= 10_000_000_000n) return { median, n, converged: false };
  }
}

const [lib, mode, file, min] = process.argv.slice(2);
const bytes = readFileSync(file);
const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);

let parse, write, count;
if (lib === "bgotink") {
  parse = () => bgotink.parse(text);
  write = (doc) => bgotink.format(doc);
  count = (nodes) => nodes.reduce((n, node) => n + 1 + (node.children ? count(node.children.nodes) : 0), 0);
} else if (lib === "kdljs") {
  parse = () => {
    const { output, errors } = kdljs.parse(text);
    if (errors.length) throw new Error(errors[0].message);
    return output;
  };
  write = (doc) => kdljs.format(doc);
  count = (nodes) => nodes.reduce((n, node) => n + 1 + count(node.children), 0);
} else {
  console.error("unknown library", lib);
  process.exit(2);
}

let doc;
try {
  doc = parse();
} catch (e) {
  console.error("parse error:", e.message);
  process.exit(1);
}
console.log(`nodes: ${count(lib === "bgotink" ? doc.nodes : doc)}`);
let size = bytes.length;
let m;
if (mode === "parse") m = measure(Number(min), parse);
else {
  let out = "";
  m = measure(Number(min), () => (out = write(doc)));
  size = Buffer.byteLength(out);
}
const ms = m.median / 1e6;
console.log(`${ms.toFixed(3)} ms/op ${(size / 1048576 / (ms / 1000)).toFixed(1)} MB/s (n=${m.n}, ${m.converged ? "converged" : "capped"})`);
