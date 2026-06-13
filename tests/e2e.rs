//! Runs every `tests/e2e/**/*.test` through the in-process headless harness
//! (`mnml::e2e`). Fails with a list of every failing file/step.

#[test]
fn e2e_suite() {
    // The project's own e2e suite trusts its own `tests/e2e/*.test` files
    // (they ship in this repo), so opt in to the `shell` step. A cloned
    // untrusted repo's `cargo test` would fail closed because this env
    // var isn't set in their crate's test harness.
    // untouched-surfaces-hunt-2026-06-08 SEV-2 #5.
    // SAFETY: process-global env-var write before the test body. Cargo
    // serializes `#[test]` invocations within a binary unless the
    // user passes `--test-threads`, and this var isn't read elsewhere
    // during normal flow — the harness only checks it inside Step::Shell.
    unsafe {
        std::env::set_var("MNML_E2E_ALLOW_SHELL", "1");
    }
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/e2e");
    let (outcomes, _) = mnml::e2e::run_path(&root);
    assert!(
        !outcomes.is_empty(),
        "no .test files found under {}",
        root.display()
    );
    let failures: Vec<String> = outcomes
        .iter()
        .filter(|o| !o.passed)
        .map(|o| format!("  {} — {}", o.name, o.message.clone().unwrap_or_default()))
        .collect();
    assert!(
        failures.is_empty(),
        "{} of {} .test file(s) failed:\n{}",
        failures.len(),
        outcomes.len(),
        failures.join("\n")
    );
}
