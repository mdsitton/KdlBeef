// Rust KDL benchmark: kdlbench <parse|write> <file> <min-samples>
// kdl-rs (the official kdl crate): KdlDocument::parse_v2 builds its format-preserving document; write
// is KdlDocument::to_string of the document parsed once. Prints the node count as a check line.
use kdl::KdlDocument;
use std::time::Instant;

/// The rule shared by every harness in bench/compare (see ../run.sh): warm up for at least 1 s, then
/// time single runs until at least `min_samples` were taken and at least 60% lie within ±10% of their
/// median, or 10 s / 1000 samples have passed. Returns the median sample in ns.
fn measure(min_samples: usize, mut op: impl FnMut()) -> (f64, usize, bool) {
    let warm = Instant::now();
    loop {
        op();
        if warm.elapsed().as_secs_f64() >= 1.0 {
            break;
        }
    }
    let start = Instant::now();
    let mut samples: Vec<f64> = Vec::new();
    loop {
        let t0 = Instant::now();
        op();
        samples.push(t0.elapsed().as_nanos() as f64);
        let mut sorted = samples.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let n = sorted.len();
        let median = if n % 2 == 1 { sorted[n / 2] } else { (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0 };
        if n >= min_samples {
            let within = samples.iter().filter(|&&s| s >= median * 0.9 && s <= median * 1.1).count();
            if within as f64 >= 0.6 * n as f64 {
                return (median, n, true);
            }
        }
        if n >= 1000 || start.elapsed().as_secs_f64() >= 10.0 {
            return (median, n, false);
        }
    }
}

/// Every node, children included
fn count(doc: &KdlDocument) -> usize {
    doc.nodes().iter().map(|n| 1 + n.children().map_or(0, count)).sum()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: kdlbench <parse|write> <file> <min-samples>");
        std::process::exit(2);
    }
    let text = std::fs::read_to_string(&args[2]).expect("read");
    let min_samples: usize = args[3].parse().expect("min samples");
    let doc = match KdlDocument::parse_v2(&text) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("parse error: {e:?}");
            std::process::exit(1);
        }
    };
    println!("nodes: {}", count(&doc));
    let (median, n, converged, bytes) = if args[1] == "parse" {
        let (m, n, c) = measure(min_samples, || {
            std::hint::black_box(KdlDocument::parse_v2(&text).unwrap());
        });
        (m, n, c, text.len())
    } else {
        let mut output = String::new();
        let (m, n, c) = measure(min_samples, || output = doc.to_string());
        (m, n, c, output.len())
    };
    let ms = median / 1e6;
    println!("{:.3} ms/op {:.1} MB/s (n={}, {})", ms, bytes as f64 / 1048576.0 / (ms / 1000.0), n,
        if converged { "converged" } else { "capped" });
}
