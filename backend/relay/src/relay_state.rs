use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Instant,
};

use tokio::sync::Mutex;

use crate::metrics::RelayStateCounts;

#[derive(Clone)]
pub struct RelayState<Stream, Datagram> {
    pub sessions: Arc<Mutex<HashMap<String, RelaySession<Stream, Datagram>>>>,
    next_connection_id: Arc<AtomicU64>,
}

#[derive(Clone)]
pub struct RelaySession<Stream, Datagram> {
    pub peers: HashMap<String, RelayPeer<Stream, Datagram>>,
    pub expires_at: Instant,
}

#[derive(Clone)]
pub struct RelayPeer<Stream, Datagram> {
    pub peer_device_id: String,
    pub stream: Option<Stream>,
    pub datagram: Option<Datagram>,
    pub last_seen: Instant,
}

impl<Stream, Datagram> RelayPeer<Stream, Datagram> {
    pub fn is_empty(&self) -> bool {
        self.stream.is_none() && self.datagram.is_none()
    }
}

impl<Stream, Datagram> Default for RelayState<Stream, Datagram> {
    fn default() -> Self {
        Self::new()
    }
}

impl<Stream, Datagram> RelayState<Stream, Datagram> {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            next_connection_id: Arc::new(AtomicU64::new(1)),
        }
    }

    pub fn allocate_connection_id(&self) -> u64 {
        self.next_connection_id.fetch_add(1, Ordering::Relaxed)
    }

    pub async fn counts(&self) -> RelayStateCounts {
        let sessions = self.sessions.lock().await;
        let mut counts = RelayStateCounts {
            active_sessions: sessions.len(),
            ..RelayStateCounts::default()
        };

        for session in sessions.values() {
            counts.active_peers += session.peers.len();
            for peer in session.peers.values() {
                if peer.stream.is_some() {
                    counts.active_stream_paths += 1;
                }
                if peer.datagram.is_some() {
                    counts.active_datagram_paths += 1;
                }
            }
        }

        counts
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn allocates_monotonic_connection_ids_across_clones() {
        let state = RelayState::<(), ()>::new();
        let clone = state.clone();

        assert_eq!(state.allocate_connection_id(), 1);
        assert_eq!(clone.allocate_connection_id(), 2);
        assert_eq!(state.allocate_connection_id(), 3);
    }

    #[test]
    fn peer_empty_tracks_stream_and_datagram_paths() {
        let mut peer = RelayPeer::<u64, u64> {
            peer_device_id: "device-b".to_owned(),
            stream: None,
            datagram: None,
            last_seen: Instant::now(),
        };

        assert!(peer.is_empty());
        peer.stream = Some(1);
        assert!(!peer.is_empty());
        peer.stream = None;
        peer.datagram = Some(2);
        assert!(!peer.is_empty());
    }

    #[tokio::test]
    async fn session_map_is_shared_across_state_clones() {
        let state = RelayState::<(), ()>::new();
        let clone = state.clone();
        {
            let mut sessions = state.sessions.lock().await;
            sessions.insert(
                "session".to_owned(),
                RelaySession {
                    peers: HashMap::new(),
                    expires_at: Instant::now() + Duration::from_secs(60),
                },
            );
        }

        let sessions = clone.sessions.lock().await;

        assert!(sessions.contains_key("session"));
    }

    #[tokio::test]
    async fn counts_active_sessions_peers_and_paths() {
        let state = RelayState::<u64, u64>::new();
        {
            let mut sessions = state.sessions.lock().await;
            let mut peers = HashMap::new();
            peers.insert(
                "device-a".to_owned(),
                RelayPeer {
                    peer_device_id: "device-b".to_owned(),
                    stream: Some(1),
                    datagram: Some(2),
                    last_seen: Instant::now(),
                },
            );
            peers.insert(
                "device-b".to_owned(),
                RelayPeer {
                    peer_device_id: "device-a".to_owned(),
                    stream: None,
                    datagram: Some(3),
                    last_seen: Instant::now(),
                },
            );
            sessions.insert(
                "session".to_owned(),
                RelaySession {
                    peers,
                    expires_at: Instant::now() + Duration::from_secs(60),
                },
            );
        }

        assert_eq!(
            state.counts().await,
            RelayStateCounts {
                active_sessions: 1,
                active_peers: 2,
                active_stream_paths: 1,
                active_datagram_paths: 2,
            }
        );
    }
}
