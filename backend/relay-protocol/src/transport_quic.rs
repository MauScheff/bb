pub const MAX_RELAY_DATAGRAM_BUFFER_LENGTH: usize = 256 * 1024;
pub const QUIC_CONN_ID_LEN: usize = 16;
pub const QUIC_MAX_UDP_PAYLOAD_SIZE: usize = 1472;
pub const QUIC_OUT_BUF_LENGTH: usize = 64 * 1024;
pub const QUIC_STREAM_RECV_BUF_LENGTH: usize = 16 * 1024;
pub const QUIC_DGRAM_QUEUE_LENGTH: usize = MAX_RELAY_DATAGRAM_BUFFER_LENGTH / 1024;
pub const QUIC_ALPN: &[u8] = b"turbo-relay-v2";

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
}
