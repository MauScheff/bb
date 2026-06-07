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
    BinaryPacketAudio {
        session_id: String,
        sender_device_id: String,
        sequence_number: u64,
        sent_at_ms: i64,
        payload: Vec<u8>,
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

const BINARY_DATAGRAM_MAGIC: &[u8; 4] = b"TRD1";
const BINARY_DATAGRAM_VERSION: u8 = 1;
const BINARY_PACKET_AUDIO_TYPE: u8 = 1;
const BINARY_PACKET_AUDIO_HEADER_LEN: usize = 32;

pub fn parse_relay_datagram_frame(data: &[u8]) -> Result<RelayFrame, String> {
    if data.starts_with(BINARY_DATAGRAM_MAGIC) {
        return parse_binary_packet_audio(data);
    }
    serde_json::from_slice(data).map_err(|error| format!("datagram was not JSON: {error}"))
}

pub fn encode_binary_packet_audio_datagram(
    session_id: &str,
    sender_device_id: &str,
    sequence_number: u64,
    sent_at_ms: i64,
    payload: &[u8],
) -> Result<Vec<u8>, String> {
    let session = session_id.as_bytes();
    let sender = sender_device_id.as_bytes();
    if session.len() > u16::MAX as usize
        || sender.len() > u16::MAX as usize
        || payload.len() > u16::MAX as usize
    {
        return Err("binary packet audio field exceeded UInt16 length".to_owned());
    }
    let mut data =
        Vec::with_capacity(BINARY_PACKET_AUDIO_HEADER_LEN + session.len() + sender.len() + payload.len());
    data.extend_from_slice(BINARY_DATAGRAM_MAGIC);
    data.push(BINARY_DATAGRAM_VERSION);
    data.push(BINARY_PACKET_AUDIO_TYPE);
    data.extend_from_slice(&(BINARY_PACKET_AUDIO_HEADER_LEN as u16).to_be_bytes());
    data.extend_from_slice(&sequence_number.to_be_bytes());
    data.extend_from_slice(&sent_at_ms.to_be_bytes());
    data.extend_from_slice(&(session.len() as u16).to_be_bytes());
    data.extend_from_slice(&(sender.len() as u16).to_be_bytes());
    data.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    data.extend_from_slice(&[0, 0]);
    data.extend_from_slice(session);
    data.extend_from_slice(sender);
    data.extend_from_slice(payload);
    Ok(data)
}

fn parse_binary_packet_audio(data: &[u8]) -> Result<RelayFrame, String> {
    if data.len() < BINARY_PACKET_AUDIO_HEADER_LEN {
        return Err(format!("binary packet audio datagram too short: {}", data.len()));
    }
    let version = data[4];
    if version != BINARY_DATAGRAM_VERSION {
        return Err(format!("unsupported binary packet audio version: {version}"));
    }
    let frame_type = data[5];
    if frame_type != BINARY_PACKET_AUDIO_TYPE {
        return Err(format!("unsupported binary packet audio type: {frame_type}"));
    }
    let header_len = u16::from_be_bytes([data[6], data[7]]) as usize;
    if header_len != BINARY_PACKET_AUDIO_HEADER_LEN {
        return Err(format!("invalid binary packet audio header length: {header_len}"));
    }
    let sequence_number = u64::from_be_bytes(data[8..16].try_into().unwrap());
    let sent_at_ms = i64::from_be_bytes(data[16..24].try_into().unwrap());
    let session_len = u16::from_be_bytes([data[24], data[25]]) as usize;
    let sender_len = u16::from_be_bytes([data[26], data[27]]) as usize;
    let payload_len = u16::from_be_bytes([data[28], data[29]]) as usize;
    if data[30] != 0 || data[31] != 0 {
        return Err("binary packet audio reserved bytes must be zero".to_owned());
    }
    let expected_len = BINARY_PACKET_AUDIO_HEADER_LEN + session_len + sender_len + payload_len;
    if data.len() != expected_len {
        return Err(format!(
            "binary packet audio length mismatch: {} != {expected_len}",
            data.len()
        ));
    }
    let mut offset = BINARY_PACKET_AUDIO_HEADER_LEN;
    let session_id = std::str::from_utf8(&data[offset..offset + session_len])
        .map_err(|error| format!("binary packet audio session id was not UTF-8: {error}"))?
        .to_owned();
    offset += session_len;
    let sender_device_id = std::str::from_utf8(&data[offset..offset + sender_len])
        .map_err(|error| format!("binary packet audio sender device id was not UTF-8: {error}"))?
        .to_owned();
    offset += sender_len;
    let payload = data[offset..offset + payload_len].to_vec();
    Ok(RelayFrame::BinaryPacketAudio {
        session_id,
        sender_device_id,
        sequence_number,
        sent_at_ms,
        payload,
    })
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

    #[test]
    fn binary_packet_audio_datagram_round_trips() {
        let encoded = encode_binary_packet_audio_datagram(
            "session",
            "device-a",
            7,
            123_456,
            &[1, 2, 3, 4],
        )
        .expect("binary packet audio should encode");

        let decoded = parse_relay_datagram_frame(&encoded).expect("binary packet audio should decode");

        assert!(matches!(
            decoded,
            RelayFrame::BinaryPacketAudio {
                session_id,
                sender_device_id,
                sequence_number: 7,
                sent_at_ms: 123_456,
                payload,
            } if session_id == "session"
                && sender_device_id == "device-a"
                && payload == vec![1, 2, 3, 4]
        ));
    }

    #[test]
    fn relay_datagram_frame_parser_accepts_json_datagram_join() {
        let frame = parse_relay_datagram_frame(
            br#"{"type":"datagram-join","session_id":"session","device_id":"device-a","peer_device_id":"device-b","token":"secret"}"#,
        )
        .expect("json datagram join should decode");

        assert!(matches!(
            frame,
            RelayFrame::DatagramJoin {
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
}
