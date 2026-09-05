//! `mnml export-config-zon` — the round-trip proof.
//!
//! 1. A fixture TOML that touches every section and every transform
//!    exports to exactly `tests/fixtures/export_config_zon/expected.zon`
//!    (library call and CLI alike; the CLI also gets its default
//!    output path and its overwrite guard checked).
//! 2. When the mnml-zig binary is on this machine, the exported file is
//!    fed to `mnml-zig --config … --headless` and the launch must show
//!    no `config:` diagnostic — a wrong enum literal, an unknown field
//!    or a syntax error would each toast one.
//! 3. The real `~/.config/mnml/config.toml`, when present, is exported
//!    to a temp dir (read-only on the source) and run through the same
//!    check; the verdict is printed, not asserted, since the file is
//!    whatever this machine happens to have. Cutover checklist item 3.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const FIXTURE: &str = include_str!("fixtures/export_config_zon/config.toml");
const EXPECTED: &str = include_str!("fixtures/export_config_zon/expected.zon");

/// Where a sibling checkout of mnml-zig leaves its debug binary.
/// `MNML_ZIG_BIN` overrides.
const DEFAULT_ZIG_BIN: &str = "/Users/chrismclennan/Projects/mnml-zig/zig-out/bin/mnml-zig";

fn mnml() -> Command {
    Command::new(env!("CARGO_BIN_EXE_mnml"))
}

fn assert_same_text(got: &str, want: &str, what: &str) {
    if got == want {
        return;
    }
    let first_diff = got
        .lines()
        .zip(want.lines())
        .position(|(a, b)| a != b)
        .map(|i| {
            format!(
                "first difference at line {}:\n  got:  {}\n  want: {}",
                i + 1,
                got.lines().nth(i).unwrap_or(""),
                want.lines().nth(i).unwrap_or("")
            )
        })
        .unwrap_or_else(|| {
            format!(
                "one is a prefix of the other ({} vs {} lines)",
                got.lines().count(),
                want.lines().count()
            )
        });
    panic!("{what} does not match expected.zon — {first_diff}\n\n--- got ---\n{got}");
}

#[test]
fn fixture_exports_to_the_expected_zon() {
    let e = mnml::config_zon_export::export_toml_to_zon(FIXTURE).expect("fixture is valid TOML");
    assert_same_text(&e.zon, EXPECTED, "library export");
    assert!(e.migrated > 50, "migrated {}", e.migrated);
    assert!(e.unmigrated > 5, "unmigrated {}", e.unmigrated);
}

#[test]
fn cli_writes_beside_the_source_and_guards_overwrites() {
    let d = tempfile::tempdir().unwrap();
    let src = d.path().join("config.toml");
    fs::write(&src, FIXTURE).unwrap();

    // Default output: `config.zon` beside the source.
    let out = mnml()
        .args(["export-config-zon", "--in"])
        .arg(&src)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let zon_path = d.path().join("config.zon");
    let got = fs::read_to_string(&zon_path).expect("config.zon written beside the source");
    assert_same_text(&got, EXPECTED, "CLI export");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("migrated"), "summary line: {stdout}");
    assert!(stdout.contains("unmigrated"), "summary line: {stdout}");
    // The source is untouched.
    assert_eq!(fs::read_to_string(&src).unwrap(), FIXTURE);

    // A second run refuses to overwrite …
    let out = mnml()
        .args(["export-config-zon", "--in"])
        .arg(&src)
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("--force"),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    // … unless told to.
    fs::write(&zon_path, "stale").unwrap();
    let out = mnml()
        .args(["export-config-zon", "--force", "--in"])
        .arg(&src)
        .output()
        .unwrap();
    assert!(out.status.success());
    assert_same_text(
        &fs::read_to_string(&zon_path).unwrap(),
        EXPECTED,
        "forced CLI export",
    );

    // `--workspace DIR` reads DIR/.mnml/config.toml and `--out` relocates.
    let ws = d.path().join("ws");
    fs::create_dir_all(ws.join(".mnml")).unwrap();
    fs::write(
        ws.join(".mnml/config.toml"),
        "[ui]\nwrap = true\n[editor]\ninput_style = \"vim\"\n",
    )
    .unwrap();
    let elsewhere = d.path().join("nested/dir/ws.zon");
    let out = mnml()
        .args(["export-config-zon", "--workspace"])
        .arg(&ws)
        .arg("--out")
        .arg(&elsewhere)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let got = fs::read_to_string(&elsewhere).unwrap();
    assert!(got.contains(".wrap = true,"), "{got}");
    assert!(got.contains(".input_style = .vim,"), "{got}");
    assert!(!ws.join(".mnml/config.zon").exists());

    // A missing source is an error, not an empty file.
    let out = mnml()
        .args(["export-config-zon", "--in"])
        .arg(d.path().join("nope.toml"))
        .output()
        .unwrap();
    assert!(!out.status.success());
}

