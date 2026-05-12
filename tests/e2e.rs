//! Runs every `tests/e2e/**/*.test` through the in-process headless harness
//! (`mnml::e2e`). Fails with a list of every failing file/step.

#[test]
fn e2e_suite() {
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
