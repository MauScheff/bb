use std::{env, fs, path::Path};

use turbo_runtime::http_probe::run_self_hosted_http_process_probe;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let report = run_self_hosted_http_process_probe()?;
    let json = serde_json::to_string_pretty(&report)?;
    if let Ok(output_path) = env::var("TURBO_HTTP_PROBE_OUTPUT") {
        if let Some(parent) = Path::new(&output_path).parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(output_path, format!("{json}\n"))?;
    } else {
        println!("{json}");
    }
    if report.status == "ok" {
        Ok(())
    } else {
        Err("self-hosted HTTP probe failed".into())
    }
}