// ─── the Zig side ────────────────────────────────────────────────────────

fn zig_bin() -> Option<PathBuf> {
    let p = std::env::var_os("MNML_ZIG_BIN")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_ZIG_BIN));
    p.is_file().then_some(p)
}

/// What one headless launch of mnml-zig on `zon` produced.
struct ZigRun {
    events: String,
    /// The `config:` toast lines from `screen.txt`, if any.
    diagnostics: Vec<String>,
    stderr: String,
}

/// Launch `mnml-zig --config ZON WS --headless` on a throw-away
/// workspace + data root, wait for its IPC channel, ask it to quit, and
/// collect what it said. Budget: 3 s to come up, 3 s to go down.
fn zig_round_trip(bin: &Path, zon: &Path) -> ZigRun {
    let d = tempfile::tempdir().unwrap();
    let ws = d.path().join("ws");
    let data_root = d.path().join("data-root");
    fs::create_dir_all(ws.join(".mnml")).unwrap();
    fs::create_dir_all(&data_root).unwrap();
    let stderr_path = d.path().join("stderr.log");
    let mut child = Command::new(bin)
        // `--config` before the workspace: mnml-zig's headless arg loop
        // takes the LAST bare argument as the workspace.
        .arg("--config")
        .arg(zon)
        .arg(&ws)
        .arg("--headless")
        .env("MNML_COLS", "80")
        .env("MNML_ROWS", "24")
        .env("MNML_DATA_ROOT", &data_root)
        .env_remove("MNML_IPC_DIR")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(fs::File::create(&stderr_path).unwrap())
        .spawn()
        .expect("spawn mnml-zig");

    let ipc = ws.join(".mnml/ipc-zig");
    let events_path = ipc.join("events.jsonl");
    let start = Instant::now();
    while !events_path.exists() && start.elapsed() < Duration::from_secs(3) {
        if let Ok(Some(_)) = child.try_wait() {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    // Let the first frame (and any startup toast) land in screen.txt.
    std::thread::sleep(Duration::from_millis(400));
    if let Ok(mut f) = fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(ipc.join("command"))
    {
        let _ = writeln!(f, "{{\"cmd\":\"quit\"}}");
    }
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(3) {
        if matches!(child.try_wait(), Ok(Some(_))) {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    // Reap unconditionally: `kill` on an exited child is a harmless
    // error, and `wait` is what frees the slot.
    let _ = child.kill();
    let _ = child.wait();

    let events = fs::read_to_string(&events_path).unwrap_or_default();
    let screen = fs::read_to_string(ipc.join("screen.txt")).unwrap_or_default();
    let stderr = fs::read_to_string(&stderr_path).unwrap_or_default();
    // A config diagnostic is a warn toast whose text starts `config:`;
    // the box wraps the `file:line:col: message` over the next lines.
    let mut diagnostics = Vec::new();
    let mut in_box = false;
    for line in screen.lines() {
        if line.contains("config:") {
            in_box = true;
        }
        if in_box {
            diagnostics.push(line.trim().to_string());
            if line.contains('╰') {
                in_box = false;
            }
        }
    }
    ZigRun {
        events,
        diagnostics,
        stderr,
    }
}

#[test]
fn zig_accepts_the_exported_fixture() {
    let Some(bin) = zig_bin() else {
        println!("mnml-zig binary not found — set MNML_ZIG_BIN or build ../mnml-zig; skipping");
        return;
    };
    let d = tempfile::tempdir().unwrap();
    let zon = d.path().join("config.zon");
    fs::write(&zon, EXPECTED).unwrap();
    let run = zig_round_trip(&bin, &zon);
    assert!(
        run.events.contains("\"event\":\"start\""),
        "mnml-zig did not start\nevents: {}\nstderr: {}",
        run.events,
        run.stderr
    );
    assert!(
        run.events.contains("\"event\":\"quit\""),
        "mnml-zig did not take the quit command\nevents: {}\nstderr: {}",
        run.events,
        run.stderr
    );
    assert!(
        !run.events.contains("\"error\"") && run.stderr.trim().is_empty(),
        "mnml-zig complained\nevents: {}\nstderr: {}",
        run.events,
        run.stderr
    );
    assert!(
        run.diagnostics.is_empty(),
        "mnml-zig raised a config diagnostic on the exported fixture:\n{}",
        run.diagnostics.join("\n")
    );
}

/// The detector must be able to fail: a value the Zig enum rejects
/// toasts a `config:` diagnostic, and `zig_round_trip` must see it.
#[test]
fn zig_rejects_a_bad_enum_literal_and_the_check_notices() {
    let Some(bin) = zig_bin() else {
        println!("mnml-zig binary not found — skipping");
        return;
    };
    let d = tempfile::tempdir().unwrap();
    let zon = d.path().join("config.zon");
    fs::write(&zon, ".{\n    .editor = .{ .input_style = .emacs },\n}\n").unwrap();
    let run = zig_round_trip(&bin, &zon);
    assert!(
        run.events.contains("\"event\":\"start\""),
        "mnml-zig did not start\nevents: {}\nstderr: {}",
        run.events,
        run.stderr
    );
    assert!(
        !run.diagnostics.is_empty(),
        "a bad enum literal produced no visible config diagnostic — the acceptance check is blind"
    );
}

/// Cutover checklist item 3: does the Zig binary accept THIS machine's
/// home config once converted? Read-only on the TOML; the ZON goes to a
/// temp dir. The verdict is printed (run with `--nocapture` to see it)
/// and only the export itself is asserted — the file's content is
/// whatever the user has.
#[test]
fn zig_accepts_the_real_home_config() {
    let Some(home) = std::env::var_os("HOME") else {
        println!("no HOME — skipping");
        return;
    };
    let src = PathBuf::from(home).join(".config/mnml/config.toml");
    if !src.is_file() {
        println!("{} not present — skipping", src.display());
        return;
    }
    let d = tempfile::tempdir().unwrap();
    let zon = d.path().join("config.zon");
    let e = mnml::config_zon_export::export_file(&src, &zon, false)
        .expect("the home config exports without error");
    println!(
        "exported {} → {} value(s) migrated, {} unmigrated item(s)",
        src.display(),
        e.migrated,
        e.unmigrated
    );
    let Some(bin) = zig_bin() else {
        println!("mnml-zig binary not found — cannot check acceptance");
        return;
    };
    let run = zig_round_trip(&bin, &zon);
    if !run.events.contains("\"event\":\"start\"") {
        println!(
            "mnml-zig did not start on it\nevents: {}\nstderr: {}",
            run.events, run.stderr
        );
    } else if run.diagnostics.is_empty() {
        println!("mnml-zig accepted the converted home config with no config diagnostic");
    } else {
        println!(
            "mnml-zig raised config diagnostic(s) on the converted home config:\n{}",
            run.diagnostics.join("\n")
        );
    }
}
