// Rust KDL benchmark: kdlbench <parse|write> <file> <min-samples>
//                     kdlbench typed <read|write> <file> <min-samples>
// kdl-rs (the official kdl crate): KdlDocument::parse_v2 builds its format-preserving document; write
// is KdlDocument::to_string of the document parsed once. Prints the node count as a check line.
// The typed mode maps inputs/ui.kdl onto serde-derived types with kdl::de::from_str (read) and writes
// them back with kdl::se::to_string (write); see the `typed` module.
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

/// The typed mapping of inputs/ui.kdl (gen-inputs.py `ui`) through kdl-rs's serde support.
///
/// kdl::de treats a document, and a node's properties plus children, as one map keyed by name, and
/// collects repeated names into a sequence. So an ordered, heterogeneous child list (a Vec of an enum
/// of widgets) cannot be expressed: each window/container gets one Vec per child kind, and the order
/// across kinds is lost (order within a kind is kept). Positional arguments use the `#0` rename and
/// properties the `#@name` rename (kdl::se writes a property, not a child node, only for `#@` names).
/// Type annotations such as `(px)14` are ignored and read as the bare number. Slashdashed containers
/// and comments are dropped by the parser.
///
/// Two gaps in kdl-rs's serde mapping need small adapters (all binding still goes through
/// kdl::de/kdl::se and derived impls):
/// - Reading a `Vec<T>` child field only works when the name repeats. A name that occurs once is
///   handed over as that one node, and a derived `Vec<T>` then reads the node's own arguments or
///   children as the elements (a lone `textbox id=..` becomes an empty Vec, a lone `row {..}` becomes
///   its children); a name that does not occur reads as `false`, which a Vec rejects even with
///   `#[serde(default)]`. `Many<T>` accepts all three shapes (see its Deserialize).
/// - Writing: a derived `Vec<T>` field of structs is written as one node whose arguments are the
///   elements, which fails for structs, and kdl::se has no "repeat this node per element" mode. But
///   its struct serializer accepts the same field name more than once, so Window, Container and Ui
///   have a hand-written Serialize that emits one `button`, `row`, ... field per element.
mod typed {
    use serde::de::{self, Deserializer, MapAccess, SeqAccess, Visitor};
    use serde::ser::{SerializeStruct, Serializer};
    use serde::{Deserialize, Serialize};
    use std::marker::PhantomData;

