use std::{env, fs};

use turbo_runtime::websocket_network::run_self_hosted_websocket_probe;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let report = run_self_hosted_websocket_probe()?;
    let json = serde_json::to_string_pretty(&report)?;
    if let Ok(output_path) = env::var("TURBO_WEBSOCKET_PROBE_OUTPUT") {
        fs::write(output_path, format!("{json}\n"))?;
    } else {
        println!("{json}");
    }
    if report.status == "ok" {
        Ok(())
    } else {
        Err("self-hosted websocket probe failed".into())
    }
}
