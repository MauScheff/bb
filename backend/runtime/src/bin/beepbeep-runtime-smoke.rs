use std::{
    net::TcpListener,
    sync::{Arc, Mutex},
};

use turbo_runtime::{
    http::RuntimeHttpConfig, http_probe::build_probe_http_service_with_config,
    server::serve_forever_with_websocket, websocket_network::AppCompatibleWebSocketHub,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let bind_addr = std::env::var("TURBO_RUNTIME_BIND")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "127.0.0.1:8091".to_owned());
    let listener = TcpListener::bind(&bind_addr)?;
    let service = Arc::new(Mutex::new(build_probe_http_service_with_config(
        RuntimeHttpConfig {
            supports_websocket: true,
            apns_worker: None,
        },
    )));
    let websocket_hub = AppCompatibleWebSocketHub::new();
    eprintln!("beepbeep-runtime smoke listening on {bind_addr}");
    serve_forever_with_websocket(&listener, service, websocket_hub)?;
    Ok(())
}
