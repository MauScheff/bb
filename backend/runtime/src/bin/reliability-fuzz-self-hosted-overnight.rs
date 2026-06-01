use std::{env, fs, path::Path};

use turbo_runtime::fuzz::run_reliability_fuzz_self_hosted_overnight;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let seed = env_u64("TURBO_FUZZ_SEED", 123)?;
    let count = env_u64("TURBO_FUZZ_COUNT", 32)?;
    let report = run_reliability_fuzz_self_hosted_overnight(seed, count)?;
    write_report(&report)?;
    if report.status == "ok" {
        Ok(())
    } else {
        Err("self-hosted reliability fuzz failed".into())
    }
}

fn env_u64(name: &str, fallback: u64) -> Result<u64, Box<dyn std::error::Error>> {
    Ok(match env::var(name) {
        Ok(value) => value.parse()?,
        Err(_) => fallback,
    })
}

fn write_report(
    report: &turbo_runtime::fuzz::FuzzReport,
) -> Result<(), Box<dyn std::error::Error>> {
    let json = serde_json::to_string_pretty(report)?;
    if let Ok(output_path) = env::var("TURBO_FUZZ_OUTPUT") {
        if let Some(parent) = Path::new(&output_path).parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(output_path, format!("{json}\n"))?;
    } else {
        println!("{json}");
    }
    Ok(())
}