    /// A node type's field names as serde_derive passes them to deserialize_struct: kdl::de only
    /// exposes a node's `#0` / `#@name` entries when they are among the requested fields, so `Many`
    /// has to request them itself when it reads a single node
    pub trait NodeFields {
        const NAME: &'static str;
        const FIELDS: &'static [&'static str];
    }

    /// A repeated child: all the children of one name, in order (see the module comment)
    pub struct Many<T>(pub Vec<T>);

    impl<T> Default for Many<T> {
        fn default() -> Self {
            Many(Vec::new())
        }
    }

    impl<T> std::ops::Deref for Many<T> {
        type Target = Vec<T>;
        fn deref(&self) -> &Vec<T> {
            &self.0
        }
    }

    impl<'a, T> IntoIterator for &'a Many<T> {
        type Item = &'a T;
        type IntoIter = std::slice::Iter<'a, T>;
        fn into_iter(self) -> Self::IntoIter {
            self.0.iter()
        }
    }

    impl<'de, T: Deserialize<'de> + NodeFields> Deserialize<'de> for Many<T> {
        fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
            struct ManyVisitor<T>(PhantomData<T>);
            impl<'de, T: Deserialize<'de>> Visitor<'de> for ManyVisitor<T> {
                type Value = Many<T>;
                fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                    f.write_str("zero or more nodes")
                }
                // Absent: kdl::de reports an omitted child as `false`
                fn visit_bool<E: de::Error>(self, _: bool) -> Result<Many<T>, E> {
                    Ok(Many(Vec::new()))
                }
                // Repeated name: a sequence of the nodes
                fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Many<T>, A::Error> {
                    let mut items = Vec::with_capacity(seq.size_hint().unwrap_or(0));
                    while let Some(item) = seq.next_element()? {
                        items.push(item);
                    }
                    Ok(Many(items))
                }
                // A single node: its entries and children, as a map
                fn visit_map<A: MapAccess<'de>>(self, map: A) -> Result<Many<T>, A::Error> {
                    Ok(Many(vec![T::deserialize(de::value::MapAccessDeserializer::new(map))?]))
                }
            }
            deserializer.deserialize_struct(T::NAME, T::FIELDS, ManyVisitor(PhantomData))
        }
    }

    /// `spacer (px)N`: a node with a single argument maps to that scalar; repeated, to a sequence
    #[derive(Default)]
    pub struct Scalars(pub Vec<i64>);

    impl<'de> Deserialize<'de> for Scalars {
        fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
            struct ScalarsVisitor;
            impl<'de> Visitor<'de> for ScalarsVisitor {
                type Value = Scalars;
                fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                    f.write_str("zero or more single-integer nodes")
                }
                fn visit_bool<E: de::Error>(self, _: bool) -> Result<Scalars, E> {
                    Ok(Scalars(Vec::new()))
                }
                fn visit_i64<E: de::Error>(self, v: i64) -> Result<Scalars, E> {
                    Ok(Scalars(vec![v]))
                }
                fn visit_u64<E: de::Error>(self, v: u64) -> Result<Scalars, E> {
                    Ok(Scalars(vec![v as i64]))
                }
                fn visit_i128<E: de::Error>(self, v: i128) -> Result<Scalars, E> {
                    Ok(Scalars(vec![v as i64]))
                }
                fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Scalars, A::Error> {
                    let mut items = Vec::with_capacity(seq.size_hint().unwrap_or(0));
                    while let Some(item) = seq.next_element()? {
                        items.push(item);
                    }
                    Ok(Scalars(items))
                }
            }
            deserializer.deserialize_any(ScalarsVisitor)
        }
    }

    #[derive(Deserialize)]
    pub struct Ui {
        #[serde(default)]
        pub window: Many<Window>,
    }

    #[derive(Deserialize)]
    pub struct Window {
        #[serde(rename = "#0")]
        pub title: String,
        #[serde(rename = "#@width")]
        pub width: i64,
        #[serde(rename = "#@height")]
        pub height: i64,
        #[serde(rename = "#@resizable")]
        pub resizable: bool,
        #[serde(default)]
        pub column: Many<Container>,
        #[serde(default)]
        pub row: Many<Container>,
        #[serde(default)]
        pub stack: Many<Container>,
        #[serde(default)]
        pub grid: Many<Container>,
    }

    /// column/row/stack/grid; `columns` is present on grid only
    #[derive(Deserialize)]
    pub struct Container {
        #[serde(rename = "#@spacing")]
        pub spacing: i64,
        #[serde(rename = "#@padding")]
        pub padding: i64,
        #[serde(rename = "#@columns", default)]
        pub columns: Option<i64>,
        #[serde(default)]
        pub column: Many<Container>,
        #[serde(default)]
        pub row: Many<Container>,
        #[serde(default)]
        pub stack: Many<Container>,
        #[serde(default)]
        pub grid: Many<Container>,
        #[serde(default)]
        pub label: Many<Label>,
        #[serde(default)]
        pub button: Many<Button>,
        #[serde(default)]
        pub textbox: Many<Textbox>,
        #[serde(default)]
        pub checkbox: Many<Checkbox>,
        #[serde(default)]
        pub slider: Many<Slider>,
        #[serde(default)]
        pub image: Many<Image>,
        #[serde(default)]
        pub icon: Many<Icon>,
        #[serde(default)]
        pub spacer: Scalars,
    }

    #[derive(Deserialize, Serialize)]
    pub struct Label {
        #[serde(rename = "#0")]
        pub text: String,
        #[serde(rename = "#@style")]
        pub style: String,
        #[serde(rename = "#@size")]
        pub size: i64,
    }

    #[derive(Deserialize, Serialize)]
    pub struct Button {
        #[serde(rename = "#0")]
        pub text: String,
        #[serde(rename = "#@id")]
        pub id: String,
        #[serde(rename = "#@on-click")]
        pub on_click: String,
        #[serde(rename = "#@enabled")]
        pub enabled: bool,
    }

    #[derive(Deserialize, Serialize)]
    pub struct Textbox {
        #[serde(rename = "#@id")]
        pub id: String,
        #[serde(rename = "#@placeholder")]
        pub placeholder: String,
        #[serde(rename = "#@max-length")]
        pub max_length: i64,
    }

    #[derive(Deserialize, Serialize)]
    pub struct Checkbox {
        #[serde(rename = "#0")]
        pub text: String,
        #[serde(rename = "#@checked")]
        pub checked: bool,
    }

    #[derive(Deserialize, Serialize)]
    pub struct Slider {
        #[serde(rename = "#@min")]
        pub min: i64,
        #[serde(rename = "#@max")]
        pub max: i64,
        #[serde(rename = "#@value")]
        pub value: f64,
        #[serde(rename = "#@step")]
        pub step: f64,
    }

    #[derive(Deserialize, Serialize)]
    pub struct Image {
        #[serde(rename = "#@src")]
        pub src: String,
        #[serde(rename = "#@width")]
        pub width: i64,
        #[serde(rename = "#@height")]
        pub height: i64,
    }

    #[derive(Deserialize, Serialize)]
    pub struct Icon {
        #[serde(rename = "#0")]
        pub name: String,
        #[serde(rename = "#@tint")]
        pub tint: i64,
    }

    const CHILDREN: [&str; 12] = ["column", "row", "stack", "grid", "label", "button", "textbox", "checkbox",
        "slider", "image", "icon", "spacer"];
    impl NodeFields for Window {
        const NAME: &'static str = "Window";
        const FIELDS: &'static [&'static str] = &["#0", "#@width", "#@height", "#@resizable", "column", "row",
            "stack", "grid"];
    }
    impl NodeFields for Container {
        const NAME: &'static str = "Container";
        const FIELDS: &'static [&'static str] = &{
            let mut f = [""; 15];
            f[0] = "#@spacing";
            f[1] = "#@padding";
            f[2] = "#@columns";
            let mut i = 0;
            while i < CHILDREN.len() {
                f[3 + i] = CHILDREN[i];
                i += 1;
            }
            f
        };
    }
    impl NodeFields for Label {
        const NAME: &'static str = "Label";
        const FIELDS: &'static [&'static str] = &["#0", "#@style", "#@size"];
    }
    impl NodeFields for Button {
        const NAME: &'static str = "Button";
        const FIELDS: &'static [&'static str] = &["#0", "#@id", "#@on-click", "#@enabled"];
    }
    impl NodeFields for Textbox {
        const NAME: &'static str = "Textbox";
        const FIELDS: &'static [&'static str] = &["#@id", "#@placeholder", "#@max-length"];
    }
    impl NodeFields for Checkbox {
        const NAME: &'static str = "Checkbox";
        const FIELDS: &'static [&'static str] = &["#0", "#@checked"];
    }
    impl NodeFields for Slider {
        const NAME: &'static str = "Slider";
        const FIELDS: &'static [&'static str] = &["#@min", "#@max", "#@value", "#@step"];
    }
    impl NodeFields for Image {
        const NAME: &'static str = "Image";
        const FIELDS: &'static [&'static str] = &["#@src", "#@width", "#@height"];
    }
    impl NodeFields for Icon {
        const NAME: &'static str = "Icon";
        const FIELDS: &'static [&'static str] = &["#0", "#@tint"];
    }

    /// One field per element: kdl::se's struct serializer turns each into a child node of that name
    fn each<S: SerializeStruct, T: Serialize>(s: &mut S, name: &'static str, items: &[T]) -> Result<(), S::Error> {
        for item in items {
            s.serialize_field(name, item)?;
        }
        Ok(())
    }

    impl Serialize for Ui {
        fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
            let mut s = serializer.serialize_struct("Ui", self.window.len())?;
            each(&mut s, "window", &self.window)?;
            s.end()
        }
    }

    impl Serialize for Window {
        fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
            let mut s = serializer.serialize_struct("Window", 4)?;
            s.serialize_field("#0", &self.title)?;
            s.serialize_field("#@width", &self.width)?;
            s.serialize_field("#@height", &self.height)?;
            s.serialize_field("#@resizable", &self.resizable)?;
            each(&mut s, "column", &self.column)?;
            each(&mut s, "row", &self.row)?;
            each(&mut s, "stack", &self.stack)?;
            each(&mut s, "grid", &self.grid)?;
            s.end()
        }
    }

    impl Serialize for Container {
        fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
            let mut s = serializer.serialize_struct("Container", 3)?;
            s.serialize_field("#@spacing", &self.spacing)?;
            s.serialize_field("#@padding", &self.padding)?;
            if let Some(columns) = self.columns {
                s.serialize_field("#@columns", &columns)?;
            }
            each(&mut s, "column", &self.column)?;
            each(&mut s, "row", &self.row)?;
            each(&mut s, "stack", &self.stack)?;
            each(&mut s, "grid", &self.grid)?;
            each(&mut s, "label", &self.label)?;
            each(&mut s, "button", &self.button)?;
            each(&mut s, "textbox", &self.textbox)?;
            each(&mut s, "checkbox", &self.checkbox)?;
            each(&mut s, "slider", &self.slider)?;
            each(&mut s, "image", &self.image)?;
            each(&mut s, "icon", &self.icon)?;
            each(&mut s, "spacer", &self.spacer.0)?;
            s.end()
        }
    }

    /// The shared check: (node count, checksum) as defined for every typed harness
    pub fn check(ui: &Ui) -> (i64, i64) {
        let (mut count, mut sum) = (0i64, 0i64);
        for w in &ui.window {
            count += 1;
            sum += w.width + w.height;
            for c in w.column.iter().chain(&w.row).chain(&w.stack).chain(&w.grid) {
                container(c, &mut count, &mut sum);
            }
        }
        (count, sum)
    }

    fn container(c: &Container, count: &mut i64, sum: &mut i64) {
        *count += 1;
        *sum += c.spacing + c.padding + c.columns.unwrap_or(0);
        for child in c.column.iter().chain(&c.row).chain(&c.stack).chain(&c.grid) {
            container(child, count, sum);
        }
        for l in &c.label {
            *sum += l.text.len() as i64 + l.size;
        }
        for b in &c.button {
            *sum += b.id.len() as i64 + b.enabled as i64;
        }
        for t in &c.textbox {
            *sum += t.max_length;
        }
        for x in &c.checkbox {
            *sum += x.checked as i64;
        }
        for s in &c.slider {
            *sum += s.max + (s.value * 1000.0) as i64;
        }
        for i in &c.image {
            *sum += i.width + i.height;
        }
        for i in &c.icon {
            *sum += i.tint;
        }
        for s in &c.spacer.0 {
            *sum += s;
        }
        *count += (c.label.len() + c.button.len() + c.textbox.len() + c.checkbox.len() + c.slider.len()
            + c.image.len() + c.icon.len() + c.spacer.0.len()) as i64;
    }
}

