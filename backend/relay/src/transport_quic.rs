use std::path::Path;

use anyhow::{Context, Result, anyhow};
pub use relay_protocol::transport_quic::{
    MAX_RELAY_DATAGRAM_BUFFER_LENGTH, QUIC_ALPN, QUIC_CONN_ID_LEN, QUIC_DGRAM_QUEUE_LENGTH,
    QUIC_MAX_UDP_PAYLOAD_SIZE, QUIC_OUT_BUF_LENGTH, QUIC_STREAM_RECV_BUF_LENGTH,
};

pub fn server_config(
    cert_pem: &Path,
    key_pem: &Path,
    active_migration_enabled: bool,
) -> Result<quiche::Config> {
    let mut quic_config =
        quiche::Config::new(quiche::PROTOCOL_VERSION).context("invalid QUIC version")?;
    quic_config
        .load_cert_chain_from_pem_file(path_as_utf8(cert_pem, "relay cert")?)
        .context("invalid relay certificate")?;
    quic_config
        .load_priv_key_from_pem_file(path_as_utf8(key_pem, "relay key")?)
        .context("invalid relay private key")?;
    quic_config
        .set_application_protos(&[QUIC_ALPN])
        .context("failed to configure relay QUIC ALPN")?;
    quic_config.set_max_idle_timeout(120_000);
    quic_config.set_max_recv_udp_payload_size(QUIC_MAX_UDP_PAYLOAD_SIZE);
    quic_config.set_max_send_udp_payload_size(QUIC_MAX_UDP_PAYLOAD_SIZE);
    quic_config.set_initial_max_data(10_000_000);
    quic_config.set_initial_max_stream_data_bidi_local(1_000_000);
    quic_config.set_initial_max_stream_data_bidi_remote(1_000_000);
    quic_config.set_initial_max_stream_data_uni(1_000_000);
    quic_config.set_initial_max_streams_bidi(100);
    quic_config.set_initial_max_streams_uni(100);
    quic_config.set_disable_active_migration(disable_active_migration(active_migration_enabled));
    quic_config.enable_dgram(true, QUIC_DGRAM_QUEUE_LENGTH, QUIC_DGRAM_QUEUE_LENGTH);
    Ok(quic_config)
}

pub fn disable_active_migration(active_migration_enabled: bool) -> bool {
    !active_migration_enabled
}

fn path_as_utf8<'a>(path: &'a Path, label: &str) -> Result<&'a str> {
    path.to_str()
        .ok_or_else(|| anyhow!("{label} path was not valid UTF-8"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn datagram_queue_length_tracks_buffer_size() {
        assert_eq!(
            QUIC_DGRAM_QUEUE_LENGTH,
            MAX_RELAY_DATAGRAM_BUFFER_LENGTH / 1024
        );
        assert!(QUIC_DGRAM_QUEUE_LENGTH > 0);
    }

    #[test]
    fn quic_alpn_is_stable() {
        assert_eq!(QUIC_ALPN, b"turbo-relay-v2");
    }

    #[test]
    fn active_migration_config_maps_to_quiche_disable_flag() {
        assert!(!disable_active_migration(true));
        assert!(disable_active_migration(false));
    }
}
