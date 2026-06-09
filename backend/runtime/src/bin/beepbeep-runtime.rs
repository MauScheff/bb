use std::{
    net::{TcpListener, UdpSocket},
    sync::{Arc, Mutex},
    thread,
};

use turbo_runtime::{
    live::{LiveRuntimeConfig, build_live_http_service, build_live_websocket_hub},
    runtime_quic::{RuntimeQuicServerConfig, serve_forever_runtime_quic_control},
    runtime_tls::serve_forever_runtime_tls_control,
    server::{serve_forever_http, serve_forever_with_websocket},
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = LiveRuntimeConfig::from_env()?;
    let listener = TcpListener::bind(config.bind_addr)?;
    let service = Arc::new(Mutex::new(build_live_http_service(&config)?));
    eprintln!("beepbeep-runtime listening on {}", config.bind_addr);
    start_runtime_tls_control_if_configured(&config, service.clone())?;
    start_runtime_quic_control_if_configured(&config, service.clone())?;
    if config.websocket_compatibility_enabled {
        let websocket_hub = build_live_websocket_hub(&config)?;
        eprintln!("runtime WebSocket compatibility enabled");
        serve_forever_with_websocket(&listener, service, websocket_hub)?;
    } else {
        serve_forever_http(&listener, service)?;
    }
    Ok(())
}

fn start_runtime_tls_control_if_configured(
    config: &LiveRuntimeConfig,
    service: Arc<Mutex<turbo_runtime::live::LiveRuntimeHttpService>>,
) -> Result<(), Box<dyn std::error::Error>> {
    let Some(bind_addr) = config.runtime_tls_control_bind else {
        return Ok(());
    };
    let (cert_pem, key_pem) = runtime_control_cert_key(config)?;
    let server_config = Arc::new(turbo_runtime::runtime_tls::server_config(
        &cert_pem, &key_pem,
    )?);
    let listener = TcpListener::bind(bind_addr)?;
    eprintln!("runtime TLS control listening on {bind_addr}");
    thread::spawn(move || {
        if let Err(error) = serve_forever_runtime_tls_control(listener, server_config, service) {
            eprintln!("runtime TLS control listener stopped: {error}");
        }
    });
    Ok(())
}

fn start_runtime_quic_control_if_configured(
    config: &LiveRuntimeConfig,
    service: Arc<Mutex<turbo_runtime::live::LiveRuntimeHttpService>>,
) -> Result<(), Box<dyn std::error::Error>> {
    let Some(bind_addr) = config.runtime_quic_control_bind else {
        return Ok(());
    };
    let (cert_pem, key_pem) = runtime_control_cert_key(config)?;
    let quic_config = turbo_runtime::runtime_quic::server_config(
        &cert_pem,
        &key_pem,
        RuntimeQuicServerConfig {
            active_migration_enabled: std::env::var("BEEP_RUNTIME_QUIC_ACTIVE_MIGRATION_ENABLED")
                .map(|value| {
                    !matches!(
                        value.trim().to_ascii_lowercase().as_str(),
                        "0" | "false" | "no" | "off"
                    )
                })
                .unwrap_or(true),
            ..RuntimeQuicServerConfig::default()
        },
    )?;
    let socket = UdpSocket::bind(bind_addr)?;
    eprintln!("runtime QUIC control listening on {bind_addr}");
    thread::spawn(move || {
        if let Err(error) = serve_forever_runtime_quic_control(socket, quic_config, service) {
            eprintln!("runtime QUIC control listener stopped: {error}");
        }
    });
    Ok(())
}

fn runtime_control_cert_key(
    config: &LiveRuntimeConfig,
) -> Result<(std::path::PathBuf, std::path::PathBuf), Box<dyn std::error::Error>> {
    let cert_pem = config.runtime_control_cert_pem.clone().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "BEEP_RUNTIME_CONTROL_CERT_PEM is required when runtime QUIC/TLS control is enabled",
        )
    })?;
    let key_pem = config.runtime_control_key_pem.clone().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "BEEP_RUNTIME_CONTROL_KEY_PEM is required when runtime QUIC/TLS control is enabled",
        )
    })?;
    Ok((cert_pem, key_pem))
}
