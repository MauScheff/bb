use serde::{Deserialize, Serialize};
use tokio_util::codec::LinesCodec;

pub const MAX_RELAY_LINE_LENGTH: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RelayTransport {
    Quic,
    QuicDatagram,
    TcpTls,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum RelayFrame {
    Join {
        session_id: String,
        device_id: String,
        peer_device_id: String,
        token: String,
    },
    JoinAck {
        session_id: String,
        device_id: String,
        transport: RelayTransport,
    },
    DatagramJoin {
        session_id: String,
        device_id: String,
        peer_device_id: String,
        token: String,
    },
    DatagramJoinAck {
        session_id: String,
        device_id: String,
        transport: RelayTransport,
    },
    PacketAudio {
        session_id: String,
        sender_device_id: String,
        sequence_number: u64,
        sent_at_ms: i64,
        payload: String,
    },
    TcpAudio {
        session_id: String,
        sender_device_id: String,
        sequence_number: u64,
        sent_at_ms: i64,
        payload: String,
    },
    Control {
        session_id: String,
        sender_device_id: String,
        kind: String,
        payload: String,
    },
    PeerUnavailable {
        session_id: String,
        device_id: String,
    },
    Error {
        message: String,
    },
}

pub fn relay_lines_codec() -> LinesCodec {
    LinesCodec::new_with_max_length(MAX_RELAY_LINE_LENGTH)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_join_frame_wire_shape() {
        let frame: RelayFrame = serde_json::from_str(
            r#"{"type":"join","session_id":"session","device_id":"device-a","peer_device_id":"device-b","token":"secret"}"#,
        )
        .expect("join frame should decode");

        assert!(matches!(
            frame,
            RelayFrame::Join {
                session_id,
                device_id,
                peer_device_id,
                token,
            } if session_id == "session"
                && device_id == "device-a"
                && peer_device_id == "device-b"
                && token == "secret"
        ));
    }

    #[test]
    fn rejects_malformed_frame_wire_shape() {
        let err = serde_json::from_str::<RelayFrame>(
            r#"{"type":"packet-audio","session_id":"session","sender_device_id":"device-a"}"#,
        )
        .expect_err("missing packet fields should fail");
        assert!(err.is_data() || err.is_syntax());
    }

    #[test]
    fn encodes_transport_names_as_stable_kebab_case() {
        let ack = RelayFrame::DatagramJoinAck {
            session_id: "session".to_owned(),
            device_id: "device-a".to_owned(),
            transport: RelayTransport::QuicDatagram,
        };

        let encoded = serde_json::to_string(&ack).expect("ack should encode");

        assert!(encoded.contains(r#""type":"datagram-join-ack""#));
        assert!(encoded.contains(r#""transport":"quic-datagram""#));
    }
}
