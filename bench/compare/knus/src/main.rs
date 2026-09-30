// knus benchmark: knusbench <parse|write> <file> <min-samples>
//                 knusbench checkv1 <v2.kdl> <v1.kdl>
// knus (a knuffel fork) reads KDL v1 only, so it parses the v1 translation of each input,
// inputs/v1/<name>.kdl (written by gen-inputs.py with ckdl-cat -1), and MB/s is of that file.
// parse is knus::parse_ast into its document (the AST its derive decoders read); knus has no writer,
// so write exits 3 (n/a). Prints the node count as a check line.
//
// checkv1 checks a translation independently of ckdl: kdl-rs's v1 parser must read it, with the same
// node count as kdl-rs's v2 parser reads from the original. (kdl-rs's own v2_to_v1 is not used: it
// leaves v2 bare-identifier values such as style=bold unquoted and keeps """ multi-line strings,
// neither of which is KDL v1.)
use std::time::Instant;

use knus::span::Span;

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
fn count(nodes: &[knus::ast::SpannedNode<Span>]) -> usize {
    nodes.iter().map(|n| 1 + n.children.as_ref().map_or(0, |c| count(c))).sum()
}

fn count_kdl(doc: &kdl::KdlDocument) -> usize {
    doc.nodes().iter().map(|n| 1 + n.children().map_or(0, count_kdl)).sum()
}

fn check_v1(v2_path: &str, v1_path: &str) {
    let text = std::fs::read_to_string(v2_path).expect("read");
    let v2 = kdl::KdlDocument::parse_v2(&text).expect("parse v2");
    let v1 = std::fs::read_to_string(v1_path).expect("read");
    let back = match kdl::KdlDocument::parse_v1(&v1) {
        Ok(d) => d,
        Err(e) => {
            for d in e.diagnostics.iter().take(3) {
                let at = d.span.offset();
                let from = v1[..at].rfind('\n').map_or(0, |i| i + 1);
                let to = v1[at..].find('\n').map_or(v1.len(), |i| at + i);
                eprintln!("{v1_path} is not valid KDL v1: {:?} at byte {at}: {}", d.message, &v1[from..to]);
            }
            std::process::exit(1);
        }
    };
    if count_kdl(&back) != count_kdl(&v2) {
        eprintln!("node count changed in translation: {} -> {}", count_kdl(&v2), count_kdl(&back));
        std::process::exit(1);
    }
}

/// inputs/<name>.kdl -> inputs/v1/<name>.kdl
fn v1_path(path: &str) -> std::path::PathBuf {
    let p = std::path::Path::new(path);
    p.parent().unwrap_or(std::path::Path::new(".")).join("v1").join(p.file_name().expect("file name"))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: knusbench <parse|write> <file> <min-samples>");
        eprintln!("       knusbench tov1 <in.kdl> <out.kdl>");
        std::process::exit(2);
    }
    if args[1] == "checkv1" {
        check_v1(&args[2], &args[3]);
        return;
    }
    if args[1] != "parse" {
        eprintln!("knus has no writer");
        std::process::exit(3);
    }
    let path = v1_path(&args[2]);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        eprintln!("{}: {e} (run gen-inputs.py after build.sh)", path.display());
        std::process::exit(2);
    });
    let min_samples: usize = args[3].parse().expect("min samples");
    let doc = match knus::parse_ast::<Span>("input.kdl", &text) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("parse error: {e:?}");
            std::process::exit(1);
        }
    };
    println!("nodes: {}", count(&doc.nodes));
    let (median, n, converged) = measure(min_samples, || {
        std::hint::black_box(knus::parse_ast::<Span>("input.kdl", &text).unwrap());
    });
    let ms = median / 1e6;
    println!("{:.3} ms/op {:.1} MB/s (n={}, {})", ms, text.len() as f64 / 1048576.0 / (ms / 1000.0), n,
        if converged { "converged" } else { "capped" });
}
