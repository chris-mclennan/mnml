//! Smoke-test for the direct-API agentic loop (`agent_to_channel`).
//! Builds a tiny throwaway workspace, runs one prompt that should
//! trigger the read-only tools, and prints the streamed output +
//! `[tool: …]` status lines.
//!
//! Run: `ANTHROPIC_API_KEY=… cargo run --example ai_agent_smoke`
//!
//! Costs a few API tokens. Verifies the tool-use SSE parsing + the
//! request → tool-call → request loop end-to-end (the part that can't
//! be unit-tested without a live server).

use std::sync::atomic::AtomicBool;
use std::sync::mpsc;

use mnml::ai::AiMsg;
use mnml::ai::api_client::agent_to_channel;

fn main() {
    if std::env::var("ANTHROPIC_API_KEY").is_err() {
        eprintln!("set ANTHROPIC_API_KEY to run this smoke test");
        std::process::exit(1);
    }
    // Throwaway workspace with two files for the agent to discover.
    let dir = std::env::temp_dir().join(format!("mnml-agent-smoke-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create temp workspace");
    std::fs::write(
        dir.join("greet.rs"),
        "fn greet(name: &str) -> String {\n    format!(\"hello, {name}!\")\n}\n",
    )
    .expect("write greet.rs");
    std::fs::write(
        dir.join("README.md"),
        "# demo\nA one-function demo crate.\n",
    )
    .expect("write README.md");
    eprintln!("workspace: {}", dir.display());

    let prompt = "List the files in this workspace, read the Rust file, and tell me \
        in one sentence what the function does.";
    let (tx, rx) = mpsc::channel();
    let cancel = AtomicBool::new(false);

    // Blocking — runs the whole agent loop, buffering messages into rx.
    agent_to_channel(prompt, &dir, None, None, None, &cancel, tx, 1);

    let mut done = false;
    for (_, msg) in rx.iter() {
        match msg {
            AiMsg::Delta(d) => print!("{d}"),
            AiMsg::Done(text) => {
                println!("\n\n=== DONE ===\n{text}");
                done = true;
            }
            AiMsg::Failed(e) => {
                eprintln!("\n\nFAILED: {e}");
                std::process::exit(1);
            }
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    if !done {
        eprintln!("no Done message received");
        std::process::exit(1);
    }
}
