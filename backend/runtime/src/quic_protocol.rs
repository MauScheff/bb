use std::collections::{BTreeMap, BTreeSet};

use relay_protocol::{
    protocol::{MAX_RELAY_LINE_LENGTH, RelayFrame, RelayTransport},
    transport_quic::{QUIC_ALPN, QUIC_MAX_UDP_PAYLOAD_SIZE},
    transport_tcp::TCP_TLS_TRANSPORT_NAME,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MediaFrameRoute {
    pub session_id: String,
    pub sender_device_id: String,
    pub sequence_number: u64,
    pub sent_at_ms: i64,
    pub transport: RelayTransport,
    pub ordered: bool,
    pub payload: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MediaFrameAuthority {
    pub session_id: String,
    pub allowed_device_ids: BTreeSet<String>,
}

impl MediaFrameAuthority {
    pub fn new(
        session_id: impl Into<String>,
        allowed_device_ids: impl IntoIterator<Item = impl Into<String>>,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            allowed_device_ids: allowed_device_ids
                .into_iter()
                .map(Into::into)
                .collect::<BTreeSet<_>>(),
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct MediaFrameLedger {
    last_sequence_by_sender: BTreeMap<MediaFrameSequenceKey, u64>,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
struct MediaFrameSequenceKey {
    session_id: String,
    sender_device_id: String,
    transport: &'static str,
}

#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum QuicProtocolError {
    #[error("relay frame was malformed: {0}")]
    MalformedFrame(String),
    #[error("media frame field `{0}` is empty")]
    EmptyField(&'static str),
    #[error("media frame session `{observed}` did not match authorized session `{expected}`")]
    CrossSession { expected: String, observed: String },
    #[error("media sender `{0}` is not authorized for this session")]
    UnauthorizedSender(String),
    #[error(
        "media frame sequence {sequence_number} for `{sender_device_id}` on `{session_id}` was not newer than {last_sequence_number}"
    )]
    DuplicateOrStaleSequence {
        session_id: String,
        sender_device_id: String,
        sequence_number: u64,
        last_sequence_number: u64,
    },
    #[error("media payload length {observed} exceeds {limit}")]
    OversizedPayload { observed: usize, limit: usize },
}

pub fn runtime_quic_alpn() -> &'static [u8] {
    QUIC_ALPN
}

pub fn runtime_tcp_fallback_name() -> &'static str {
    TCP_TLS_TRANSPORT_NAME
}

pub fn route_media_frame(frame: &RelayFrame) -> Result<Option<MediaFrameRoute>, QuicProtocolError> {
    match frame {
        RelayFrame::PacketAudio {
            session_id,
            sender_device_id,
            sequence_number,
            sent_at_ms,
            payload,
        } => {
            ensure_payload_limit(payload, QUIC_MAX_UDP_PAYLOAD_SIZE)?;
            Ok(Some(MediaFrameRoute {
                session_id: session_id.clone(),
                sender_device_id: sender_device_id.clone(),
                sequence_number: *sequence_number,
                sent_at_ms: *sent_at_ms,
                transport: RelayTransport::QuicDatagram,
                ordered: false,
                payload: payload.clone(),
            }))
        }
        RelayFrame::TcpAudio {
            session_id,
            sender_device_id,
            sequence_number,
            sent_at_ms,
            payload,
        } => {
            ensure_payload_limit(payload, MAX_RELAY_LINE_LENGTH)?;
            Ok(Some(MediaFrameRoute {
                session_id: session_id.clone(),
                sender_device_id: sender_device_id.clone(),
                sequence_number: *sequence_number,
                sent_at_ms: *sent_at_ms,
                transport: RelayTransport::TcpTls,
                ordered: true,
                payload: payload.clone(),
            }))
        }
        _ => Ok(None),
    }
}

pub fn parse_relay_frame_json(text: &str) -> Result<RelayFrame, QuicProtocolError> {
    serde_json::from_str(text).map_err(|error| QuicProtocolError::MalformedFrame(error.to_string()))
}

pub fn route_authorized_media_frame(
    ledger: &mut MediaFrameLedger,
    authority: &MediaFrameAuthority,
    frame: &RelayFrame,
) -> Result<Option<MediaFrameRoute>, QuicProtocolError> {
    let Some(route) = route_media_frame(frame)? else {
        return Ok(None);
    };
    validate_non_empty("session_id", &route.session_id)?;
    validate_non_empty("sender_device_id", &route.sender_device_id)?;
    if route.session_id != authority.session_id {
        return Err(QuicProtocolError::CrossSession {
            expected: authority.session_id.clone(),
            observed: route.session_id,
        });
    }
    if !authority
        .allowed_device_ids
        .contains(&route.sender_device_id)
    {
        return Err(QuicProtocolError::UnauthorizedSender(
            route.sender_device_id,
        ));
    }
    ledger.record_newer_sequence(&route)?;
    Ok(Some(route))
}

impl MediaFrameLedger {
    fn record_newer_sequence(&mut self, route: &MediaFrameRoute) -> Result<(), QuicProtocolError> {
        let key = MediaFrameSequenceKey {
            session_id: route.session_id.clone(),
            sender_device_id: route.sender_device_id.clone(),
            transport: transport_key(route.transport),
        };
        if let Some(last_sequence_number) = self.last_sequence_by_sender.get(&key) {
            if route.sequence_number <= *last_sequence_number {
                return Err(QuicProtocolError::DuplicateOrStaleSequence {
                    session_id: route.session_id.clone(),
                    sender_device_id: route.sender_device_id.clone(),
                    sequence_number: route.sequence_number,
                    last_sequence_number: *last_sequence_number,
                });
            }
        }
        self.last_sequence_by_sender
            .insert(key, route.sequence_number);
        Ok(())
    }
}

fn ensure_payload_limit(payload: &str, limit: usize) -> Result<(), QuicProtocolError> {
    let observed = payload.len();
    if observed > limit {
        Err(QuicProtocolError::OversizedPayload { observed, limit })
    } else {
        Ok(())
    }
}

fn validate_non_empty(field: &'static str, value: &str) -> Result<(), QuicProtocolError> {
    if value.is_empty() {
        Err(QuicProtocolError::EmptyField(field))
    } else {
        Ok(())
    }
}

fn transport_key(transport: RelayTransport) -> &'static str {
    match transport {
        RelayTransport::Quic => "quic",
        RelayTransport::QuicDatagram => "quic-datagram",
        RelayTransport::TcpTls => "tcp-tls",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn authority() -> MediaFrameAuthority {
        MediaFrameAuthority::new("session-1", ["device-a", "device-b"])
    }

    #[test]
    fn quic_protocol_routes_packet_media_without_kernel_dependency() {
        let route = route_media_frame(&RelayFrame::PacketAudio {
            session_id: "session-1".to_owned(),
            sender_device_id: "device-a".to_owned(),
            sequence_number: 7,
            sent_at_ms: 42,
            payload: "voice-packet".to_owned(),
        })
        .expect("packet should route")
        .expect("packet audio should produce media route");

        assert_eq!(route.transport, RelayTransport::QuicDatagram);
        assert!(!route.ordered);
        assert_eq!(route.session_id, "session-1");
        assert_eq!(route.sequence_number, 7);
    }

    #[test]
    fn quic_protocol_preserves_tcp_tls_ordered_fallback() {
        let route = route_media_frame(&RelayFrame::TcpAudio {
            session_id: "session-1".to_owned(),
            sender_device_id: "device-a".to_owned(),
            sequence_number: 8,
            sent_at_ms: 43,
            payload: "voice-stream-chunk".to_owned(),
        })
        .expect("TCP audio should route")
        .expect("TCP audio should produce media route");

        assert_eq!(route.transport, RelayTransport::TcpTls);
        assert!(route.ordered);
        assert_eq!(runtime_tcp_fallback_name(), "tcp-tls");
    }

    #[test]
    fn quic_protocol_ignores_non_media_control_frames() {
        let route = route_media_frame(&RelayFrame::Control {
            session_id: "session-1".to_owned(),
            sender_device_id: "device-a".to_owned(),
            kind: "ping".to_owned(),
            payload: "{}".to_owned(),
        })
        .expect("control frame should parse");

        assert!(route.is_none());
    }

    #[test]
    fn quic_protocol_rejects_oversized_datagram_payload() {
        let payload = "x".repeat(QUIC_MAX_UDP_PAYLOAD_SIZE + 1);

        let err = route_media_frame(&RelayFrame::PacketAudio {
            session_id: "session-1".to_owned(),
            sender_device_id: "device-a".to_owned(),
            sequence_number: 1,
            sent_at_ms: 42,
            payload,
        })
        .expect_err("oversized packet should be rejected before relay routing");

        assert_eq!(
            err,
            QuicProtocolError::OversizedPayload {
                observed: QUIC_MAX_UDP_PAYLOAD_SIZE + 1,
                limit: QUIC_MAX_UDP_PAYLOAD_SIZE
            }
        );
    }

    #[test]
    fn quic_protocol_rejects_malformed_frame_json() {
        let err = parse_relay_frame_json(
            r#"{"type":"packet-audio","session_id":"session-1","sender_device_id":"device-a"}"#,
        )
        .expect_err("missing sequence and payload fields should fail");

        assert!(matches!(err, QuicProtocolError::MalformedFrame(_)));
    }

    #[test]
    fn quic_protocol_rejects_cross_session_media_frames() {
        let mut ledger = MediaFrameLedger::default();
        let err = route_authorized_media_frame(
            &mut ledger,
            &authority(),
            &RelayFrame::PacketAudio {
                session_id: "session-other".to_owned(),
                sender_device_id: "device-a".to_owned(),
                sequence_number: 1,
                sent_at_ms: 42,
                payload: "voice-packet".to_owned(),
            },
        )
        .expect_err("cross-session frame should fail closed");

        assert_eq!(
            err,
            QuicProtocolError::CrossSession {
                expected: "session-1".to_owned(),
                observed: "session-other".to_owned()
            }
        );
    }

    #[test]
    fn quic_protocol_rejects_unauthorized_sender_device() {
        let mut ledger = MediaFrameLedger::default();
        let err = route_authorized_media_frame(
            &mut ledger,
            &authority(),
            &RelayFrame::PacketAudio {
                session_id: "session-1".to_owned(),
                sender_device_id: "device-c".to_owned(),
                sequence_number: 1,
                sent_at_ms: 42,
                payload: "voice-packet".to_owned(),
            },
        )
        .expect_err("unauthorized sender should fail closed");

        assert_eq!(
            err,
            QuicProtocolError::UnauthorizedSender("device-c".to_owned())
        );
    }

    #[test]
    fn quic_protocol_rejects_duplicate_and_stale_packet_sequences() {
        let mut ledger = MediaFrameLedger::default();
        route_authorized_media_frame(
            &mut ledger,
            &authority(),
            &RelayFrame::PacketAudio {
                session_id: "session-1".to_owned(),
                sender_device_id: "device-a".to_owned(),
                sequence_number: 7,
                sent_at_ms: 42,
                payload: "voice-packet".to_owned(),
            },
        )
        .expect("first packet should route");

        let duplicate = route_authorized_media_frame(
            &mut ledger,
            &authority(),
            &RelayFrame::PacketAudio {
                session_id: "session-1".to_owned(),
                sender_device_id: "device-a".to_owned(),
                sequence_number: 7,
                sent_at_ms: 43,
                payload: "voice-packet".to_owned(),
            },
        )
        .expect_err("duplicate packet should fail closed");
        let stale = route_authorized_media_frame(
            &mut ledger,
            &authority(),
            &RelayFrame::PacketAudio {
                session_id: "session-1".to_owned(),
                sender_device_id: "device-a".to_owned(),
                sequence_number: 6,
                sent_at_ms: 44,
                payload: "voice-packet".to_owned(),
            },
        )
        .expect_err("stale packet should fail closed");

        assert_eq!(
            duplicate,
            QuicProtocolError::DuplicateOrStaleSequence {
                session_id: "session-1".to_owned(),
                sender_device_id: "device-a".to_owned(),
                sequence_number: 7,
                last_sequence_number: 7
            }
        );
        assert_eq!(
            stale,
            QuicProtocolError::DuplicateOrStaleSequence {
                session_id: "session-1".to_owned(),
                sender_device_id: "device-a".to_owned(),
                sequence_number: 6,
                last_sequence_number: 7
            }
        );
    }

    #[test]
    fn quic_protocol_tracks_packet_and_tcp_sequences_separately() {
        let mut ledger = MediaFrameLedger::default();
        route_authorized_media_frame(
            &mut ledger,
            &authority(),
            &RelayFrame::PacketAudio {
                session_id: "session-1".to_owned(),
                sender_device_id: "device-a".to_owned(),
                sequence_number: 7,
                sent_at_ms: 42,
                payload: "voice-packet".to_owned(),
            },
        )
        .expect("packet lane should route");
        let tcp = route_authorized_media_frame(
            &mut ledger,
            &authority(),
            &RelayFrame::TcpAudio {
                session_id: "session-1".to_owned(),
                sender_device_id: "device-a".to_owned(),
                sequence_number: 7,
                sent_at_ms: 42,
                payload: "voice-stream".to_owned(),
            },
        )
        .expect("tcp fallback lane should keep its own ordering")
        .expect("tcp media should route");

        assert_eq!(tcp.transport, RelayTransport::TcpTls);
        assert!(tcp.ordered);
    }

    #[test]
    fn quic_protocol_rejects_empty_media_identity_fields() {
        let mut ledger = MediaFrameLedger::default();
        let err = route_authorized_media_frame(
            &mut ledger,
            &authority(),
            &RelayFrame::PacketAudio {
                session_id: String::new(),
                sender_device_id: "device-a".to_owned(),
                sequence_number: 1,
                sent_at_ms: 42,
                payload: "voice-packet".to_owned(),
            },
        )
        .expect_err("empty session id should fail closed");

        assert_eq!(err, QuicProtocolError::EmptyField("session_id"));
    }

    #[test]
    fn quic_protocol_uses_stable_relay_alpn() {
        assert_eq!(runtime_quic_alpn(), b"turbo-relay-v2");
    }
}
