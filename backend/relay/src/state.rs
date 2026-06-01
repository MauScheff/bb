use crate::protocol::RelayFrame;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct JoinedPeer {
    pub session_id: String,
    pub device_id: String,
    pub peer_device_id: String,
    pub connection_id: u64,
}

impl JoinedPeer {
    pub fn new(
        session_id: String,
        device_id: String,
        peer_device_id: String,
        connection_id: u64,
    ) -> Self {
        Self {
            session_id,
            device_id,
            peer_device_id,
            connection_id,
        }
    }

    pub fn owns_connection(&self, connection_id: u64) -> bool {
        self.connection_id == connection_id
    }

    pub fn matches_sender(&self, session_id: &str, sender_device_id: &str) -> bool {
        self.session_id == session_id && self.device_id == sender_device_id
    }

    pub fn matches_datagram_join(&self, frame: &RelayFrame) -> bool {
        matches!(
            frame,
            RelayFrame::DatagramJoin {
                session_id,
                device_id,
                peer_device_id,
                ..
            } if session_id == &self.session_id
                && device_id == &self.device_id
                && peer_device_id == &self.peer_device_id
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joined_peer_matches_own_sender_identity() {
        let joined = JoinedPeer::new(
            "session".to_owned(),
            "device-a".to_owned(),
            "device-b".to_owned(),
            7,
        );

        assert!(joined.matches_sender("session", "device-a"));
        assert!(!joined.matches_sender("session", "device-b"));
        assert!(!joined.matches_sender("other-session", "device-a"));
    }

    #[test]
    fn joined_peer_matches_duplicate_datagram_join_for_reack() {
        let joined = JoinedPeer::new(
            "session".to_owned(),
            "device-a".to_owned(),
            "device-b".to_owned(),
            7,
        );
        let duplicate = RelayFrame::DatagramJoin {
            session_id: "session".to_owned(),
            device_id: "device-a".to_owned(),
            peer_device_id: "device-b".to_owned(),
            token: "secret".to_owned(),
        };
        let other = RelayFrame::DatagramJoin {
            session_id: "session".to_owned(),
            device_id: "device-c".to_owned(),
            peer_device_id: "device-b".to_owned(),
            token: "secret".to_owned(),
        };

        assert!(joined.matches_datagram_join(&duplicate));
        assert!(!joined.matches_datagram_join(&other));
    }

    #[test]
    fn joined_peer_owns_only_the_same_connection_id() {
        let joined = JoinedPeer::new(
            "session".to_owned(),
            "device-a".to_owned(),
            "device-b".to_owned(),
            7,
        );

        assert!(joined.owns_connection(7));
        assert!(!joined.owns_connection(8));
    }
}
