use std::{
    net::TcpListener,
    sync::{Arc, Mutex},
};

use turbo_runtime::{
    live::{LiveRuntimeConfig, build_live_http_service, build_live_websocket_hub},
    server::serve_forever_with_websocket,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = LiveRuntimeConfig::from_env()?;
    let listener = TcpListener::bind(config.bind_addr)?;
    let service = Arc::new(Mutex::new(build_live_http_service(&config)?));
    let websocket_hub = build_live_websocket_hub(&config)?;
    eprintln!("beepbeep-runtime listening on {}", config.bind_addr);
    serve_forever_with_websocket(&listener, service, websocket_hub)?;
    Ok(())
}
