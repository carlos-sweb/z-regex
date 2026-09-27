//! Rust regex harness of z-regex's cross-engine benchmark (docs/BENCHMARKS.md).
//!
//!   cargo run --release -- CORPUS_DIR CASES_JSON
//!
//! T0 cases use `regex::bytes` with `unicode(false)`: `\d`, `\w` and the
//! classes are ASCII, as in ECMAScript without `u`. T1 cases use
//! `regex::Regex` (Unicode). Rust regex has no backreferences, no
//! lookaround and no `v` flag: those cases are not run here. findAll collects
//! every match (`captures_iter` when the pattern has groups, `find_iter`
//! otherwise); "execAt" is a loop of `find_at` / `captures_read_at` with one
//! reused `CaptureLocations` (no allocation). The regex crate exposes no
//! size of a compiled regex: no bytes column.
use std::time::Instant;

const MB: f64 = 1024.0 * 1024.0;

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[v.len() / 2]
}

/// One warm-up pass, then the median of up to 5 (5 s budget); MB/s.
fn timed<F: FnMut() -> usize>(bytes: usize, mut f: F) -> (f64, usize) {
    let mut n = f();
    let mut times = Vec::new();
    let mut spent = 0.0;
    for _ in 0..5 {
        let t = Instant::now();
        n = f();
        let dt = t.elapsed().as_secs_f64();
        times.push(dt);
        spent += dt;
        if spent > 5.0 {
            break;
        }
    }
    (bytes as f64 / MB / median(times), n)
}

fn short_ns<F: FnMut() -> bool>(mut f: F) -> f64 {
    for _ in 0..10000 {
        std::hint::black_box(f());
    }
    let iters = 200000;
    let mut s = Vec::new();
    for _ in 0..11 {
        let t = Instant::now();
        for _ in 0..iters {
            std::hint::black_box(f());
        }
        s.push(t.elapsed().as_nanos() as f64 / iters as f64);
    }
    median(s)
}

fn compile_us<T, F: FnMut() -> T>(mut f: F) -> f64 {
    let mut s = Vec::new();
    for _ in 0..21 {
        let t = Instant::now();
        std::hint::black_box(f());
        s.push(t.elapsed().as_nanos() as f64 / 1e3);
    }
    median(s)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let corpus = &args[1];
    let cases: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&args[2]).unwrap()).unwrap();
    let mut out = Vec::new();
    for c in cases["cases"].as_array().unwrap() {
        let engines: Vec<&str> = c["engines"].as_array().unwrap().iter().map(|e| e.as_str().unwrap()).collect();
        if !engines.contains(&"rust") || c.get("adversarial").is_some() {
            continue;
        }
        let id = c["id"].as_str().unwrap();
        let pattern = c["pattern"].as_str().unwrap();
        let tier = c["tier"].as_str().unwrap();
        let short = c["short"].as_str().unwrap();
        let input = std::fs::read(format!("{}/{}.txt", corpus, c["corpus"].as_str().unwrap())).unwrap();
        let bytes = input.len();
        let (fa, ex, sn, cu, matches, exec_matches);
        if tier == "T0" {
            let build = || regex::bytes::RegexBuilder::new(pattern).unicode(false).build().unwrap();
            cu = compile_us(build);
            let re = build();
            let groups = re.captures_len() > 1;
            let r = timed(bytes, || if groups { re.captures_iter(&input).collect::<Vec<_>>().len() } else { re.find_iter(&input).collect::<Vec<_>>().len() });
            fa = r.0;
            matches = r.1;
            let mut locs = re.capture_locations();
            let r = timed(bytes, || {
                let mut n = 0;
                let mut i = 0;
                while i <= input.len() {
                    let m = if groups { re.captures_read_at(&mut locs, &input, i).map(|m| (m.start(), m.end())) } else { re.find_at(&input, i).map(|m| (m.start(), m.end())) };
                    match m {
                        None => break,
                        Some((s, e)) => {
                            n += 1;
                            i = if e == s { e + 1 } else { e };
                        }
                    }
                }
                n
            });
            ex = r.0;
            exec_matches = r.1;
            let sb = short.as_bytes();
            sn = short_ns(|| if groups { re.captures_read_at(&mut locs, sb, 0).is_some() } else { re.find_at(sb, 0).is_some() });
        } else {
            let text = String::from_utf8(input).unwrap();
            let build = || regex::Regex::new(pattern).unwrap();
            cu = compile_us(build);
            let re = build();
            let groups = re.captures_len() > 1;
            let r = timed(bytes, || if groups { re.captures_iter(&text).collect::<Vec<_>>().len() } else { re.find_iter(&text).collect::<Vec<_>>().len() });
            fa = r.0;
            matches = r.1;
            let mut locs = re.capture_locations();
            let r = timed(bytes, || {
                let mut n = 0;
                let mut i = 0;
                while i <= text.len() {
                    let m = if groups { re.captures_read_at(&mut locs, &text, i).map(|m| (m.start(), m.end())) } else { re.find_at(&text, i).map(|m| (m.start(), m.end())) };
                    match m {
                        None => break,
                        Some((s, e)) => {
                            n += 1;
                            i = if e == s { e + text[e..].chars().next().map_or(1, |ch| ch.len_utf8()) } else { e };
                        }
                    }
                }
                n
            });
            ex = r.0;
            exec_matches = r.1;
            sn = short_ns(|| re.find_at(short, 0).is_some());
        }
        out.push(serde_json::json!({ "id": id, "findall_mbps": fa, "execat_mbps": ex, "matches": matches, "exec_matches": exec_matches, "short_ns": sn, "compile_us": cu }));
    }
    println!("{}", serde_json::json!({ "engine": "rust", "regex": "1.13.1", "cases": out }));
}