/// `typed <read|write> <file> <min-samples>`: exits 0 ok, 1 on a library error
fn typed_main(mode: &str, text: &str, min_samples: usize) {
    let ui: typed::Ui = match kdl::de::from_str(text) {
        Ok(u) => u,
        Err(e) => {
            eprintln!("deserialize error: {e}");
            std::process::exit(1);
        }
    };
    let (count, sum) = typed::check(&ui);
    println!("check: {count} {sum}");
    let written = match kdl::se::to_string(&ui) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("serialize error: {e}");
            std::process::exit(1);
        }
    };
    match kdl::de::from_str::<typed::Ui>(&written) {
        Ok(again) => {
            let (c2, s2) = typed::check(&again);
            println!("re-read check: {c2} {s2}");
        }
        Err(e) => {
            eprintln!("re-read deserialize error: {e}");
            std::process::exit(1);
        }
    }
    let (median, n, converged, bytes) = if mode == "read" {
        let (m, n, c) = measure(min_samples, || {
            std::hint::black_box(kdl::de::from_str::<typed::Ui>(text).unwrap());
        });
        (m, n, c, text.len())
    } else {
        let mut output = String::new();
        let (m, n, c) = measure(min_samples, || output = kdl::se::to_string(&ui).unwrap());
        (m, n, c, output.len())
    };
    report(median, n, converged, bytes);
}

fn report(median: f64, n: usize, converged: bool, bytes: usize) {
    let ms = median / 1e6;
    println!("{:.3} ms/op {:.1} MB/s (n={}, {})", ms, bytes as f64 / 1048576.0 / (ms / 1000.0), n,
        if converged { "converged" } else { "capped" });
}

/// Every node, children included
fn count(doc: &KdlDocument) -> usize {
    doc.nodes().iter().map(|n| 1 + n.children().map_or(0, count)).sum()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: kdlbench <parse|write> <file> <min-samples>");
        eprintln!("       kdlbench typed <read|write> <file> <min-samples>");
        std::process::exit(2);
    }
    if args[1] == "typed" {
        if args.len() < 5 {
            eprintln!("usage: kdlbench typed <read|write> <file> <min-samples>");
            std::process::exit(2);
        }
        let text = std::fs::read_to_string(&args[3]).expect("read");
        typed_main(&args[2], &text, args[4].parse().expect("min samples"));
        return;
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
    report(median, n, converged, bytes);
}
