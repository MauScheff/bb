use std::sync::{Arc, Mutex};

use postgres::Client;

use crate::websocket::{WebSocketAuthorizationDecision, WebSocketAuthorizationFact};

pub trait WebSocketAuthorizationFactSink: Send + Sync {
    fn record_authorization_fact(
        &self,
        fact: &WebSocketAuthorizationFact,
    ) -> Result<(), WebSocketAuthorizationFactSinkError>;
}

#[derive(Debug, thiserror::Error)]
pub enum WebSocketAuthorizationFactSinkError {
    #[error("session epoch `{0}` is too large for durable storage")]
    SessionEpochOutOfRange(u64),
    #[error("failed to write websocket authorization fact to Postgres: {0}")]
    Postgres(#[from] postgres::Error),
}

#[derive(Clone, Default)]
pub struct NoopWebSocketAuthorizationFactSink;

impl WebSocketAuthorizationFactSink for NoopWebSocketAuthorizationFactSink {
    fn record_authorization_fact(
        &self,
        _fact: &WebSocketAuthorizationFact,
    ) -> Result<(), WebSocketAuthorizationFactSinkError> {
        Ok(())
    }
}

#[derive(Clone, Default)]
pub struct InMemoryWebSocketAuthorizationFactSink {
    facts: Arc<Mutex<Vec<WebSocketAuthorizationFact>>>,
}

impl InMemoryWebSocketAuthorizationFactSink {
    pub fn facts(&self) -> Vec<WebSocketAuthorizationFact> {
        self.facts
            .lock()
            .expect("websocket authorization fact sink lock should not be poisoned")
            .clone()
    }
}

impl WebSocketAuthorizationFactSink for InMemoryWebSocketAuthorizationFactSink {
    fn record_authorization_fact(
        &self,
        fact: &WebSocketAuthorizationFact,
    ) -> Result<(), WebSocketAuthorizationFactSinkError> {
        self.facts
            .lock()
            .expect("websocket authorization fact sink lock should not be poisoned")
            .push(fact.clone());
        Ok(())
    }
}

pub struct PostgresWebSocketAuthorizationFactSink {
    client: Mutex<Client>,
}

impl PostgresWebSocketAuthorizationFactSink {
    pub fn new(client: Client) -> Self {
        Self {
            client: Mutex::new(client),
        }
    }
}

impl WebSocketAuthorizationFactSink for PostgresWebSocketAuthorizationFactSink {
    fn record_authorization_fact(
        &self,
        fact: &WebSocketAuthorizationFact,
    ) -> Result<(), WebSocketAuthorizationFactSinkError> {
        let session_epoch = i64::try_from(fact.session_epoch).map_err(|_| {
            WebSocketAuthorizationFactSinkError::SessionEpochOutOfRange(fact.session_epoch)
        })?;
        let decision = authorization_decision_label(&fact.decision);
        self.client
            .lock()
            .expect("Postgres websocket authorization fact sink lock should not be poisoned")
            .execute(
                "insert into runtime_websocket_authorization_facts (
                    connection_id,
                    conversation_id,
                    participant_id,
                    device_id,
                    session_epoch,
                    decision,
                    reason
                ) values ($1, $2, $3, $4, $5, $6, $7)",
                &[
                    &fact.connection_id,
                    &fact.conversation_id,
                    &fact.participant_id,
                    &fact.device_id,
                    &session_epoch,
                    &decision,
                    &fact.reason,
                ],
            )?;
        Ok(())
    }
}

fn authorization_decision_label(decision: &WebSocketAuthorizationDecision) -> &'static str {
    match decision {
        WebSocketAuthorizationDecision::Accepted => "accepted",
        WebSocketAuthorizationDecision::Rejected => "rejected",
    }
}
