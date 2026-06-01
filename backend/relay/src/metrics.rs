use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct RelayStateCounts {
    pub active_sessions: usize,
    pub active_peers: usize,
    pub active_stream_paths: usize,
    pub active_datagram_paths: usize,
}

#[derive(Debug, Default)]
pub struct RelayCounters {
    accepted_joins: AtomicU64,
    rejected_joins: AtomicU64,
    forwarded_frames: AtomicU64,
    dropped_frames: AtomicU64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct RelayCounterSnapshot {
    pub accepted_joins: u64,
    pub rejected_joins: u64,
    pub forwarded_frames: u64,
    pub dropped_frames: u64,
}

impl RelayCounters {
    pub fn record_accepted_join(&self) {
        self.accepted_joins.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_rejected_join(&self) {
        self.rejected_joins.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_forwarded_frame(&self) {
        self.forwarded_frames.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_dropped_frame(&self) {
        self.dropped_frames.fetch_add(1, Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> RelayCounterSnapshot {
        RelayCounterSnapshot {
            accepted_joins: self.accepted_joins.load(Ordering::Relaxed),
            rejected_joins: self.rejected_joins.load(Ordering::Relaxed),
            forwarded_frames: self.forwarded_frames.load(Ordering::Relaxed),
            dropped_frames: self.dropped_frames.load(Ordering::Relaxed),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counters_snapshot_observes_recorded_events() {
        let counters = RelayCounters::default();

        counters.record_accepted_join();
        counters.record_rejected_join();
        counters.record_forwarded_frame();
        counters.record_forwarded_frame();
        counters.record_dropped_frame();

        assert_eq!(
            counters.snapshot(),
            RelayCounterSnapshot {
                accepted_joins: 1,
                rejected_joins: 1,
                forwarded_frames: 2,
                dropped_frames: 1,
            }
        );
    }
}
