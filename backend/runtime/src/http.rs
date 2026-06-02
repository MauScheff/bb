use std::{
    collections::{BTreeMap, BTreeSet},
    env,
    io::{Read, Write},
    net::TcpListener,
    sync::Mutex,
    time::Duration,
    time::{SystemTime, UNIX_EPOCH},
};

use serde_json::Value;

use crate::{
    postgres::{
        DurableBeepThread, DurableBeepThreadStore, DurableContactStore, DurablePostgresError,
        KernelDecisionCommitter, RequestTalkTurnKernelWorker, RequestTalkTurnSnapshotLoader,
        TalkTurnReleaseCommitter, TalkTurnRenewalCommitter,
    },
    routes::{RuntimeRouteError, SelfHostedRouteService},
    shadow::LegacyBeginTransmitInput,
};

const APP_COMPATIBLE_TRANSMIT_LEASE_MS: u64 = 12_000;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HttpRequest {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Value,
}

#[derive(Debug, thiserror::Error)]
pub enum RuntimeHttpError {
    #[error("malformed HTTP request")]
    MalformedRequest,
    #[error("missing Content-Length header")]
    MissingContentLength,
    #[error("invalid Content-Length header")]
    InvalidContentLength,
    #[error("request body was not valid JSON: {0}")]
    InvalidJson(#[source] serde_json::Error),
    #[error("missing field `{0}`")]
    MissingField(&'static str),
    #[error("durable store failed: {0}")]
    Durable(#[from] DurablePostgresError),
    #[error("route failed: {0}")]
    Route(#[from] RuntimeRouteError),
    #[error("io failed: {0}")]
    Io(#[from] std::io::Error),
}

pub struct RuntimeHttpService<S, W, C = crate::postgres::DurableConversationStore> {
    route_service: SelfHostedRouteService<S, W, C>,
    runtime_config: RuntimeHttpConfig,
    state: RuntimeHttpState,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RuntimeHttpConfig {
    pub supports_websocket: bool,
    pub supports_direct_quic_upgrade: bool,
    pub supports_direct_quic_provisioning: bool,
    pub supports_media_end_to_end_encryption: bool,
    pub apns_worker: Option<RuntimeApnsWorkerConfig>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeApnsWorkerConfig {
    pub base_url: String,
    pub secret: String,
    pub bundle_id: String,
    pub use_sandbox: bool,
    pub timeout_ms: u64,
}

impl RuntimeHttpConfig {
    pub fn live_from_env() -> Self {
        Self {
            supports_websocket: true,
            supports_direct_quic_upgrade: env_flag_default_true(
                "BEEP_RUNTIME_SUPPORTS_DIRECT_QUIC_UPGRADE",
            ),
            supports_direct_quic_provisioning: env_flag_default_true(
                "BEEP_RUNTIME_SUPPORTS_DIRECT_QUIC_PROVISIONING",
            ),
            supports_media_end_to_end_encryption: env_flag_default_false(
                "BEEP_RUNTIME_SUPPORTS_MEDIA_E2EE",
            ),
            apns_worker: RuntimeApnsWorkerConfig::from_env(),
        }
    }
}

fn env_flag_default_true(name: &str) -> bool {
    match env::var(name) {
        Ok(value) => !matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "0" | "false" | "no" | "off"
        ),
        Err(_) => true,
    }
}

fn env_flag_default_false(name: &str) -> bool {
    match env::var(name) {
        Ok(value) => matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "yes" | "on"
        ),
        Err(_) => false,
    }
}

impl RuntimeApnsWorkerConfig {
    fn from_env() -> Option<Self> {
        let base_url = env::var("TURBO_APNS_WORKER_BASE_URL")
            .ok()?
            .trim()
            .to_owned();
        let secret = env::var("TURBO_APNS_WORKER_SECRET").ok()?.trim().to_owned();
        if base_url.is_empty() || secret.is_empty() {
            return None;
        }
        Some(Self {
            base_url,
            secret,
            bundle_id: env::var("TURBO_APNS_BUNDLE_ID")
                .or_else(|_| env::var("TURBO_APNS_DEFAULT_BUNDLE_ID"))
                .unwrap_or_else(|_| "com.rounded.Turbo".to_owned()),
            use_sandbox: env::var("TURBO_APNS_USE_SANDBOX")
                .or_else(|_| env::var("TURBO_APNS_DEFAULT_USE_SANDBOX"))
                .map(|value| parse_env_bool(&value))
                .unwrap_or(true),
            timeout_ms: env::var("TURBO_APNS_WORKER_TIMEOUT_MS")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(1_500),
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct RuntimeHttpState {
    channels: BTreeMap<String, RuntimeChannel>,
    direct_quic_identities_by_device: BTreeMap<String, Value>,
    presence_by_handle: BTreeMap<String, RuntimePresence>,
    diagnostics_by_device: BTreeMap<String, Value>,
    wake_events: Vec<Value>,
    invariant_events: Vec<Value>,
    next_transmit_id: u64,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct RuntimeChannel {
    participants_by_handle: BTreeMap<String, String>,
    joined_devices_by_handle: BTreeMap<String, String>,
    ephemeral_tokens_by_handle: BTreeMap<String, RuntimeEphemeralToken>,
    wake_disconnected_handles: BTreeSet<String>,
    active_transmit_id: Option<String>,
    active_transmitter_handle: Option<String>,
    active_transmit_expires_at_ms: Option<u128>,
    last_transmitter_handle: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct RuntimeEphemeralToken {
    device_id: String,
    token: String,
    apns_environment: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct RuntimePresence {
    status: String,
    device_id: Option<String>,
}

struct AppPttPushRequest<'a> {
    event: &'a str,
    channel_id: &'a str,
    sender_handle: &'a str,
    sender_user_id: &'a str,
    sender_device_id: &'a str,
    target_handle: &'a str,
    target_device_id: &'a str,
    target_token: &'a str,
    target_apns_environment: Option<&'a str>,
    attempt_id: &'a str,
    started_at: &'a str,
}

impl<S, W, C> RuntimeHttpService<S, W, C>
where
    S: RequestTalkTurnSnapshotLoader,
    W: RequestTalkTurnKernelWorker,
    C: KernelDecisionCommitter
        + TalkTurnRenewalCommitter
        + TalkTurnReleaseCommitter
        + DurableContactStore
        + DurableBeepThreadStore,
{
    pub fn new(route_service: SelfHostedRouteService<S, W, C>) -> Self {
        Self {
            route_service,
            runtime_config: RuntimeHttpConfig::default(),
            state: RuntimeHttpState::default(),
        }
    }

    pub fn new_with_config(
        route_service: SelfHostedRouteService<S, W, C>,
        runtime_config: RuntimeHttpConfig,
    ) -> Self {
        Self {
            route_service,
            runtime_config,
            state: RuntimeHttpState::default(),
        }
    }

    pub fn route_service(&self) -> &SelfHostedRouteService<S, W, C> {
        &self.route_service
    }

    pub fn observe_app_compatible_control_command(
        &mut self,
        command_kind: &str,
        participant_id: &str,
        device_id: &str,
        channel_id: Option<&str>,
        payload: Option<&str>,
    ) {
        let Some(channel_id) = channel_id else { return };
        let handle = handle_for_user_id(participant_id);
        match command_kind {
            "join-channel" => self.join_channel(channel_id, &handle, device_id),
            "leave-channel" => self.leave_channel(channel_id, &handle, Some(device_id)),
            "receiver-ready" => {
                self.record_presence(&handle, "online", Some(device_id.to_owned()));
                if !self.channel_has_pending_beep(channel_id).unwrap_or(true) {
                    self.join_channel(channel_id, &handle, device_id);
                    self.clear_channel_wake_disconnect(channel_id, &handle);
                }
            }
            "receiver-not-ready" => {
                if payload.is_some_and(|payload| payload.contains("app-background-media-closed")) {
                    self.record_presence(&handle, "background", Some(device_id.to_owned()));
                    self.mark_channel_wake_disconnected(channel_id, &handle, device_id);
                }
            }
            _ => {}
        }
    }

    pub fn observe_app_compatible_websocket_connected(
        &mut self,
        participant_id: &str,
        device_id: &str,
        _channel_id: &str,
    ) {
        let handle = handle_for_user_id(participant_id);
        let normalized_handle = normalize_handle(&handle);
        self.record_presence(&normalized_handle, "online", Some(device_id.to_owned()));
        self.clear_joined_handle_wake_disconnect(&normalized_handle, device_id);
    }

    pub fn observe_app_compatible_websocket_disconnected(
        &mut self,
        participant_id: &str,
        device_id: &str,
        _channel_id: &str,
    ) {
        let handle = handle_for_user_id(participant_id);
        let normalized_handle = normalize_handle(&handle);
        self.record_presence(&normalized_handle, "background", Some(device_id.to_owned()));
        self.mark_joined_handle_wake_disconnected(&normalized_handle, device_id);
    }

    fn clear_joined_handle_wake_disconnect(&mut self, handle: &str, device_id: &str) {
        let normalized_handle = normalize_handle(handle);
        for channel in self.state.channels.values_mut() {
            if channel
                .joined_devices_by_handle
                .get(&normalized_handle)
                .is_some_and(|joined_device_id| joined_device_id == device_id)
            {
                channel.wake_disconnected_handles.remove(&normalized_handle);
            }
        }
    }

    fn mark_joined_handle_wake_disconnected(&mut self, handle: &str, device_id: &str) {
        let normalized_handle = normalize_handle(handle);
        for channel in self.state.channels.values_mut() {
            if channel
                .joined_devices_by_handle
                .get(&normalized_handle)
                .is_some_and(|joined_device_id| joined_device_id == device_id)
            {
                channel
                    .wake_disconnected_handles
                    .insert(normalized_handle.clone());
                if channel.active_transmitter_handle.as_ref() == Some(&normalized_handle) {
                    channel.active_transmit_id = None;
                    channel.active_transmitter_handle = None;
                    channel.active_transmit_expires_at_ms = None;
                }
            }
        }
    }

    pub fn handle(&mut self, request: HttpRequest) -> HttpResponse {
        match self.handle_result(request) {
            Ok(response) => response,
            Err(error) => error_response(status_for_error(&error), error.to_string()),
        }
    }

    fn handle_result(&mut self, request: HttpRequest) -> Result<HttpResponse, RuntimeHttpError> {
        if request.method == "GET" && is_health_path(&request.path) {
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "status": "ok",
                    "service": "beepbeep-runtime",
                    "runtime": "self-hosted",
                    "supportsWebSocket": self.runtime_config.supports_websocket
                }),
            });
        }
        if request.method == "GET" && is_apple_app_site_association_path(&request.path) {
            return Ok(HttpResponse {
                status: 200,
                body: apple_app_site_association_response(),
            });
        }
        self.clear_expired_app_transmits();
        if request.method == "GET" && is_config_path(&request.path) {
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "mode": "self-hosted",
                    "supportsWebSocket": self.runtime_config.supports_websocket,
                    "telemetryEnabled": true,
                    "supportsDirectQuicUpgrade": self.runtime_config.supports_direct_quic_upgrade,
                    "supportsDirectQuicProvisioning": self.runtime_config.supports_direct_quic_provisioning,
                    "supportsMediaEndToEndEncryption": self.runtime_config.supports_media_end_to_end_encryption,
                    "supportsSignalSessionIds": true,
                    "supportsTransmitIds": true,
                    "supportsProjectionEpochs": true
                }),
            });
        }
        if request.method == "GET" {
            if let Some(direction) = beeps_list_direction(&request.path) {
                let handle = request_handle(&request);
                let beeps = self.beeps_for_handle(handle, direction)?;
                return Ok(HttpResponse {
                    status: 200,
                    body: Value::Array(beeps),
                });
            }
        }
        if request.method == "GET" && is_beeps_list_path(&request.path) {
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!([]),
            });
        }
        if request.method == "GET" && is_contact_summaries_path(&request.path) {
            let handle = request_handle(&request);
            return Ok(HttpResponse {
                status: 200,
                body: Value::Array(self.contact_summaries_for_handle(handle)?),
            });
        }
        if request.method == "GET" {
            if let Some(device_id) = latest_diagnostics_device_id(&request.path) {
                let device_id = normalize_path_token(device_id);
                let Some(report) = self.state.diagnostics_by_device.get(&device_id) else {
                    return Ok(error_response(404, "not found"));
                };
                return Ok(HttpResponse {
                    status: 200,
                    body: serde_json::json!({
                        "status": "ok",
                        "report": report
                    }),
                });
            }
            if is_latest_diagnostics_path(&request.path) {
                let Some(report) = self.state.diagnostics_by_device.values().next_back() else {
                    return Ok(error_response(404, "not found"));
                };
                return Ok(HttpResponse {
                    status: 200,
                    body: serde_json::json!({
                        "status": "ok",
                        "report": report
                    }),
                });
            }
            if is_wake_events_recent_path(&request.path) {
                return Ok(HttpResponse {
                    status: 200,
                    body: serde_json::json!({
                        "status": "ok",
                        "events": self.state.wake_events.clone()
                    }),
                });
            }
            if is_invariant_events_recent_path(&request.path) {
                return Ok(HttpResponse {
                    status: 200,
                    body: serde_json::json!({
                        "status": "ok",
                        "events": self.state.invariant_events.clone()
                    }),
                });
            }
            if let Some(public_id) = did_document_public_id(&request.path) {
                let handle = normalize_identity_reference(public_id);
                return Ok(HttpResponse {
                    status: 200,
                    body: did_document_response(&handle, &request_public_base_url(&request)),
                });
            }
            if let Some(public_id) = share_page_public_id(&request.path) {
                let handle = normalize_identity_reference(&public_id);
                let profile_name = self
                    .route_service
                    .committer_mut()
                    .profile_name(&handle)?
                    .unwrap_or_else(|| handle.clone());
                return Ok(HttpResponse {
                    status: 200,
                    body: raw_html_response(share_page_html(
                        &handle,
                        &profile_name,
                        &request_public_base_url(&request),
                    )),
                });
            }
            if let Some(handle) = user_presence_handle(&request.path) {
                let handle = normalize_identity_reference(handle);
                let profile_name = self
                    .route_service
                    .committer_mut()
                    .profile_name(&handle)?
                    .unwrap_or_else(|| handle.clone());
                return Ok(HttpResponse {
                    status: 200,
                    body: user_lookup_response(
                        &handle,
                        &profile_name,
                        self.handle_is_online(&handle),
                        &request_public_base_url(&request),
                    ),
                });
            }
            if let Some(handle) = user_lookup_handle(&request.path) {
                let handle = normalize_identity_reference(handle);
                let profile_name = self
                    .route_service
                    .committer_mut()
                    .profile_name(&handle)?
                    .unwrap_or_else(|| handle.clone());
                return Ok(HttpResponse {
                    status: 200,
                    body: user_lookup_response(
                        &handle,
                        &profile_name,
                        self.handle_is_online(&handle),
                        &request_public_base_url(&request),
                    ),
                });
            }
            if let Some((channel_id, _device_id)) = channel_state_path(&request.path) {
                let handle = request_handle(&request);
                return Ok(HttpResponse {
                    status: 200,
                    body: self.channel_state_response(channel_id, handle)?,
                });
            }
            if let Some((channel_id, _device_id)) = channel_readiness_path(&request.path) {
                let handle = request_handle(&request);
                return Ok(HttpResponse {
                    status: 200,
                    body: self.channel_readiness_response(channel_id, handle)?,
                });
            }
        }
        if request.method != "POST" {
            return Ok(error_response(405, "method not allowed"));
        }
        let body = parse_body(&request.body)?;
        if is_auth_session_path(&request.path) {
            let handle = normalize_identity_reference(request_handle(&request));
            let profile_name = self
                .route_service
                .committer_mut()
                .profile_name(&handle)?
                .unwrap_or_else(|| handle.clone());
            return Ok(HttpResponse {
                status: 200,
                body: auth_session_response_with_profile_name(
                    &handle,
                    &profile_name,
                    &request_public_base_url(&request),
                ),
            });
        }
        if is_profile_path(&request.path) {
            let handle = request_handle(&request);
            let profile_name = required_string(&body, &["profileName"], "profileName")?;
            let normalized_handle = normalize_identity_reference(handle);
            self.route_service
                .committer_mut()
                .upsert_profile(&normalized_handle, profile_name)?;
            return Ok(HttpResponse {
                status: 200,
                body: auth_session_response_with_profile_name(
                    &normalized_handle,
                    profile_name,
                    &request_public_base_url(&request),
                ),
            });
        }
        if is_device_register_path(&request.path) {
            let handle = request_handle(&request);
            let device_id = required_string(&body, &["deviceId"], "deviceId")?.to_owned();
            let device_label = path_value(&body, &["deviceLabel"])
                .and_then(Value::as_str)
                .unwrap_or(&device_id)
                .to_owned();
            if let Some(identity) = sanitized_direct_quic_identity(&body) {
                self.state
                    .direct_quic_identities_by_device
                    .insert(device_id.clone(), identity);
            }
            let direct_quic_identity = self
                .state
                .direct_quic_identities_by_device
                .get(&device_id)
                .cloned()
                .unwrap_or(Value::Null);
            self.record_presence(handle, "online", Some(device_id.clone()));
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "deviceId": device_id,
                    "userId": user_id_for_handle(handle),
                    "platform": "ios",
                    "deviceLabel": device_label,
                    "lastSeenAt": "1970-01-01T00:00:00Z",
                    "directQuicIdentity": direct_quic_identity
                }),
            });
        }
        if let Some(presence_status) = presence_status_path(&request.path) {
            let handle = request_handle(&request);
            let device_id = required_string(&body, &["deviceId"], "deviceId")?.to_owned();
            self.record_presence(handle, presence_status, Some(device_id.clone()));
            match presence_status {
                "background" | "offline" => {
                    self.mark_joined_handle_wake_disconnected(handle, &device_id)
                }
                _ => {}
            }
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "deviceId": device_id,
                    "userId": user_id_for_handle(handle),
                    "status": presence_status
                }),
            });
        }
        if is_telemetry_events_path(&request.path) {
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "status": "ok",
                    "delivered": true
                }),
            });
        }
        if is_diagnostics_upload_path(&request.path) {
            let handle = request_handle(&request);
            let report = diagnostics_report(handle, &body)?;
            let device_id = required_string(&body, &["deviceId"], "deviceId")?.to_owned();
            self.state
                .diagnostics_by_device
                .insert(device_id, report.clone());
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "status": "uploaded",
                    "report": report
                }),
            });
        }
        if is_wake_events_upload_path(&request.path) {
            let handle = request_handle(&request);
            let event = dev_event(handle, &body);
            self.state.wake_events.push(event.clone());
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "status": "uploaded",
                    "event": event
                }),
            });
        }
        if is_invariant_events_upload_path(&request.path) {
            let handle = request_handle(&request);
            let event = dev_event(handle, &body);
            self.state.invariant_events.push(event.clone());
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "status": "uploaded",
                    "event": event
                }),
            });
        }
        if is_dev_seed_path(&request.path) {
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "status": "seeded",
                    "users": []
                }),
            });
        }
        if is_dev_reset_path(&request.path) {
            let cleared_beeps = self.route_service.committer_mut().clear_beep_threads()?;
            let cleared_channels = self.state.channels.len();
            let cleared_remembered_contacts = self
                .route_service
                .committer_mut()
                .clear_remembered_contacts()?;
            let cleared_profiles = self.route_service.committer_mut().clear_profiles()?;
            let cleared_direct_quic_identities = self.state.direct_quic_identities_by_device.len();
            let cleared_presence_entries = self.state.presence_by_handle.len();
            self.state.channels.clear();
            self.state.direct_quic_identities_by_device.clear();
            self.state.presence_by_handle.clear();
            self.state.diagnostics_by_device.clear();
            self.state.wake_events.clear();
            self.state.invariant_events.clear();
            self.state.next_transmit_id = 0;
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "status": if control_plane_path_parts(&request.path).as_slice() == ["v1", "dev", "reset-all"] { "reset-all" } else { "reset" },
                    "clearedTransmitStates": 0,
                    "clearedPresenceEntries": cleared_presence_entries,
                    "clearedTokenEntries": 0,
                    "clearedBeeps": cleared_beeps,
                    "clearedChannels": cleared_channels,
                    "clearedRememberedContacts": cleared_remembered_contacts,
                    "clearedProfiles": cleared_profiles,
                    "clearedDirectQuicIdentities": cleared_direct_quic_identities
                }),
            });
        }
        if is_identity_resolve_path(&request.path) {
            let reference = path_value(&body, &["reference"])
                .and_then(Value::as_str)
                .unwrap_or("@self");
            let handle = normalize_identity_reference(reference);
            let profile_name = self
                .route_service
                .committer_mut()
                .profile_name(&handle)?
                .unwrap_or_else(|| handle.clone());
            return Ok(HttpResponse {
                status: 200,
                body: user_lookup_response(
                    &handle,
                    &profile_name,
                    self.handle_is_online(&handle),
                    &request_public_base_url(&request),
                ),
            });
        }
        if is_contact_remember_path(&request.path) {
            let handle = normalize_handle(request_handle(&request));
            let other_handle = contact_peer_handle_from_body(&body);
            let other_user_id = user_id_for_handle(&other_handle);
            self.route_service
                .committer_mut()
                .remember_contact_pair(&handle, &other_handle)?;
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "status": "remembered",
                    "otherUserId": other_user_id
                }),
            });
        }
        if is_contact_forget_path(&request.path) {
            let handle = normalize_handle(request_handle(&request));
            let other_handle = contact_peer_handle_from_body(&body);
            let other_user_id = user_id_for_handle(&other_handle);
            self.route_service
                .committer_mut()
                .forget_contact(&handle, &other_handle)?;
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "status": "forgotten",
                    "otherUserId": other_user_id
                }),
            });
        }
        if is_beep_create_path(&request.path) {
            let handle = request_handle(&request);
            let friend_handle = path_value(&body, &["friendHandle"])
                .and_then(Value::as_str)
                .map(normalize_handle)
                .or_else(|| {
                    path_value(&body, &["friendUserId"])
                        .and_then(Value::as_str)
                        .map(handle_for_user_id)
                })
                .unwrap_or_else(|| "@peer".to_owned());
            let beep = self.create_beep(handle, &friend_handle)?;
            return Ok(HttpResponse {
                status: 200,
                body: beep_response(&beep, handle),
            });
        }
        if let Some((beep_id, action)) = beep_action_path(&request.path) {
            let handle = request_handle(&request);
            let Some(effective_beep_id) = self.resolve_beep_action_id(beep_id, action)? else {
                return Ok(error_response(404, "beep not found"));
            };
            let Some(beep) = self
                .route_service
                .committer_mut()
                .beep_thread(&effective_beep_id)?
            else {
                return Ok(error_response(404, "beep not found"));
            };
            match action {
                "accept" => {
                    let beep = self
                        .route_service
                        .committer_mut()
                        .set_beep_thread_status(&effective_beep_id, "connected")?
                        .unwrap_or(beep);
                    self.route_service
                        .committer_mut()
                        .alias_beep_thread(&beep.beep_id, &beep.channel_id)?;
                    return Ok(HttpResponse {
                        status: 200,
                        body: beep_response(&beep, handle),
                    });
                }
                "decline" | "cancel" => {
                    let beep = self
                        .route_service
                        .committer_mut()
                        .set_beep_thread_status(
                            &effective_beep_id,
                            if action == "decline" {
                                "declined"
                            } else {
                                "cancelled"
                            },
                        )?
                        .unwrap_or(beep);
                    self.route_service
                        .committer_mut()
                        .alias_beep_thread(&beep.beep_id, &beep.channel_id)?;
                    return Ok(HttpResponse {
                        status: 200,
                        body: beep_response(&beep, handle),
                    });
                }
                _ => {}
            }
        }
        if is_direct_channel_path(&request.path) {
            let handle = request_handle(&request);
            let self_user_id = user_id_for_handle(handle);
            let other_handle = path_value(&body, &["otherHandle"])
                .and_then(Value::as_str)
                .map(normalize_handle)
                .or_else(|| {
                    path_value(&body, &["otherUserId"])
                        .and_then(Value::as_str)
                        .map(handle_for_user_id)
                })
                .unwrap_or_else(|| "@peer".to_owned());
            let other_user_id = path_value(&body, &["otherUserId"])
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| Some(user_id_for_handle(&other_handle)))
                .unwrap_or_else(|| "user-peer".to_owned());
            let (low_user_id, high_user_id) = sorted_pair(self_user_id, other_user_id);
            let channel_id = format!("direct-{low_user_id}-{high_user_id}");
            self.ensure_channel_participants(&channel_id, handle, &other_handle);
            let handle = normalize_handle(handle);
            self.route_service
                .committer_mut()
                .remember_contact_pair(&handle, &other_handle)?;
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "channelId": channel_id,
                    "lowUserId": low_user_id,
                    "highUserId": high_user_id,
                    "createdAt": "1970-01-01T00:00:00Z"
                }),
            });
        }
        if let Some(channel_id) = channel_join_path(&request.path) {
            let handle = request_handle(&request);
            let device_id = path_value(&body, &["deviceId"])
                .and_then(Value::as_str)
                .unwrap_or("device")
                .to_owned();
            self.join_channel(channel_id, handle, &device_id);
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "channelId": channel_id,
                    "userId": user_id_for_handle(handle),
                    "deviceId": device_id,
                    "status": "joined"
                }),
            });
        }
        if let Some(channel_id) = channel_leave_path(&request.path) {
            let handle = request_handle(&request);
            let device_id = path_value(&body, &["deviceId"])
                .and_then(Value::as_str)
                .unwrap_or("device")
                .to_owned();
            self.leave_channel(channel_id, handle, Some(&device_id));
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "channelId": channel_id,
                    "deviceId": device_id,
                    "status": "left"
                }),
            });
        }
        if let Some(channel_id) = channel_ephemeral_token_upload_path(&request.path) {
            let handle = request_handle(&request);
            let device_id = required_string(&body, &["deviceId"], "deviceId")?.to_owned();
            let token = required_string(&body, &["token"], "token")?.to_owned();
            let apns_environment = path_value(&body, &["apnsEnvironment"])
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);
            self.record_ephemeral_token(channel_id, handle, &device_id, &token, apns_environment);
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "channelId": channel_id,
                    "token": token,
                    "status": "uploaded"
                }),
            });
        }
        if let Some(channel_id) = channel_ephemeral_token_revoke_path(&request.path) {
            let handle = request_handle(&request);
            let device_id = required_string(&body, &["deviceId"], "deviceId")?.to_owned();
            self.revoke_ephemeral_token(channel_id, handle);
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "channelId": channel_id,
                    "deviceId": device_id,
                    "status": "revoked"
                }),
            });
        }
        if let Some(channel_id) = receiver_audio_readiness_path(&request.path) {
            let handle = request_handle(&request);
            let device_id = required_string(&body, &["deviceId"], "deviceId")?.to_owned();
            let signal_type = required_string(&body, &["type"], "type")?.to_owned();
            let payload = path_value(&body, &["payload"])
                .and_then(Value::as_str)
                .unwrap_or("");
            if signal_type == "receiver-ready" {
                self.record_presence(handle, "online", Some(device_id.clone()));
                if !self.channel_has_pending_beep(channel_id)? {
                    self.join_channel(channel_id, handle, &device_id);
                    self.clear_channel_wake_disconnect(channel_id, handle);
                }
            } else if payload.contains("app-background-media-closed") {
                self.record_presence(handle, "background", Some(device_id.clone()));
                self.mark_channel_wake_disconnected(channel_id, handle, &device_id);
            }
            return Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({
                    "channelId": channel_id,
                    "deviceId": device_id,
                    "type": signal_type,
                    "audioReadiness": if signal_type == "receiver-ready" { "ready" } else { "waiting" },
                    "status": "stored"
                }),
            });
        }
        if let Some(conversation_id) = native_request_conversation_id(&request.path) {
            let route_response = self
                .route_service
                .handle_request_talk_turn(conversation_id, body)?;
            return Ok(HttpResponse {
                status: route_response.status_code,
                body: route_response.body,
            });
        }
        if let Some(conversation_id) = native_renew_conversation_id(&request.path) {
            let route_response = self
                .route_service
                .handle_renew_talk_turn(conversation_id, body)?;
            return Ok(HttpResponse {
                status: route_response.status_code,
                body: route_response.body,
            });
        }
        if let Some(conversation_id) = native_release_conversation_id(&request.path) {
            let route_response = self
                .route_service
                .handle_actor_release_talk_turn(conversation_id, body)?;
            return Ok(HttpResponse {
                status: route_response.status_code,
                body: route_response.body,
            });
        }
        if let Some(channel_id) = legacy_begin_transmit_channel_id(&request.path) {
            if !body.get("requestingParticipantId").is_some() {
                let handle = request_handle(&request);
                let device_id = required_string(&body, &["deviceId"], "deviceId")?.to_owned();
                return Ok(HttpResponse {
                    status: 200,
                    body: self.begin_app_transmit_response(channel_id, handle, &device_id),
                });
            }
            let route_response = self
                .route_service
                .handle_legacy_begin_transmit(legacy_begin_transmit_input(channel_id, &body)?)?;
            return Ok(HttpResponse {
                status: route_response.status_code,
                body: route_response.body,
            });
        }
        if let Some(channel_id) = legacy_renew_transmit_channel_id(&request.path) {
            if self.state.channels.contains_key(channel_id) {
                return Ok(self.renew_app_transmit_response(channel_id));
            }
            let route_response = self.route_service.handle_renew_talk_turn(
                channel_id,
                legacy_renew_transmit_command(channel_id, &body)?,
            )?;
            return Ok(HttpResponse {
                status: route_response.status_code,
                body: legacy_renew_transmit_response(&route_response.body),
            });
        }
        if let Some(channel_id) = legacy_end_transmit_channel_id(&request.path) {
            if self.state.channels.contains_key(channel_id) {
                return Ok(HttpResponse {
                    status: 200,
                    body: self.end_app_transmit_response(channel_id),
                });
            }
            let route_response = self.route_service.handle_actor_release_talk_turn(
                channel_id,
                legacy_end_transmit_command(channel_id, &body)?,
            )?;
            return Ok(HttpResponse {
                status: route_response.status_code,
                body: legacy_end_transmit_response(&route_response.body),
            });
        }

        Ok(error_response(404, "not found"))
    }

    fn create_beep(
        &mut self,
        from_handle: &str,
        to_handle: &str,
    ) -> Result<DurableBeepThread, RuntimeHttpError> {
        let from_handle = normalize_handle(from_handle);
        let to_handle = normalize_handle(to_handle);
        let channel_id = channel_id_for_pair(&from_handle, &to_handle);
        let beep = self
            .route_service
            .committer_mut()
            .create_or_refresh_beep_thread(&from_handle, &to_handle, &channel_id)?;
        self.ensure_channel_participants(&channel_id, &from_handle, &to_handle);
        Ok(beep)
    }

    fn resolve_beep_action_id(
        &mut self,
        requested_beep_id: &str,
        action: &str,
    ) -> Result<Option<String>, RuntimeHttpError> {
        if let Some(beep) = self
            .route_service
            .committer_mut()
            .beep_thread(requested_beep_id)?
        {
            if action == "accept" && beep.status != "pending" {
                if let Some(current_id) = self
                    .route_service
                    .committer_mut()
                    .current_pending_beep_thread_id(&beep.channel_id)?
                {
                    return Ok(Some(current_id));
                }
            }
            return Ok(Some(requested_beep_id.to_owned()));
        }

        let Some(channel_id) = self
            .route_service
            .committer_mut()
            .alias_channel_for_beep_thread(requested_beep_id)?
        else {
            return Ok(None);
        };
        Ok(self
            .route_service
            .committer_mut()
            .current_pending_beep_thread_id(&channel_id)?)
    }

    fn beeps_for_handle(
        &mut self,
        handle: &str,
        direction: &str,
    ) -> Result<Vec<Value>, RuntimeHttpError> {
        let normalized_handle = normalize_handle(handle);
        Ok(self
            .route_service
            .committer_mut()
            .pending_beep_threads_for_handle(&normalized_handle, direction)?
            .iter()
            .map(|beep| beep_response(beep, &normalized_handle))
            .collect())
    }

    fn contact_summaries_for_handle(
        &mut self,
        handle: &str,
    ) -> Result<Vec<Value>, RuntimeHttpError> {
        let normalized_handle = normalize_handle(handle);
        let mut peers_by_channel_id = BTreeMap::new();
        let transient_channels: Vec<(String, RuntimeChannel)> = self
            .state
            .channels
            .iter()
            .map(|(channel_id, channel)| (channel_id.clone(), channel.clone()))
            .collect();
        for (channel_id, channel) in transient_channels {
            if channel
                .participants_by_handle
                .contains_key(&normalized_handle)
            {
                let membership = self.channel_membership(&channel_id, &normalized_handle);
                let (has_incoming_beep, has_outgoing_beep, _) =
                    self.beep_projection_for_channel(&channel_id, &normalized_handle)?;
                let has_active_transmit =
                    active_transmitter_for_handle(Some(&channel), &normalized_handle).is_some();
                let should_project_channel = has_incoming_beep
                    || has_outgoing_beep
                    || membership.self_joined
                    || membership.peer_joined
                    || membership.peer_device_connected
                    || has_active_transmit;
                if !should_project_channel {
                    continue;
                }

                let peer_handle = channel
                    .participants_by_handle
                    .keys()
                    .find(|candidate| *candidate != &normalized_handle)
                    .cloned();
                if let Some(peer_handle) = peer_handle {
                    peers_by_channel_id.insert(channel_id, peer_handle);
                }
            }
        }
        let remembered_contacts = self
            .route_service
            .committer_mut()
            .remembered_contact_handles(&normalized_handle)?;
        for peer_handle in remembered_contacts {
            peers_by_channel_id
                .entry(channel_id_for_pair(&normalized_handle, &peer_handle))
                .or_insert(peer_handle);
        }
        let mut summaries = Vec::new();
        for (channel_id, peer_handle) in peers_by_channel_id {
            let profile_name = self
                .route_service
                .committer_mut()
                .profile_name(&peer_handle)?
                .unwrap_or_else(|| peer_handle.clone());
            summaries.push(self.contact_summary_for_channel(
                &channel_id,
                handle,
                &peer_handle,
                &profile_name,
            )?);
        }
        Ok(summaries)
    }

    fn contact_summary_for_channel(
        &mut self,
        channel_id: &str,
        handle: &str,
        peer_handle: &str,
        profile_name: &str,
    ) -> Result<Value, RuntimeHttpError> {
        let membership = self.channel_membership(channel_id, handle);
        let (has_incoming_beep, has_outgoing_beep, request_count) =
            self.beep_projection_for_channel(channel_id, handle)?;
        let projected_membership =
            membership.projected_for_pending_beep(has_incoming_beep || has_outgoing_beep);
        let badge_status = summary_status_kind(
            has_incoming_beep,
            has_outgoing_beep,
            projected_membership.self_joined,
            projected_membership.peer_joined,
            projected_membership.peer_device_connected,
            active_transmitter_for_handle(self.state.channels.get(channel_id), handle),
        );
        let active_transmitter_user_id =
            active_transmitter_user_id(self.state.channels.get(channel_id));
        let peer_user_id = user_id_for_handle(peer_handle);
        let peer_device_connected = projected_membership.peer_device_connected;
        Ok(serde_json::json!({
            "userId": peer_user_id,
            "handle": peer_handle,
            "publicId": peer_handle,
            "displayName": profile_name,
            "profileName": profile_name,
            "channelId": channel_id,
            "isOnline": true,
            "hasIncomingBeep": has_incoming_beep,
            "hasOutgoingBeep": has_outgoing_beep,
            "requestCount": request_count,
            "selfJoined": projected_membership.self_joined,
            "peerJoined": projected_membership.peer_joined,
            "peerDeviceConnected": peer_device_connected,
            "isActiveConversation": has_incoming_beep
                || has_outgoing_beep
                || projected_membership.self_joined
                || projected_membership.peer_joined,
            "badgeStatus": badge_status,
            "beepThreadProjection": beep_thread_projection_payload(
                has_incoming_beep,
                has_outgoing_beep,
                request_count
            ),
            "membership": membership_payload(
                projected_membership.self_joined,
                projected_membership.peer_joined,
                peer_device_connected
            ),
            "summaryStatus": {
                "kind": badge_status,
                "activeTransmitterUserId": active_transmitter_user_id
            }
        }))
    }

    fn begin_app_transmit_response(
        &mut self,
        channel_id: &str,
        handle: &str,
        device_id: &str,
    ) -> Value {
        self.state.next_transmit_id += 1;
        let transmit_id = format!("transmit-{}", self.state.next_transmit_id);
        let normalized_handle = normalize_handle(handle);
        let self_user_id = user_id_for_handle(&normalized_handle);
        let peer_handle = self
            .peer_handle_for_channel(channel_id, handle)
            .unwrap_or_else(|| {
                handle_for_user_id(&peer_user_id_for_channel(channel_id, &self_user_id))
            });
        let target_device_id = self
            .state
            .channels
            .get(channel_id)
            .and_then(|channel| channel.joined_devices_by_handle.get(&peer_handle))
            .cloned()
            .unwrap_or_else(|| "peer-device".to_owned());
        let wake_target = self.state.channels.get(channel_id).and_then(|channel| {
            if channel.wake_disconnected_handles.contains(&peer_handle) {
                channel
                    .ephemeral_tokens_by_handle
                    .get(&peer_handle)
                    .cloned()
            } else {
                None
            }
        });
        let started_at = runtime_iso8601_utc_millis(runtime_now_millis());
        let channel = self
            .state
            .channels
            .entry(channel_id.to_owned())
            .or_default();
        channel
            .participants_by_handle
            .insert(normalized_handle.clone(), self_user_id.clone());
        channel
            .joined_devices_by_handle
            .insert(normalized_handle.clone(), device_id.to_owned());
        channel.active_transmit_id = Some(transmit_id.clone());
        channel.active_transmitter_handle = Some(normalized_handle.clone());
        let expires_at_ms = runtime_app_transmit_expires_at_ms();
        channel.active_transmit_expires_at_ms = Some(expires_at_ms);
        channel.last_transmitter_handle = Some(normalized_handle);
        if let Some(wake_target) = wake_target {
            self.send_apns_ptt_push(AppPttPushRequest {
                event: "transmit-start",
                channel_id,
                sender_handle: handle,
                sender_user_id: &self_user_id,
                sender_device_id: device_id,
                target_handle: &peer_handle,
                target_device_id: &wake_target.device_id,
                target_token: &wake_target.token,
                target_apns_environment: wake_target.apns_environment.as_deref(),
                attempt_id: &transmit_id,
                started_at: &started_at,
            });
        }
        serde_json::json!({
            "channelId": channel_id,
            "status": "transmitting",
            "transmitId": transmit_id,
            "startedAt": started_at,
            "expiresAt": runtime_iso8601_utc_millis(expires_at_ms),
            "expiresAtMs": APP_COMPATIBLE_TRANSMIT_LEASE_MS,
            "targetUserId": user_id_for_handle(&peer_handle),
            "targetDeviceId": target_device_id
        })
    }

    fn send_apns_ptt_push(&mut self, request: AppPttPushRequest<'_>) {
        let base_event = serde_json::json!({
            "event": request.event,
            "senderUserId": request.sender_user_id,
            "channelId": request.channel_id,
            "senderDeviceId": request.sender_device_id,
            "senderHandle": request.sender_handle,
            "targetUserId": user_id_for_handle(request.target_handle),
            "targetDeviceId": request.target_device_id,
            "startedAt": request.started_at,
            "recordedAt": runtime_iso8601_utc_millis(runtime_now_millis()),
        });

        let Some(worker) = self.runtime_config.apns_worker.clone() else {
            self.record_wake_event(
                base_event,
                "not-configured",
                0,
                "TURBO_APNS_WORKER_BASE_URL or TURBO_APNS_WORKER_SECRET missing",
            );
            return;
        };

        let sandbox = request
            .target_apns_environment
            .map(|environment| environment != "production")
            .unwrap_or(worker.use_sandbox);
        let worker_url = format!("{}/apns/send", worker.base_url.trim_end_matches('/'));
        let body = serde_json::json!({
            "token": request.target_token,
            "payload": {
                "aps": {},
                "event": request.event,
                "channelId": request.channel_id,
                "activeSpeaker": request.sender_handle,
                "senderUserId": request.sender_user_id,
                "senderDeviceId": request.sender_device_id,
            },
            "pushType": "pushtotalk",
            "bundleId": worker.bundle_id,
            "topicSuffix": ".voip-ptt",
            "sandbox": sandbox,
            "priority": 10,
            "expiration": 0,
            "metadata": {
                "wakeAttemptId": format!(
                    "{}:{}:{}",
                    request.channel_id, request.attempt_id, request.target_device_id
                ),
                "event": request.event,
                "channelId": request.channel_id,
                "targetDeviceId": request.target_device_id,
            },
        });

        let client = match reqwest::blocking::Client::builder()
            .timeout(Duration::from_millis(worker.timeout_ms))
            .build()
        {
            Ok(client) => client,
            Err(error) => {
                self.record_wake_event(base_event, "client-build-failed", 0, &error.to_string());
                return;
            }
        };

        let response = client
            .post(worker_url)
            .header("x-turbo-worker-secret", worker.secret)
            .json(&body)
            .send();
        match response {
            Ok(response) => {
                let status = response.status().as_u16();
                let response_text = response.text().unwrap_or_default();
                let parsed: Option<Value> = serde_json::from_str(&response_text).ok();
                let result = parsed
                    .as_ref()
                    .and_then(|value| path_value(value, &["result"]).and_then(Value::as_str))
                    .unwrap_or(if (200..300).contains(&status) {
                        "sent"
                    } else {
                        "rejected"
                    });
                let status_code = parsed
                    .as_ref()
                    .and_then(|value| path_value(value, &["status"]).and_then(Value::as_u64))
                    .unwrap_or(status as u64);
                let response_body = parsed
                    .as_ref()
                    .and_then(|value| path_value(value, &["reason"]).and_then(Value::as_str))
                    .or_else(|| {
                        if response_text.is_empty() {
                            None
                        } else {
                            Some(response_text.as_str())
                        }
                    })
                    .unwrap_or("");
                self.record_wake_event(base_event, result, status_code, response_body);
            }
            Err(error) => {
                self.record_wake_event(base_event, "transport-failed", 0, &error.to_string());
            }
        }
    }

    fn record_wake_event(
        &mut self,
        mut event: Value,
        result: &str,
        status_code: u64,
        response_body: &str,
    ) {
        if let Some(object) = event.as_object_mut() {
            object.insert("result".to_owned(), Value::String(result.to_owned()));
            object.insert(
                "statusCode".to_owned(),
                Value::String(status_code.to_string()),
            );
            object.insert(
                "responseBody".to_owned(),
                if response_body.is_empty() {
                    Value::Null
                } else {
                    Value::String(response_body.to_owned())
                },
            );
        }
        self.state.wake_events.push(event);
    }

    fn renew_app_transmit_response(&mut self, channel_id: &str) -> HttpResponse {
        self.clear_expired_app_transmit(channel_id);
        let Some(transmit_id) = self
            .state
            .channels
            .get(channel_id)
            .and_then(|channel| channel.active_transmit_id.clone())
        else {
            return error_response(409, "no active transmit state for sender");
        };
        let expires_at_ms = runtime_app_transmit_expires_at_ms();
        if let Some(channel) = self.state.channels.get_mut(channel_id) {
            channel.active_transmit_expires_at_ms = Some(expires_at_ms);
        }
        HttpResponse {
            status: 200,
            body: serde_json::json!({
                "channelId": channel_id,
                "status": "transmitting",
                "transmitId": transmit_id,
                "startedAt": "1970-01-01T00:00:00Z",
                "expiresAt": runtime_iso8601_utc_millis(expires_at_ms),
                "expiresAtMs": APP_COMPATIBLE_TRANSMIT_LEASE_MS
            }),
        }
    }

    fn end_app_transmit_response(&mut self, channel_id: &str) -> Value {
        if let Some(channel) = self.state.channels.get_mut(channel_id) {
            channel.active_transmit_id = None;
            channel.active_transmitter_handle = None;
            channel.active_transmit_expires_at_ms = None;
        }
        serde_json::json!({
            "channelId": channel_id,
            "status": "stopped"
        })
    }

    fn clear_expired_app_transmits(&mut self) {
        let now_ms = runtime_now_millis();
        for channel in self.state.channels.values_mut() {
            clear_expired_app_transmit(channel, now_ms);
        }
    }

    fn clear_expired_app_transmit(&mut self, channel_id: &str) {
        let now_ms = runtime_now_millis();
        if let Some(channel) = self.state.channels.get_mut(channel_id) {
            clear_expired_app_transmit(channel, now_ms);
        }
    }

    fn record_ephemeral_token(
        &mut self,
        channel_id: &str,
        handle: &str,
        device_id: &str,
        token: &str,
        apns_environment: Option<String>,
    ) {
        let handle = normalize_handle(handle);
        let channel = self
            .state
            .channels
            .entry(channel_id.to_owned())
            .or_default();
        channel
            .participants_by_handle
            .entry(handle.clone())
            .or_insert_with(|| user_id_for_handle(&handle));
        channel.ephemeral_tokens_by_handle.insert(
            handle,
            RuntimeEphemeralToken {
                device_id: device_id.to_owned(),
                token: token.to_owned(),
                apns_environment,
            },
        );
    }

    fn revoke_ephemeral_token(&mut self, channel_id: &str, handle: &str) {
        let handle = normalize_handle(handle);
        if let Some(channel) = self.state.channels.get_mut(channel_id) {
            channel.ephemeral_tokens_by_handle.remove(&handle);
            if channel
                .active_transmitter_handle
                .as_ref()
                .is_some_and(|active_handle| active_handle != &handle)
                && channel.wake_disconnected_handles.contains(&handle)
            {
                channel.active_transmit_id = None;
                channel.active_transmitter_handle = None;
                channel.active_transmit_expires_at_ms = None;
            }
        }
    }

    fn channel_state_response(
        &mut self,
        channel_id: &str,
        handle: &str,
    ) -> Result<Value, RuntimeHttpError> {
        let self_user_id = user_id_for_handle(handle);
        let peer_handle = self
            .peer_handle_for_channel(channel_id, handle)
            .unwrap_or_else(|| {
                handle_for_user_id(&peer_user_id_for_channel(channel_id, &self_user_id))
            });
        let peer_user_id = user_id_for_handle(&peer_handle);
        let (has_incoming_beep, has_outgoing_beep, request_count) =
            self.beep_projection_for_channel(channel_id, handle)?;
        let membership = self.channel_membership(channel_id, handle);
        let channel = self.state.channels.get(channel_id);
        let active_transmit_id = channel
            .and_then(|channel| channel.active_transmit_id.clone())
            .map(Value::String)
            .unwrap_or(Value::Null);
        let active_transmitter_user_id = active_transmitter_user_id(channel);
        let peer_device_connected = membership.peer_device_connected;
        let status = match active_transmitter_for_handle(channel, handle) {
            Some(true) => "self-transmitting",
            Some(false) => "peer-transmitting",
            None => match (has_incoming_beep, has_outgoing_beep) {
                (true, _) => "incoming-beep",
                (false, true) => "outgoing-beep",
                (false, false) if membership.has_both && peer_device_connected => "ready",
                (false, false) if membership.self_joined || membership.peer_joined => {
                    "waiting-for-peer"
                }
                (false, false) => "idle",
            },
        };
        let has_pending_beep = has_incoming_beep || has_outgoing_beep;
        let projected_membership = membership.projected_for_pending_beep(has_pending_beep);
        Ok(serde_json::json!({
            "channelId": channel_id,
            "selfUserId": self_user_id,
            "peerUserId": peer_user_id,
            "peerHandle": peer_handle,
            "selfOnline": true,
            "peerOnline": true,
            "stateEpoch": "1",
            "serverTimestamp": "1970-01-01T00:00:00Z",
            "activeTransmitId": active_transmit_id,
            "activeTransmitterUserId": active_transmitter_user_id,
            "transmitLeaseExpiresAt": active_transmit_expires_at_value(channel),
            "canTransmit": !has_pending_beep
                && membership.has_both
                && peer_device_connected
                && active_transmitter_user_id.is_none(),
            "status": status,
            "membership": membership_payload(
                projected_membership.self_joined,
                projected_membership.peer_joined,
                projected_membership.peer_device_connected
            ),
            "beepThreadProjection": beep_thread_projection_payload(
                has_incoming_beep,
                has_outgoing_beep,
                request_count
            ),
            "conversationStatus": {
                "kind": status,
                "activeTransmitterUserId": active_transmitter_user_id
            }
        }))
    }

    fn channel_readiness_response(
        &mut self,
        channel_id: &str,
        handle: &str,
    ) -> Result<Value, RuntimeHttpError> {
        let self_user_id = user_id_for_handle(handle);
        let peer_handle = self
            .peer_handle_for_channel(channel_id, handle)
            .unwrap_or_else(|| {
                handle_for_user_id(&peer_user_id_for_channel(channel_id, &self_user_id))
            });
        let peer_user_id = user_id_for_handle(&peer_handle);
        let (has_incoming_beep, has_outgoing_beep, _) =
            self.beep_projection_for_channel(channel_id, handle)?;
        let membership = self.channel_membership(channel_id, handle);
        let has_pending_beep = has_incoming_beep || has_outgoing_beep;
        let projected_membership = membership.projected_for_pending_beep(has_pending_beep);
        let channel = self.state.channels.get(channel_id);
        let active_transmitter_user_id = active_transmitter_user_id(channel);
        let active_transmit_id = channel
            .and_then(|channel| channel.active_transmit_id.clone())
            .map(Value::String)
            .unwrap_or(Value::Null);
        let peer_device_connected = projected_membership.peer_device_connected;
        let readiness_kind = match active_transmitter_for_handle(channel, handle) {
            Some(true) => "self-transmitting",
            Some(false) => "peer-transmitting",
            None if has_pending_beep => "inactive",
            None if projected_membership.has_both && peer_device_connected => "ready",
            None if projected_membership.self_joined || projected_membership.peer_joined => {
                "waiting-for-peer"
            }
            None => "inactive",
        };
        let peer_audio_readiness = if projected_membership.peer_joined {
            if peer_device_connected {
                "ready"
            } else {
                "wake-capable"
            }
        } else {
            "unknown"
        };
        let self_wake_token = channel.and_then(|channel| {
            channel
                .ephemeral_tokens_by_handle
                .get(&normalize_handle(handle))
        });
        let peer_wake_token = channel.and_then(|channel| {
            channel
                .ephemeral_tokens_by_handle
                .get(&normalize_handle(&peer_handle))
        });
        let self_wake_readiness = if self_wake_token.is_some() {
            "wake-capable"
        } else {
            "unavailable"
        };
        let peer_wake_readiness = if peer_wake_token.is_some() {
            Value::String("wake-capable".to_owned())
        } else {
            Value::String("unavailable".to_owned())
        };
        let peer_target_device_id = projected_membership
            .peer_device_id
            .clone()
            .map(Value::String);
        let self_target_device_id = self_wake_token
            .map(|token| Value::String(token.device_id.clone()))
            .unwrap_or(Value::Null);
        let peer_wake_target_device_id = peer_wake_token
            .map(|token| Value::String(token.device_id.clone()))
            .unwrap_or(Value::Null);
        let peer_direct_quic_identity = projected_membership
            .peer_device_id
            .as_ref()
            .and_then(|device_id| self.state.direct_quic_identities_by_device.get(device_id))
            .cloned()
            .unwrap_or(Value::Null);
        Ok(serde_json::json!({
            "channelId": channel_id,
            "peerUserId": peer_user_id,
            "selfHasActiveDevice": projected_membership.self_joined,
            "peerHasActiveDevice": projected_membership.peer_joined && peer_device_connected,
            "stateEpoch": "1",
            "serverTimestamp": "1970-01-01T00:00:00Z",
            "activeTransmitId": active_transmit_id,
            "activeTransmitterUserId": active_transmitter_user_id,
            "activeTransmitExpiresAt": active_transmit_expires_at_value(channel),
            "readiness": {
                "kind": readiness_kind,
                "activeTransmitterUserId": active_transmitter_user_id
            },
            "audioReadiness": {
                "self": { "kind": if projected_membership.self_joined { "ready" } else { "unknown" } },
                "peer": { "kind": peer_audio_readiness },
                "peerTargetDeviceId": peer_target_device_id.clone().unwrap_or(Value::Null)
            },
            "wakeReadiness": {
                "self": { "kind": self_wake_readiness, "targetDeviceId": self_target_device_id },
                "peer": {
                    "kind": peer_wake_readiness,
                    "targetDeviceId": peer_wake_target_device_id
                }
            },
            "peerDirectQuicIdentity": peer_direct_quic_identity
        }))
    }

    fn beep_projection_for_channel(
        &mut self,
        channel_id: &str,
        handle: &str,
    ) -> Result<(bool, bool, u64), RuntimeHttpError> {
        let normalized_handle = normalize_handle(handle);
        let Some(beep) = self
            .route_service
            .committer_mut()
            .pending_beep_thread_for_channel(channel_id)?
        else {
            return Ok((false, false, 0));
        };
        Ok((
            beep.to_handle == normalized_handle,
            beep.from_handle == normalized_handle,
            beep.request_count,
        ))
    }

    fn channel_has_pending_beep(&mut self, channel_id: &str) -> Result<bool, RuntimeHttpError> {
        Ok(self
            .route_service
            .committer_mut()
            .pending_beep_thread_for_channel(channel_id)?
            .is_some())
    }

    fn ensure_channel_participants(
        &mut self,
        channel_id: &str,
        self_handle: &str,
        peer_handle: &str,
    ) {
        let channel = self
            .state
            .channels
            .entry(channel_id.to_owned())
            .or_default();
        let self_handle = normalize_handle(self_handle);
        let peer_handle = normalize_handle(peer_handle);
        channel
            .participants_by_handle
            .insert(self_handle.clone(), user_id_for_handle(&self_handle));
        channel
            .participants_by_handle
            .insert(peer_handle.clone(), user_id_for_handle(&peer_handle));
    }

    fn join_channel(&mut self, channel_id: &str, handle: &str, device_id: &str) {
        let normalized_handle = normalize_handle(handle);
        self.record_presence(&normalized_handle, "online", Some(device_id.to_owned()));
        let channel = self
            .state
            .channels
            .entry(channel_id.to_owned())
            .or_default();
        channel.participants_by_handle.insert(
            normalized_handle.clone(),
            user_id_for_handle(&normalized_handle),
        );
        channel
            .joined_devices_by_handle
            .insert(normalized_handle.clone(), device_id.to_owned());
        channel.wake_disconnected_handles.remove(&normalized_handle);
    }

    fn mark_channel_wake_disconnected(&mut self, channel_id: &str, handle: &str, device_id: &str) {
        let normalized_handle = normalize_handle(handle);
        let channel = self
            .state
            .channels
            .entry(channel_id.to_owned())
            .or_default();
        channel.participants_by_handle.insert(
            normalized_handle.clone(),
            user_id_for_handle(&normalized_handle),
        );
        channel
            .joined_devices_by_handle
            .entry(normalized_handle.clone())
            .or_insert_with(|| device_id.to_owned());
        channel.wake_disconnected_handles.insert(normalized_handle);
    }

    fn clear_channel_wake_disconnect(&mut self, channel_id: &str, handle: &str) {
        if let Some(channel) = self.state.channels.get_mut(channel_id) {
            channel
                .wake_disconnected_handles
                .remove(&normalize_handle(handle));
        }
    }

    fn leave_channel(&mut self, channel_id: &str, handle: &str, device_id: Option<&str>) {
        let mut leave_pushes = Vec::new();
        let normalized_handle = normalize_handle(handle);
        let mut sender_device_id = device_id.unwrap_or("device").to_owned();
        if let Some(channel) = self.state.channels.get_mut(channel_id) {
            if device_id.is_none()
                && let Some(joined_device_id) =
                    channel.joined_devices_by_handle.get(&normalized_handle)
            {
                sender_device_id = joined_device_id.clone();
            }
            for (peer_handle, token) in channel.ephemeral_tokens_by_handle.iter() {
                if peer_handle != &normalized_handle {
                    leave_pushes.push((peer_handle.clone(), token.clone()));
                }
            }
            let leaver_was_active_transmitter =
                channel.active_transmitter_handle.as_ref() == Some(&normalized_handle);
            let should_preserve_last_sender = channel
                .last_transmitter_handle
                .as_ref()
                .is_some_and(|last_transmitter| last_transmitter != &normalized_handle);
            channel.active_transmit_id = None;
            channel.active_transmitter_handle = None;
            channel.active_transmit_expires_at_ms = None;

            if leaver_was_active_transmitter || !should_preserve_last_sender {
                channel.joined_devices_by_handle.clear();
                channel.wake_disconnected_handles.clear();
            } else {
                channel.joined_devices_by_handle.remove(&normalized_handle);
                channel.wake_disconnected_handles.remove(&normalized_handle);
            }
        }

        let started_at = runtime_iso8601_utc_millis(runtime_now_millis());
        let attempt_id = format!("leave:{channel_id}:{normalized_handle}:{sender_device_id}");
        let sender_user_id = user_id_for_handle(&normalized_handle);
        for (target_handle, token) in leave_pushes {
            self.send_apns_ptt_push(AppPttPushRequest {
                event: "leave-channel",
                channel_id,
                sender_handle: &normalized_handle,
                sender_user_id: &sender_user_id,
                sender_device_id: &sender_device_id,
                target_handle: &target_handle,
                target_device_id: &token.device_id,
                target_token: &token.token,
                target_apns_environment: token.apns_environment.as_deref(),
                attempt_id: &attempt_id,
                started_at: &started_at,
            });
        }
    }

    fn peer_handle_for_channel(&self, channel_id: &str, handle: &str) -> Option<String> {
        let normalized_handle = normalize_handle(handle);
        self.state
            .channels
            .get(channel_id)?
            .participants_by_handle
            .keys()
            .find(|candidate| *candidate != &normalized_handle)
            .cloned()
    }

    fn channel_membership(&self, channel_id: &str, handle: &str) -> RuntimeMembership {
        let normalized_handle = normalize_handle(handle);
        let Some(channel) = self.state.channels.get(channel_id) else {
            return RuntimeMembership::default();
        };
        let self_joined = channel
            .joined_devices_by_handle
            .contains_key(&normalized_handle);
        let peer_joined = channel
            .joined_devices_by_handle
            .keys()
            .any(|candidate| candidate != &normalized_handle);
        RuntimeMembership {
            self_joined,
            peer_joined,
            has_both: self_joined && peer_joined,
            peer_device_connected: peer_joined
                && self
                    .peer_handle_for_channel(channel_id, handle)
                    .is_none_or(|peer_handle| {
                        !channel.wake_disconnected_handles.contains(&peer_handle)
                            && self.handle_is_connected(&peer_handle)
                    }),
            peer_device_id: self.peer_handle_for_channel(channel_id, handle).and_then(
                |peer_handle| {
                    channel
                        .joined_devices_by_handle
                        .get(&peer_handle)
                        .cloned()
                        .or_else(|| self.presence_device_id(&peer_handle))
                },
            ),
        }
    }

    fn record_presence(&mut self, handle: &str, status: &str, device_id: Option<String>) {
        let normalized_handle = normalize_handle(handle);
        self.state.presence_by_handle.insert(
            normalized_handle,
            RuntimePresence {
                status: status.to_owned(),
                device_id,
            },
        );
    }

    fn handle_is_online(&self, handle: &str) -> bool {
        self.state
            .presence_by_handle
            .get(&normalize_handle(handle))
            .is_none_or(|presence| presence.status != "offline")
    }

    fn handle_is_connected(&self, handle: &str) -> bool {
        self.state
            .presence_by_handle
            .get(&normalize_handle(handle))
            .is_none_or(|presence| presence.status == "online")
    }

    fn presence_device_id(&self, handle: &str) -> Option<String> {
        self.state
            .presence_by_handle
            .get(&normalize_handle(handle))
            .and_then(|presence| presence.device_id.clone())
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct RuntimeMembership {
    self_joined: bool,
    peer_joined: bool,
    has_both: bool,
    peer_device_connected: bool,
    peer_device_id: Option<String>,
}

impl RuntimeMembership {
    fn projected_for_pending_beep(&self, has_pending_beep: bool) -> Self {
        if has_pending_beep {
            Self::default()
        } else {
            self.clone()
        }
    }
}

pub fn serve_one_connection<S, W>(
    listener: &TcpListener,
    service: &Mutex<RuntimeHttpService<S, W>>,
) -> Result<(), RuntimeHttpError>
where
    S: RequestTalkTurnSnapshotLoader,
    W: RequestTalkTurnKernelWorker,
    crate::postgres::DurableConversationStore: TalkTurnRenewalCommitter
        + TalkTurnReleaseCommitter
        + DurableContactStore
        + DurableBeepThreadStore,
{
    let (mut stream, _) = listener.accept()?;
    let request = read_http_request(&mut stream)?;
    let response = service
        .lock()
        .expect("runtime HTTP service lock should not be poisoned")
        .handle(request);
    write_http_response(&mut stream, &response)?;
    Ok(())
}

pub fn serve_one_connection_with_committer<S, W, C>(
    listener: &TcpListener,
    service: &Mutex<RuntimeHttpService<S, W, C>>,
) -> Result<(), RuntimeHttpError>
where
    S: RequestTalkTurnSnapshotLoader,
    W: RequestTalkTurnKernelWorker,
    C: KernelDecisionCommitter
        + TalkTurnRenewalCommitter
        + TalkTurnReleaseCommitter
        + DurableContactStore
        + DurableBeepThreadStore,
{
    let (mut stream, _) = listener.accept()?;
    serve_stream_with_committer(&mut stream, service)
}

pub fn serve_stream_with_committer<S, W, C>(
    stream: &mut impl ReadWrite,
    service: &Mutex<RuntimeHttpService<S, W, C>>,
) -> Result<(), RuntimeHttpError>
where
    S: RequestTalkTurnSnapshotLoader,
    W: RequestTalkTurnKernelWorker,
    C: KernelDecisionCommitter
        + TalkTurnRenewalCommitter
        + TalkTurnReleaseCommitter
        + DurableContactStore
        + DurableBeepThreadStore,
{
    let request = read_http_request(stream)?;
    let response = service
        .lock()
        .expect("runtime HTTP service lock should not be poisoned")
        .handle(request);
    write_http_response(stream, &response)?;
    Ok(())
}

pub fn serve_forever_with_committer<S, W, C>(
    listener: &TcpListener,
    service: &Mutex<RuntimeHttpService<S, W, C>>,
) -> Result<(), RuntimeHttpError>
where
    S: RequestTalkTurnSnapshotLoader,
    W: RequestTalkTurnKernelWorker,
    C: KernelDecisionCommitter
        + TalkTurnRenewalCommitter
        + TalkTurnReleaseCommitter
        + DurableContactStore
        + DurableBeepThreadStore,
{
    loop {
        serve_one_connection_with_committer(listener, service)?;
    }
}

fn read_http_request(stream: &mut impl Read) -> Result<HttpRequest, RuntimeHttpError> {
    let mut buffer = Vec::new();
    let mut chunk = [0_u8; 1024];
    let header_end = loop {
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            return Err(RuntimeHttpError::MalformedRequest);
        }
        buffer.extend_from_slice(&chunk[..read]);
        if let Some(header_end) = find_header_end(&buffer) {
            break header_end;
        }
    };
    let headers = std::str::from_utf8(&buffer[..header_end])
        .map_err(|_| RuntimeHttpError::MalformedRequest)?;
    let mut lines = headers.split("\r\n");
    let request_line = lines.next().ok_or(RuntimeHttpError::MalformedRequest)?;
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts
        .next()
        .ok_or(RuntimeHttpError::MalformedRequest)?
        .to_owned();
    let path = request_parts
        .next()
        .ok_or(RuntimeHttpError::MalformedRequest)?
        .to_owned();
    let headers = lines
        .filter_map(parse_header)
        .collect::<Vec<(String, String)>>();
    let content_length = match headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
        .map(|(_, value)| parse_content_length_value(value))
    {
        Some(content_length) => content_length?,
        None if method == "GET" || method == "POST" => 0,
        None => return Err(RuntimeHttpError::MissingContentLength),
    };
    let body_start = header_end + 4;
    while buffer.len() < body_start + content_length {
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            return Err(RuntimeHttpError::MalformedRequest);
        }
        buffer.extend_from_slice(&chunk[..read]);
    }
    Ok(HttpRequest {
        method,
        path,
        headers,
        body: buffer[body_start..body_start + content_length].to_vec(),
    })
}

pub trait ReadWrite: Read + Write {}

impl<T> ReadWrite for T where T: Read + Write {}

fn write_http_response(
    stream: &mut impl Write,
    response: &HttpResponse,
) -> Result<(), RuntimeHttpError> {
    let (content_type, body) = raw_response_parts(&response.body).unwrap_or_else(|| {
        (
            "application/json".to_owned(),
            serde_json::to_vec(&response.body).expect("JSON response body should encode"),
        )
    });
    let status_line = match response.status {
        200 => "HTTP/1.1 200 OK",
        400 => "HTTP/1.1 400 Bad Request",
        404 => "HTTP/1.1 404 Not Found",
        405 => "HTTP/1.1 405 Method Not Allowed",
        409 => "HTTP/1.1 409 Conflict",
        422 => "HTTP/1.1 422 Unprocessable Entity",
        _ => "HTTP/1.1 500 Internal Server Error",
    };
    write!(
        stream,
        "{status_line}\r\ncontent-type: {content_type}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
        body.len()
    )?;
    stream.write_all(&body)?;
    Ok(())
}

fn parse_header(line: &str) -> Option<(String, String)> {
    let (name, value) = line.split_once(':')?;
    Some((name.trim().to_owned(), value.trim().to_owned()))
}

fn parse_content_length_value(value: &str) -> Result<usize, RuntimeHttpError> {
    value
        .trim()
        .parse()
        .map_err(|_| RuntimeHttpError::InvalidContentLength)
}

fn parse_body(bytes: &[u8]) -> Result<Value, RuntimeHttpError> {
    if bytes.is_empty() {
        return Ok(serde_json::json!({}));
    }
    serde_json::from_slice(bytes).map_err(RuntimeHttpError::InvalidJson)
}

fn native_request_conversation_id(path: &str) -> Option<&str> {
    let parts = control_plane_path_parts(path);
    match parts.as_slice() {
        [
            "v1",
            "conversations",
            conversation_id,
            "talk-turns",
            "request",
        ] => Some(*conversation_id),
        _ => None,
    }
}

fn native_release_conversation_id(path: &str) -> Option<&str> {
    let parts = control_plane_path_parts(path);
    match parts.as_slice() {
        [
            "v1",
            "conversations",
            conversation_id,
            "talk-turns",
            "release",
        ] => Some(*conversation_id),
        _ => None,
    }
}

fn native_renew_conversation_id(path: &str) -> Option<&str> {
    let parts = control_plane_path_parts(path);
    match parts.as_slice() {
        [
            "v1",
            "conversations",
            conversation_id,
            "talk-turns",
            "renew",
        ] => Some(*conversation_id),
        _ => None,
    }
}

fn legacy_begin_transmit_channel_id(path: &str) -> Option<&str> {
    let parts = control_plane_path_parts(path);
    match parts.as_slice() {
        ["v1", "channels", channel_id, "begin-transmit"] => Some(*channel_id),
        _ => None,
    }
}

fn legacy_renew_transmit_channel_id(path: &str) -> Option<&str> {
    let parts = control_plane_path_parts(path);
    match parts.as_slice() {
        ["v1", "channels", channel_id, "renew-transmit"] => Some(*channel_id),
        _ => None,
    }
}

fn legacy_end_transmit_channel_id(path: &str) -> Option<&str> {
    let parts = control_plane_path_parts(path);
    match parts.as_slice() {
        ["v1", "channels", channel_id, "end-transmit"] => Some(*channel_id),
        _ => None,
    }
}

fn is_health_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "health"]
}

fn is_config_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "config"]
}

fn is_auth_session_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "auth", "session"]
}

fn is_profile_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "profile"]
}

fn is_device_register_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "devices", "register"]
}

fn presence_status_path(path: &str) -> Option<&'static str> {
    match control_plane_path_parts(path).as_slice() {
        ["v1", "presence", "heartbeat"] => Some("online"),
        ["v1", "presence", "offline"] => Some("offline"),
        ["v1", "presence", "background"] => Some("background"),
        _ => None,
    }
}

fn is_telemetry_events_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "telemetry", "events"]
}

fn is_diagnostics_upload_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "dev", "diagnostics"]
}

fn latest_diagnostics_device_id(path: &str) -> Option<&str> {
    match control_plane_path_parts(path).as_slice() {
        ["v1", "dev", "diagnostics", "latest", device_id] => Some(*device_id),
        _ => None,
    }
}

fn is_latest_diagnostics_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "dev", "diagnostics", "latest"]
}

fn is_wake_events_recent_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "dev", "wake-events", "recent"]
}

fn is_wake_events_upload_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "dev", "wake-events"]
}

fn is_invariant_events_recent_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "dev", "invariant-events", "recent"]
}

fn is_invariant_events_upload_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "dev", "invariant-events"]
}

fn is_dev_seed_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "dev", "seed"]
}

fn is_dev_reset_path(path: &str) -> bool {
    matches!(
        control_plane_path_parts(path).as_slice(),
        ["v1", "dev", "reset-state"] | ["v1", "dev", "reset-all"]
    )
}

fn is_beeps_list_path(path: &str) -> bool {
    matches!(
        control_plane_path_parts(path).as_slice(),
        ["v1", "beeps", "incoming"] | ["v1", "beeps", "outgoing"]
    )
}

fn beeps_list_direction(path: &str) -> Option<&'static str> {
    match control_plane_path_parts(path).as_slice() {
        ["v1", "beeps", "incoming"] => Some("incoming"),
        ["v1", "beeps", "outgoing"] => Some("outgoing"),
        _ => None,
    }
}

fn is_beep_create_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "beeps"]
}

fn beep_action_path(path: &str) -> Option<(&str, &str)> {
    match control_plane_path_parts(path).as_slice() {
        [
            "v1",
            "beeps",
            beep_id,
            action @ ("accept" | "decline" | "cancel"),
        ] => Some((*beep_id, *action)),
        _ => None,
    }
}

fn is_contact_summaries_path(path: &str) -> bool {
    matches!(
        control_plane_path_parts(path).as_slice(),
        ["v1", "contacts", "summaries", _device_id]
    )
}

fn user_lookup_handle(path: &str) -> Option<&str> {
    match control_plane_path_parts(path).as_slice() {
        ["v1", "users", "by-handle", handle] => Some(*handle),
        _ => None,
    }
}

fn user_presence_handle(path: &str) -> Option<&str> {
    match control_plane_path_parts(path).as_slice() {
        ["v1", "users", "by-handle", handle, "presence"] => Some(*handle),
        _ => None,
    }
}

fn is_identity_resolve_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "identities", "resolve"]
}

fn is_contact_remember_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "contacts", "remember"]
}

fn is_contact_forget_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "contacts", "forget"]
}

fn is_direct_channel_path(path: &str) -> bool {
    control_plane_path_parts(path).as_slice() == ["v1", "channels", "direct"]
}

fn channel_join_path(path: &str) -> Option<&str> {
    match control_plane_path_parts(path).as_slice() {
        ["v1", "channels", channel_id, "join"] => Some(*channel_id),
        _ => None,
    }
}

fn channel_leave_path(path: &str) -> Option<&str> {
    match control_plane_path_parts(path).as_slice() {
        ["v1", "channels", channel_id, "leave"] => Some(*channel_id),
        _ => None,
    }
}

fn channel_ephemeral_token_upload_path(path: &str) -> Option<&str> {
    match control_plane_path_parts(path).as_slice() {
        ["v1", "channels", channel_id, "ephemeral-token"] => Some(*channel_id),
        _ => None,
    }
}

fn channel_ephemeral_token_revoke_path(path: &str) -> Option<&str> {
    match control_plane_path_parts(path).as_slice() {
        ["v1", "channels", channel_id, "ephemeral-token", "revoke"] => Some(*channel_id),
        _ => None,
    }
}

fn channel_state_path(path: &str) -> Option<(&str, &str)> {
    match control_plane_path_parts(path).as_slice() {
        ["v1", "channels", channel_id, "state", device_id] => Some((*channel_id, *device_id)),
        _ => None,
    }
}

fn channel_readiness_path(path: &str) -> Option<(&str, &str)> {
    match control_plane_path_parts(path).as_slice() {
        ["v1", "channels", channel_id, "readiness", device_id] => Some((*channel_id, *device_id)),
        _ => None,
    }
}

fn receiver_audio_readiness_path(path: &str) -> Option<&str> {
    match control_plane_path_parts(path).as_slice() {
        ["v1", "channels", channel_id, "receiver-audio-readiness"] => Some(*channel_id),
        _ => None,
    }
}

fn control_plane_path_parts(path: &str) -> Vec<&str> {
    let parts = path.trim_matches('/').split('/').collect::<Vec<_>>();
    match parts.as_slice() {
        ["s", "turbo", rest @ ..] => rest.to_vec(),
        _ => parts,
    }
}

fn is_apple_app_site_association_path(path: &str) -> bool {
    path.trim_matches('/') == ".well-known/apple-app-site-association"
}

fn did_document_public_id(path: &str) -> Option<&str> {
    match path
        .trim_matches('/')
        .split('/')
        .collect::<Vec<_>>()
        .as_slice()
    {
        ["id", public_id, "did.json"] => Some(*public_id),
        _ => None,
    }
}

fn share_page_public_id(path: &str) -> Option<String> {
    let parts = path.trim_matches('/').split('/').collect::<Vec<_>>();
    match parts.as_slice() {
        [single]
            if !single.is_empty()
                && !single.starts_with('.')
                && !matches!(*single, "s" | "v1" | "id" | "p") =>
        {
            Some(
                normalize_path_token(single)
                    .trim_start_matches('@')
                    .to_owned(),
            )
        }
        ["p", public_id] if !public_id.is_empty() => Some(
            normalize_path_token(public_id)
                .trim_start_matches('@')
                .to_owned(),
        ),
        _ => None,
    }
}

fn apple_app_site_association_response() -> Value {
    serde_json::json!({
        "applinks": {
            "details": [
                {
                    "appIDs": ["7MQU7TLQQ2.com.rounded.Turbo"],
                    "components": [
                        { "/": "/*" },
                        { "/": "/@*" },
                        { "/": "/p/*" },
                        { "/": "/id/*/did.json" }
                    ]
                }
            ]
        }
    })
}

fn did_document_response(handle: &str, public_base_url: &str) -> Value {
    let normalized = normalize_handle(handle);
    let public_id = normalized.trim_start_matches('@');
    let share_link = format!("{}/{}", public_base_url.trim_end_matches('/'), public_id);
    serde_json::json!({
        "@context": ["https://www.w3.org/ns/did/v1"],
        "id": format!("did:web:{}:id:{}", did_host(public_base_url), public_id),
        "alsoKnownAs": [share_link],
        "service": []
    })
}

fn sanitized_direct_quic_identity(body: &Value) -> Option<Value> {
    let identity = body.get("directQuicIdentity")?.as_object()?;
    let fingerprint = identity.get("fingerprint")?.as_str()?;
    Some(serde_json::json!({
        "fingerprint": fingerprint,
        "status": identity
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("active")
    }))
}

fn raw_html_response(html: String) -> Value {
    serde_json::json!({
        "__turboRuntimeRawContentType": "text/html; charset=utf-8",
        "__turboRuntimeRawBody": html
    })
}

fn raw_response_parts(body: &Value) -> Option<(String, Vec<u8>)> {
    Some((
        body.get("__turboRuntimeRawContentType")?
            .as_str()?
            .to_owned(),
        body.get("__turboRuntimeRawBody")?
            .as_str()?
            .as_bytes()
            .to_vec(),
    ))
}

fn share_page_html(handle: &str, profile_name: &str, public_base_url: &str) -> String {
    let normalized = normalize_handle(handle);
    let public_id = normalized.trim_start_matches('@');
    let share_link = format!("{}/{}", public_base_url.trim_end_matches('/'), public_id);
    let escaped_profile_name = html_escape(profile_name);
    let escaped_handle = html_escape(&normalized);
    let escaped_share_link = html_escape(&share_link);
    let encoded_share_link = percent_encode_query_component(&share_link);
    format!(
        r#"<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="apple-itunes-app" content="app-id=6762493911, app-argument={escaped_share_link}">
  <title>{escaped_profile_name} on BeepBeep</title>
</head>
<body>
  <main>
    <h1>{escaped_profile_name}</h1>
    <p>{escaped_handle}</p>
    <a href="{escaped_share_link}">Open in BeepBeep</a>
    <p>{escaped_share_link}</p>
    <div id="qr">
      <img alt="QR code" src="https://api.qrserver.com/v1/create-qr-code/?size=240x240&amp;data={encoded_share_link}">
    </div>
    <p>Android is not supported yet.</p>
  </main>
</body>
</html>"#
    )
}

fn request_handle(request: &HttpRequest) -> &str {
    header_value(request, "x-turbo-user-handle")
        .or_else(|| header_value(request, "authorization").and_then(bearer_handle))
        .unwrap_or("@self")
}

fn request_public_base_url(request: &HttpRequest) -> String {
    let proto = header_value(request, "x-forwarded-proto").unwrap_or_else(|| {
        if header_value(request, "host").is_some_and(|host| host.starts_with("localhost")) {
            "http"
        } else {
            "https"
        }
    });
    let host = header_value(request, "host").unwrap_or("localhost");
    format!("{proto}://{host}")
}

fn header_value<'a>(request: &'a HttpRequest, name: &str) -> Option<&'a str> {
    request
        .headers
        .iter()
        .find(|(header_name, _)| header_name.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

fn bearer_handle(value: &str) -> Option<&str> {
    value
        .strip_prefix("Bearer ")
        .filter(|handle| handle.starts_with('@'))
}

fn auth_session_response_with_profile_name(
    handle: &str,
    profile_name: &str,
    public_base_url: &str,
) -> Value {
    let handle = normalize_identity_reference(handle);
    let user_id = user_id_for_handle(&handle);
    let public_id = handle.trim_start_matches('@');
    serde_json::json!({
        "userId": user_id,
        "handle": handle,
        "publicId": public_id,
        "displayName": handle,
        "profileName": profile_name,
        "shareCode": public_id,
        "shareLink": format!("{}/{}", public_base_url.trim_end_matches('/'), public_id),
        "did": format!("did:web:{}:id:{}", did_host(public_base_url), public_id),
        "subjectKind": "human"
    })
}

fn user_id_for_handle(handle: &str) -> String {
    format!("user-{}", handle.trim_start_matches('@'))
}

fn handle_for_user_id(user_id: &str) -> String {
    format!("@{}", user_id.strip_prefix("user-").unwrap_or(user_id))
}

fn contact_peer_handle_from_body(body: &Value) -> String {
    path_value(body, &["otherHandle"])
        .and_then(Value::as_str)
        .map(normalize_handle)
        .or_else(|| {
            path_value(body, &["otherUserId"])
                .and_then(Value::as_str)
                .map(handle_for_user_id)
        })
        .unwrap_or_else(|| "@self".to_owned())
}

fn channel_id_for_pair(first_handle: &str, second_handle: &str) -> String {
    let first_user_id = user_id_for_handle(first_handle);
    let second_user_id = user_id_for_handle(second_handle);
    let (low_user_id, high_user_id) = sorted_pair(first_user_id, second_user_id);
    format!("direct-{low_user_id}-{high_user_id}")
}

fn normalize_handle(handle: &str) -> String {
    normalize_identity_reference(handle)
}

fn normalize_identity_reference(reference: &str) -> String {
    let decoded = normalize_path_token(reference.trim());
    let decoded_lower = decoded.to_lowercase();
    if let Some(id) = decoded_lower
        .strip_prefix("did:web:")
        .and_then(|rest| rest.rsplit_once(":id:").map(|(_, id)| id))
    {
        return normalize_handle_body(id);
    }
    if let Some(path) = decoded_lower
        .strip_prefix("https://")
        .or_else(|| decoded_lower.strip_prefix("http://"))
        .and_then(|rest| rest.split_once('/').map(|(_, path)| path))
    {
        let first = path.split(['/', '?', '#']).next().unwrap_or("").trim();
        if !first.is_empty() && first != "p" && first != "id" {
            return normalize_handle_body(first);
        }
        let mut parts = path.split('/');
        if matches!(parts.next(), Some("p" | "id")) {
            if let Some(id) = parts.next() {
                return normalize_handle_body(id);
            }
        }
    }
    normalize_handle_body(&decoded)
}

fn normalize_handle_body(decoded: &str) -> String {
    if decoded.starts_with('@') {
        decoded.to_owned()
    } else {
        format!("@{decoded}")
    }
}

fn user_lookup_response(
    handle: &str,
    profile_name: &str,
    is_online: bool,
    public_base_url: &str,
) -> Value {
    let normalized = normalize_handle(handle);
    let public_id = normalized.trim_start_matches('@');
    serde_json::json!({
        "userId": user_id_for_handle(&normalized),
        "handle": normalized,
        "publicId": public_id,
        "displayName": profile_name,
        "profileName": profile_name,
        "shareCode": public_id,
        "shareLink": format!("{}/{}", public_base_url.trim_end_matches('/'), public_id),
        "did": format!("did:web:{}:id:{}", did_host(public_base_url), public_id),
        "subjectKind": "human",
        "isOnline": is_online
    })
}

fn did_host(public_base_url: &str) -> &str {
    public_base_url
        .strip_prefix("https://")
        .or_else(|| public_base_url.strip_prefix("http://"))
        .unwrap_or(public_base_url)
        .trim_end_matches('/')
}

fn diagnostics_report(handle: &str, body: &Value) -> Result<Value, RuntimeHttpError> {
    let normalized = normalize_handle(handle);
    Ok(serde_json::json!({
        "userId": user_id_for_handle(&normalized),
        "deviceId": required_string(body, &["deviceId"], "deviceId")?,
        "appVersion": required_string(body, &["appVersion"], "appVersion")?,
        "backendBaseURL": required_string(body, &["backendBaseURL"], "backendBaseURL")?,
        "selectedHandle": body.get("selectedHandle").cloned().unwrap_or(Value::Null),
        "snapshot": required_string(body, &["snapshot"], "snapshot")?,
        "transcript": required_string(body, &["transcript"], "transcript")?,
        "uploadedAt": "1970-01-01T00:00:00Z"
    }))
}

fn dev_event(handle: &str, body: &Value) -> Value {
    let normalized = normalize_handle(handle);
    let mut event = body.as_object().cloned().unwrap_or_default();
    event
        .entry("handle".to_owned())
        .or_insert_with(|| Value::String(normalized.clone()));
    event
        .entry("userId".to_owned())
        .or_insert_with(|| Value::String(user_id_for_handle(&normalized)));
    event
        .entry("recordedAt".to_owned())
        .or_insert_with(|| Value::String("1970-01-01T00:00:00Z".to_owned()));
    event
        .entry("uploadedAt".to_owned())
        .or_insert_with(|| Value::String("1970-01-01T00:00:00Z".to_owned()));
    Value::Object(event)
}

fn beep_response(beep: &DurableBeepThread, handle: &str) -> Value {
    let normalized_handle = normalize_handle(handle);
    let direction = if beep.to_handle == normalized_handle {
        "incoming"
    } else {
        "outgoing"
    };
    serde_json::json!({
        "beepId": beep.beep_id,
        "fromUserId": user_id_for_handle(&beep.from_handle),
        "fromHandle": beep.from_handle,
        "toUserId": user_id_for_handle(&beep.to_handle),
        "toHandle": beep.to_handle,
        "channelId": beep.channel_id,
        "status": beep.status,
        "direction": direction,
        "requestCount": beep.request_count,
        "createdAt": "1970-01-01T00:00:00Z",
        "updatedAt": "1970-01-01T00:00:00Z",
        "subject": null,
        "targetAvailability": "online",
        "shouldAutoJoinFriend": false,
        "accepted": beep.status == "connected",
        "pendingJoin": beep.status == "pending"
    })
}

fn beep_thread_projection_payload(
    has_incoming_beep: bool,
    has_outgoing_beep: bool,
    request_count: u64,
) -> Value {
    let kind = match (has_incoming_beep, has_outgoing_beep) {
        (true, true) => "mutual",
        (true, false) => "incoming",
        (false, true) => "outgoing",
        (false, false) => "none",
    };
    if kind == "none" {
        serde_json::json!({ "kind": kind })
    } else {
        serde_json::json!({
            "kind": kind,
            "requestCount": request_count.max(1)
        })
    }
}

fn membership_payload(self_joined: bool, peer_joined: bool, peer_device_connected: bool) -> Value {
    match (self_joined, peer_joined) {
        (false, false) => serde_json::json!({ "kind": "absent" }),
        (true, false) => serde_json::json!({ "kind": "self-only" }),
        (false, true) => serde_json::json!({
            "kind": "peer-only",
            "peerDeviceConnected": peer_device_connected
        }),
        (true, true) => serde_json::json!({
            "kind": "both",
            "peerDeviceConnected": peer_device_connected
        }),
    }
}

fn summary_status_kind(
    has_incoming_beep: bool,
    has_outgoing_beep: bool,
    self_joined: bool,
    peer_joined: bool,
    peer_device_connected: bool,
    active_transmitter_is_self: Option<bool>,
) -> &'static str {
    if let Some(is_self) = active_transmitter_is_self {
        if is_self { "talking" } else { "receiving" }
    } else if has_incoming_beep {
        "incoming"
    } else if has_outgoing_beep {
        "outgoing-beep"
    } else if self_joined && peer_joined && !peer_device_connected {
        "online"
    } else if self_joined || peer_joined {
        "ready"
    } else {
        "online"
    }
}

fn active_transmitter_for_handle(channel: Option<&RuntimeChannel>, handle: &str) -> Option<bool> {
    let active_handle = channel?.active_transmitter_handle.as_deref()?;
    Some(active_handle == normalize_handle(handle))
}

fn active_transmitter_user_id(channel: Option<&RuntimeChannel>) -> Option<String> {
    channel?
        .active_transmitter_handle
        .as_deref()
        .map(user_id_for_handle)
}

fn active_transmit_expires_at_value(channel: Option<&RuntimeChannel>) -> Value {
    channel
        .and_then(|channel| channel.active_transmit_expires_at_ms)
        .map(runtime_iso8601_utc_millis)
        .map(Value::String)
        .unwrap_or(Value::Null)
}

fn runtime_now_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or(0)
}

fn runtime_app_transmit_expires_at_ms() -> u128 {
    runtime_now_millis() + u128::from(APP_COMPATIBLE_TRANSMIT_LEASE_MS)
}

fn parse_env_bool(value: &str) -> bool {
    !matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "0" | "false" | "no" | "off"
    )
}

fn clear_expired_app_transmit(channel: &mut RuntimeChannel, now_ms: u128) {
    if channel
        .active_transmit_expires_at_ms
        .is_some_and(|expires_at_ms| expires_at_ms <= now_ms)
    {
        channel.active_transmit_id = None;
        channel.active_transmitter_handle = None;
        channel.active_transmit_expires_at_ms = None;
    }
}

fn runtime_iso8601_utc_millis(ms: u128) -> String {
    let total_seconds = (ms / 1_000) as i128;
    let millisecond = (ms % 1_000) as u32;
    let days = total_seconds.div_euclid(86_400);
    let seconds_of_day = total_seconds.rem_euclid(86_400);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    let (year, month, day) = runtime_civil_from_days(days);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{millisecond:03}Z")
}

fn runtime_civil_from_days(days_since_unix_epoch: i128) -> (i128, u32, u32) {
    let days = days_since_unix_epoch + 719_468;
    let era = if days >= 0 { days } else { days - 146_096 } / 146_097;
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_phase = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_phase + 2) / 5 + 1;
    let month = month_phase + if month_phase < 10 { 3 } else { -9 };
    if month <= 2 {
        year += 1;
    }
    (year, month as u32, day as u32)
}

fn peer_user_id_for_channel(channel_id: &str, self_user_id: &str) -> String {
    channel_id
        .strip_prefix("direct-")
        .and_then(|rest| rest.split_once('-'))
        .map(|(a, b)| if a == self_user_id { b } else { a })
        .unwrap_or("user-peer")
        .to_owned()
}

fn sorted_pair(a: String, b: String) -> (String, String) {
    if a <= b { (a, b) } else { (b, a) }
}

fn normalize_path_token(value: &str) -> String {
    value.replace("%40", "@").replace("%2F", "/")
}

fn html_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn percent_encode_query_component(value: &str) -> String {
    value
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

fn legacy_begin_transmit_input(
    channel_id: &str,
    body: &Value,
) -> Result<LegacyBeginTransmitInput, RuntimeHttpError> {
    Ok(LegacyBeginTransmitInput {
        channel_id: channel_id.to_owned(),
        device_id: required_string(body, &["deviceId"], "deviceId")?.to_owned(),
        requesting_participant_id: required_string(
            body,
            &["requestingParticipantId"],
            "requestingParticipantId",
        )?
        .to_owned(),
        requesting_session_epoch: required_u64(
            body,
            &["requestingSessionEpoch"],
            "requestingSessionEpoch",
        )?,
        target_participant_id: required_string(
            body,
            &["targetParticipantId"],
            "targetParticipantId",
        )?
        .to_owned(),
        operation_id: required_string(body, &["operationId"], "operationId")?.to_owned(),
        policy_version: required_string(body, &["policyVersion"], "policyVersion")?.to_owned(),
        kernel_version: required_string(body, &["kernelVersion"], "kernelVersion")?.to_owned(),
    })
}

fn legacy_renew_transmit_command(
    channel_id: &str,
    body: &Value,
) -> Result<Value, RuntimeHttpError> {
    let device_id = required_string(body, &["deviceId"], "deviceId")?.to_owned();
    let transmit_id = path_value(body, &["transmitId"])
        .and_then(Value::as_str)
        .map(str::to_owned);
    let operation_id = transmit_id
        .as_deref()
        .map(|transmit_id| format!("renew-transmit-{transmit_id}"))
        .unwrap_or_else(|| format!("renew-transmit-{channel_id}-{device_id}"));
    let mut command = serde_json::json!({
        "kind": "renew-talk-turn",
        "conversationId": { "value": channel_id },
        "deviceId": device_id,
        "operationId": operation_id,
        "policyVersion": { "value": "policy-v1" },
        "maxTalkTurnLeaseMs": 15_000,
        "grantsEnabled": true,
        "ownerRuntimeId": "runtime-single",
        "ownerEpoch": { "value": 1 },
        "ownerLeaseExpiresAtMs": 9_223_372_036_854_775_i64
    });
    if let Some(transmit_id) = transmit_id {
        command["transmitId"] = Value::String(transmit_id);
    }
    Ok(command)
}

fn legacy_renew_transmit_response(native_body: &Value) -> Value {
    serde_json::json!({
        "status": "transmitting",
        "transmitId": native_body["talkTurnEpoch"].as_u64().map(|epoch| epoch.to_string()),
        "expiresAtMs": native_body["expiresAtMs"].clone(),
    })
}

fn legacy_end_transmit_command(channel_id: &str, body: &Value) -> Result<Value, RuntimeHttpError> {
    let device_id = required_string(body, &["deviceId"], "deviceId")?.to_owned();
    let transmit_id = path_value(body, &["transmitId"])
        .and_then(Value::as_str)
        .map(str::to_owned);
    let operation_id = transmit_id
        .as_deref()
        .map(|transmit_id| format!("end-transmit-{transmit_id}"))
        .unwrap_or_else(|| format!("end-transmit-{channel_id}-{device_id}"));
    let mut command = serde_json::json!({
        "kind": "release-talk-turn",
        "conversationId": { "value": channel_id },
        "deviceId": device_id,
        "operationId": operation_id,
        "ownerRuntimeId": "runtime-single",
        "ownerEpoch": { "value": 1 },
        "ownerLeaseExpiresAtMs": 9_223_372_036_854_775_i64
    });
    if let Some(transmit_id) = transmit_id {
        command["transmitId"] = Value::String(transmit_id);
    }
    Ok(command)
}

fn legacy_end_transmit_response(native_body: &Value) -> Value {
    serde_json::json!({
        "channelId": native_body["conversationId"].clone(),
        "status": "stopped",
    })
}

fn required_string<'a>(
    value: &'a Value,
    path: &[&str],
    label: &'static str,
) -> Result<&'a str, RuntimeHttpError> {
    path_value(value, path)
        .and_then(Value::as_str)
        .ok_or(RuntimeHttpError::MissingField(label))
}

fn required_u64(
    value: &Value,
    path: &[&str],
    label: &'static str,
) -> Result<u64, RuntimeHttpError> {
    path_value(value, path)
        .and_then(Value::as_u64)
        .ok_or(RuntimeHttpError::MissingField(label))
}

fn path_value<'a>(value: &'a Value, path: &[&str]) -> Option<&'a Value> {
    path.iter().try_fold(value, |cursor, key| cursor.get(*key))
}

fn find_header_end(bytes: &[u8]) -> Option<usize> {
    bytes.windows(4).position(|window| window == b"\r\n\r\n")
}

fn status_for_error(error: &RuntimeHttpError) -> u16 {
    match error {
        RuntimeHttpError::InvalidJson(_)
        | RuntimeHttpError::MissingField(_)
        | RuntimeHttpError::MalformedRequest
        | RuntimeHttpError::MissingContentLength
        | RuntimeHttpError::InvalidContentLength
        | RuntimeHttpError::Route(RuntimeRouteError::ConversationMismatch { .. })
        | RuntimeHttpError::Route(RuntimeRouteError::UnsupportedCommandKind(_))
        | RuntimeHttpError::Route(RuntimeRouteError::MissingField(_)) => 400,
        RuntimeHttpError::Durable(DurablePostgresError::IdempotencyConflict { .. }) => 409,
        RuntimeHttpError::Durable(
            DurablePostgresError::SnapshotNotFound | DurablePostgresError::KernelDecisionNotFound,
        ) => 422,
        RuntimeHttpError::Durable(DurablePostgresError::TalkTurnRenewalRejected(_)) => 422,
        RuntimeHttpError::Route(RuntimeRouteError::Durable(
            DurablePostgresError::IdempotencyConflict { .. },
        )) => 409,
        RuntimeHttpError::Route(RuntimeRouteError::Durable(
            DurablePostgresError::SnapshotNotFound | DurablePostgresError::KernelDecisionNotFound,
        )) => 422,
        RuntimeHttpError::Route(RuntimeRouteError::Durable(
            DurablePostgresError::TalkTurnRenewalRejected(_),
        )) => 422,
        RuntimeHttpError::Io(_)
        | RuntimeHttpError::Durable(_)
        | RuntimeHttpError::Route(RuntimeRouteError::Durable(_)) => 500,
    }
}

fn error_response(status: u16, message: impl Into<String>) -> HttpResponse {
    HttpResponse {
        status,
        body: serde_json::json!({ "error": message.into() }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        KernelCommandKind, KernelCorpus, KernelCorpusCase,
        postgres::{CorpusKernelDecisionWorker, InMemoryRequestTalkTurnSnapshotLoader},
        routes::SelfHostedRouteService,
    };
    use std::{
        io::{Read, Write},
        net::{Shutdown, TcpListener, TcpStream},
        sync::Arc,
        thread,
    };

    fn corpus() -> KernelCorpus {
        KernelCorpus {
            cases: vec![granted_case(), released_case()],
        }
    }

    fn granted_case() -> KernelCorpusCase {
        KernelCorpusCase {
            id: "http-route-grant".to_owned(),
            kind: KernelCommandKind::RequestTalkTurn,
            command: serde_json::json!({
                "kind": "request-talk-turn",
                "conversationId": { "value": "conversation-1" },
                "requestingParticipantId": { "value": "participant-a" },
                "requestingDeviceId": { "value": "device-a" },
                "requestingSessionEpoch": { "value": 0 },
                "targetParticipantId": { "value": "participant-b" },
                "operationId": "op-http-1",
                "policyVersion": { "value": "policy-v1" },
                "kernelVersion": { "value": "kernel-contract-v1" }
            }),
            snapshot: serde_json::json!({
                "conversationId": { "value": "conversation-1" },
                "snapshotBuiltAtMs": 10000
            }),
            policy: serde_json::json!({ "policyVersion": { "value": "policy-v1" } }),
            expected_decision: serde_json::json!({
                "kind": "granted",
                "grant": {
                    "conversationId": { "value": "conversation-1" },
                    "requestingParticipantId": { "value": "participant-a" },
                    "requestingDeviceId": { "value": "device-a" },
                    "targetParticipantId": { "value": "participant-b" },
                    "targetDeviceId": { "value": "device-b" },
                    "talkTurnEpoch": { "value": 1 },
                    "expiresAtMs": 25000
                },
                "effectPlan": {
                    "transactionEffects": [
                        {
                            "kind": "record-talk-turn",
                            "conversationId": { "value": "conversation-1" },
                            "requestingParticipantId": { "value": "participant-a" },
                            "requestingDeviceId": { "value": "device-a" },
                            "targetParticipantId": { "value": "participant-b" },
                            "targetDeviceId": { "value": "device-b" },
                            "talkTurnEpoch": { "value": 1 },
                            "expiresAtMs": 25000
                        }
                    ],
                    "postCommitEffects": [
                        { "kind": "notify-talk-turn-granted" }
                    ]
                }
            }),
        }
    }

    fn released_case() -> KernelCorpusCase {
        KernelCorpusCase {
            id: "http-route-release".to_owned(),
            kind: KernelCommandKind::ReleaseTalkTurn,
            command: serde_json::json!({
                "kind": "release-talk-turn",
                "conversationId": { "value": "conversation-1" },
                "participantId": { "value": "participant-a" },
                "deviceId": { "value": "device-a" },
                "sessionEpoch": { "value": 0 },
                "talkTurnEpoch": { "value": 1 },
                "operationId": "op-http-release",
                "policyVersion": { "value": "policy-v1" },
                "kernelVersion": { "value": "kernel-contract-v1" }
            }),
            snapshot: serde_json::json!({
                "conversationId": { "value": "conversation-1" },
                "snapshotBuiltAtMs": 10000
            }),
            policy: serde_json::json!({ "policyVersion": { "value": "policy-v1" } }),
            expected_decision: serde_json::json!({
                "kind": "released",
                "effectPlan": {
                    "transactionEffects": [
                        {
                            "kind": "clear-talk-turn",
                            "conversationId": { "value": "conversation-1" },
                            "talkTurnEpoch": { "value": 1 }
                        }
                    ],
                    "postCommitEffects": [
                        {
                            "kind": "notify-talk-turn-released",
                            "conversationId": { "value": "conversation-1" },
                            "participantId": { "value": "participant-a" },
                            "deviceId": { "value": "device-a" },
                            "talkTurnEpoch": { "value": 1 }
                        }
                    ]
                }
            }),
        }
    }

    fn renew_command() -> Value {
        serde_json::json!({
            "kind": "renew-talk-turn",
            "conversationId": { "value": "conversation-1" },
            "participantId": { "value": "participant-a" },
            "deviceId": { "value": "device-a" },
            "talkTurnEpoch": { "value": 1 },
            "operationId": "op-http-renew",
            "nowMs": 20_000,
            "policyVersion": { "value": "policy-v1" },
            "maxTalkTurnLeaseMs": 15_000,
            "grantsEnabled": true,
            "ownerRuntimeId": "runtime-a",
            "ownerEpoch": { "value": 1 },
            "ownerLeaseExpiresAtMs": 60_000
        })
    }

    fn service()
    -> RuntimeHttpService<InMemoryRequestTalkTurnSnapshotLoader, CorpusKernelDecisionWorker> {
        service_with_config(RuntimeHttpConfig::default())
    }

    fn service_with_config(
        runtime_config: RuntimeHttpConfig,
    ) -> RuntimeHttpService<InMemoryRequestTalkTurnSnapshotLoader, CorpusKernelDecisionWorker> {
        service_with_config_and_committer(
            runtime_config,
            crate::postgres::DurableConversationStore::default(),
        )
    }

    fn service_with_config_and_committer(
        runtime_config: RuntimeHttpConfig,
        committer: crate::postgres::DurableConversationStore,
    ) -> RuntimeHttpService<InMemoryRequestTalkTurnSnapshotLoader, CorpusKernelDecisionWorker> {
        let corpus = corpus();
        let loader = InMemoryRequestTalkTurnSnapshotLoader::from_cases(corpus.cases.iter());
        let worker = CorpusKernelDecisionWorker::new(&corpus);
        RuntimeHttpService::new_with_config(
            SelfHostedRouteService::with_committer(loader, worker, committer),
            runtime_config,
        )
    }

    #[test]
    fn self_hosted_config_advertises_direct_quic_capabilities_from_runtime_config() {
        let mut service = service_with_config(RuntimeHttpConfig {
            supports_websocket: true,
            supports_direct_quic_upgrade: true,
            supports_direct_quic_provisioning: true,
            supports_media_end_to_end_encryption: false,
            apns_worker: None,
        });

        let response = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/config".to_owned(),
            headers: Vec::new(),
            body: Vec::new(),
        });

        assert_eq!(response.status, 200);
        assert_eq!(response.body["mode"], "self-hosted");
        assert_eq!(response.body["supportsWebSocket"], true);
        assert_eq!(response.body["supportsDirectQuicUpgrade"], true);
        assert_eq!(response.body["supportsDirectQuicProvisioning"], true);
        assert_eq!(response.body["supportsMediaEndToEndEncryption"], false);
        assert_eq!(response.body["supportsSignalSessionIds"], true);
        assert_eq!(response.body["supportsTransmitIds"], true);
        assert_eq!(response.body["supportsProjectionEpochs"], true);
    }

    #[test]
    fn self_hosted_http_route_probe_creates_and_lists_beeps_by_direction() {
        let mut service = service();
        let create = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/beeps".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({
                "friendHandle": "@blake",
                "operationId": "connect-1"
            }))
            .expect("body should encode"),
        });

        assert_eq!(create.status, 200);
        assert_eq!(create.body["direction"], "outgoing");
        assert_eq!(create.body["fromHandle"], "@avery");
        assert_eq!(create.body["toHandle"], "@blake");

        let outgoing = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/beeps/outgoing".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let incoming = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/beeps/incoming".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(outgoing.body.as_array().expect("outgoing list").len(), 1);
        assert_eq!(incoming.body.as_array().expect("incoming list").len(), 1);
        assert_eq!(incoming.body[0]["direction"], "incoming");
    }

    #[test]
    fn self_hosted_http_route_probe_accepts_profile_update_during_bootstrap() {
        let mut service = service();
        let response = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/profile".to_owned(),
            headers: vec![
                ("host".to_owned(), "api.beepbeep.to".to_owned()),
                ("x-forwarded-proto".to_owned(), "https".to_owned()),
                ("x-turbo-user-handle".to_owned(), "@avery".to_owned()),
            ],
            body: serde_json::to_vec(&serde_json::json!({
                "profileName": "Avery"
            }))
            .expect("body should encode"),
        });

        assert_eq!(response.status, 200);
        assert_eq!(response.body["handle"], "@avery");
        assert_eq!(response.body["profileName"], "Avery");
        assert_eq!(response.body["shareCode"], "avery");
        assert_eq!(response.body["shareLink"], "https://api.beepbeep.to/avery");
        assert_eq!(response.body["did"], "did:web:api.beepbeep.to:id:avery");

        let durable_committer_after_restart = service.route_service().committer().clone();
        let mut restarted_service = service_with_config_and_committer(
            RuntimeHttpConfig::default(),
            durable_committer_after_restart,
        );
        let lookup = restarted_service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/users/by-handle/avery".to_owned(),
            headers: vec![
                ("host".to_owned(), "api.beepbeep.to".to_owned()),
                ("x-forwarded-proto".to_owned(), "https".to_owned()),
            ],
            body: Vec::new(),
        });
        assert_eq!(lookup.status, 200);
        assert_eq!(lookup.body["profileName"], "Avery");
    }

    #[test]
    fn self_hosted_http_route_probe_resolves_share_url_to_handle() {
        let mut service = service();
        let response = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/identities/resolve".to_owned(),
            headers: vec![
                ("host".to_owned(), "api.beepbeep.to".to_owned()),
                ("x-forwarded-proto".to_owned(), "https".to_owned()),
                ("x-turbo-user-handle".to_owned(), "@avery".to_owned()),
            ],
            body: serde_json::to_vec(&serde_json::json!({
                "reference": "https://api.beepbeep.to/mau"
            }))
            .expect("body should encode"),
        });

        assert_eq!(response.status, 200);
        assert_eq!(response.body["handle"], "@mau");
        assert_eq!(response.body["publicId"], "mau");
        assert_eq!(response.body["shareLink"], "https://api.beepbeep.to/mau");
    }

    #[test]
    fn self_hosted_http_route_probe_serves_profile_share_page() {
        let mut service = service();
        let profile = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/profile".to_owned(),
            headers: vec![
                ("host".to_owned(), "api.beepbeep.to".to_owned()),
                ("x-forwarded-proto".to_owned(), "https".to_owned()),
                ("x-turbo-user-handle".to_owned(), "@avery".to_owned()),
            ],
            body: serde_json::to_vec(&serde_json::json!({
                "profileName": "Avery Radio"
            }))
            .expect("body should encode"),
        });
        assert_eq!(profile.status, 200);

        let page = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/avery".to_owned(),
            headers: vec![
                ("host".to_owned(), "api.beepbeep.to".to_owned()),
                ("x-forwarded-proto".to_owned(), "https".to_owned()),
            ],
            body: Vec::new(),
        });

        assert_eq!(page.status, 200);
        let html = page.body["__turboRuntimeRawBody"]
            .as_str()
            .expect("share page should be raw HTML");
        assert!(html.contains("Open in BeepBeep"));
        assert!(html.contains("https://api.beepbeep.to/avery"));
        assert!(html.contains("Avery Radio"));
        assert!(html.contains("apple-itunes-app"));
        assert!(html.contains("app-id=6762493911"));
        assert!(html.contains("id=\"qr\""));
        assert!(html.contains("api.qrserver.com/v1/create-qr-code/"));
        assert!(html.contains("Android is not supported yet."));
    }

    #[test]
    fn self_hosted_http_route_probe_serves_did_document() {
        let mut service = service();
        let response = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/id/avery/did.json".to_owned(),
            headers: vec![
                ("host".to_owned(), "api.beepbeep.to".to_owned()),
                ("x-forwarded-proto".to_owned(), "https".to_owned()),
            ],
            body: Vec::new(),
        });

        assert_eq!(response.status, 200);
        assert_eq!(response.body["id"], "did:web:api.beepbeep.to:id:avery");
        assert_eq!(
            response.body["alsoKnownAs"][0],
            "https://api.beepbeep.to/avery"
        );
    }

    #[test]
    fn self_hosted_http_route_probe_preserves_direct_quic_identity_on_device_register() {
        let mut service = service();
        let first = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/devices/register".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({
                "deviceId": "device-a",
                "deviceLabel": "Avery Phone",
                "directQuicIdentity": {
                    "fingerprint": "sha256:test",
                    "certificateDerBase64": "must-not-leak"
                }
            }))
            .expect("body should encode"),
        });

        assert_eq!(first.status, 200);
        assert_eq!(
            first.body["directQuicIdentity"]["fingerprint"],
            "sha256:test"
        );
        assert_eq!(first.body["directQuicIdentity"]["status"], "active");
        assert!(first.body["directQuicIdentity"]["certificateDerBase64"].is_null());

        let second = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/devices/register".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({
                "deviceId": "device-a",
                "deviceLabel": "Avery Phone"
            }))
            .expect("body should encode"),
        });

        assert_eq!(second.status, 200);
        assert_eq!(
            second.body["directQuicIdentity"]["fingerprint"],
            "sha256:test"
        );
        assert!(second.body["directQuicIdentity"]["certificateDerBase64"].is_null());
    }

    #[test]
    fn self_hosted_http_route_probe_marks_diagnostics_upload_as_uploaded() {
        let mut service = service();
        let upload = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/dev/diagnostics".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({
                "deviceId": "device-a",
                "appVersion": "route-probe:device-a",
                "backendBaseURL": "https://api.beepbeep.to",
                "selectedHandle": "@blake",
                "snapshot": "snapshot",
                "transcript": "transcript"
            }))
            .expect("body should encode"),
        });

        assert_eq!(upload.status, 200);
        assert_eq!(upload.body["status"], "uploaded");

        let latest = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/dev/diagnostics/latest/device-a".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(latest.status, 200);
        assert_eq!(latest.body["status"], "ok");
        assert_eq!(latest.body["report"]["deviceId"], "device-a");
    }

    #[test]
    fn self_hosted_http_route_probe_refreshes_reciprocal_beep_thread() {
        let mut service = service();
        let first = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/beeps".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "friendHandle": "@blake" }))
                .expect("body should encode"),
        });
        let reciprocal = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/beeps".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "friendHandle": "@avery" }))
                .expect("body should encode"),
        });

        assert_eq!(first.body["beepId"], reciprocal.body["beepId"]);
        assert_eq!(reciprocal.body["requestCount"], 2);
        assert_eq!(reciprocal.body["direction"], "outgoing");

        let avery_incoming = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/beeps/incoming".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(avery_incoming.body[0]["requestCount"], 2);
        assert_eq!(avery_incoming.body[0]["direction"], "incoming");
    }

    #[test]
    fn self_hosted_http_route_probe_accepts_stale_beep_id_through_current_alias() {
        let mut service = service();
        let original = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/beeps".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "friendHandle": "@blake" }))
                .expect("body should encode"),
        });
        let original_beep_id = original.body["beepId"].as_str().expect("original beep id");
        let cancel = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/beeps/{original_beep_id}/cancel"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(cancel.status, 200);

        let replacement = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/beeps".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "friendHandle": "@blake" }))
                .expect("body should encode"),
        });
        let replacement_beep_id = replacement.body["beepId"]
            .as_str()
            .expect("replacement beep id");
        assert_ne!(original_beep_id, replacement_beep_id);

        let accept = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/beeps/{original_beep_id}/accept"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(accept.status, 200);
        assert_eq!(accept.body["beepId"], replacement.body["beepId"]);
        assert_eq!(accept.body["status"], "connected");
        assert_eq!(accept.body["accepted"], true);
    }

    #[test]
    fn self_hosted_http_route_probe_remember_contact_is_reciprocal_and_summary_durable() {
        let mut service = service();

        let blake_profile = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/profile".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "profileName": "Blake" }))
                .expect("body should encode"),
        });
        assert_eq!(blake_profile.status, 200);

        let remember = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/contacts/remember".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        assert_eq!(remember.status, 200);
        assert_eq!(remember.body["status"], "remembered");
        assert_eq!(remember.body["otherUserId"], user_id_for_handle("@blake"));

        let avery_summaries = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-a".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let blake_summaries = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-b".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(avery_summaries.body.as_array().expect("summaries").len(), 1);
        assert_eq!(blake_summaries.body.as_array().expect("summaries").len(), 1);
        assert_eq!(avery_summaries.body[0]["handle"], "@blake");
        assert_eq!(avery_summaries.body[0]["publicId"], "@blake");
        assert_eq!(avery_summaries.body[0]["profileName"], "Blake");
        assert_eq!(blake_summaries.body[0]["handle"], "@avery");
        assert_eq!(blake_summaries.body[0]["publicId"], "@avery");
        assert_eq!(
            avery_summaries.body[0]["channelId"],
            channel_id_for_pair("@avery", "@blake")
        );
        assert_eq!(
            blake_summaries.body[0]["channelId"],
            channel_id_for_pair("@avery", "@blake")
        );
        assert_eq!(
            avery_summaries.body[0]["beepThreadProjection"]["kind"],
            "none"
        );
        assert_eq!(avery_summaries.body[0]["membership"]["kind"], "absent");
        assert_eq!(avery_summaries.body[0]["summaryStatus"]["kind"], "online");

        let durable_committer_after_restart = service.route_service().committer().clone();
        let mut restarted_service = service_with_config_and_committer(
            RuntimeHttpConfig::default(),
            durable_committer_after_restart,
        );
        let restarted_avery_summaries = restarted_service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-a".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let restarted_blake_summaries = restarted_service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-b".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(
            restarted_avery_summaries.body[0]["handle"], "@blake",
            "remembered contacts must survive RuntimeHttpService rebuild"
        );
        assert_eq!(
            restarted_avery_summaries.body[0]["profileName"], "Blake",
            "remembered contact profile names must survive RuntimeHttpService rebuild"
        );
        assert_eq!(
            restarted_blake_summaries.body[0]["handle"], "@avery",
            "reciprocal remembered contact must survive RuntimeHttpService rebuild"
        );
    }

    #[test]
    fn self_hosted_http_route_probe_forget_contact_is_account_local() {
        let mut service = service();

        let remember = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/contacts/remember".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        assert_eq!(remember.status, 200);

        let forget = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/contacts/forget".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        assert_eq!(forget.status, 200);
        assert_eq!(forget.body["status"], "forgotten");

        let avery_summaries = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-a".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let blake_summaries = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-b".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(avery_summaries.body.as_array().expect("summaries").len(), 0);
        assert_eq!(blake_summaries.body.as_array().expect("summaries").len(), 1);
        assert_eq!(blake_summaries.body[0]["handle"], "@avery");
    }

    #[test]
    fn self_hosted_http_direct_channel_projects_contact_summary() {
        let mut service = service();

        let direct = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/direct".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        assert_eq!(direct.status, 200);

        let summaries = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-a".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let summary = summaries
            .body
            .as_array()
            .expect("summaries")
            .iter()
            .find(|summary| summary["handle"] == "@blake")
            .expect("direct channel peer should be projected");

        assert_eq!(summary["channelId"], direct.body["channelId"]);
        assert_eq!(summary["hasIncomingBeep"], false);
        assert_eq!(summary["hasOutgoingBeep"], false);
        assert!(summary["membership"].is_object());
        assert!(summary["summaryStatus"].is_object());
    }

    #[test]
    fn self_hosted_http_route_probe_projects_beeps_in_contact_summaries() {
        let mut service = service();
        let create = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/beeps".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "friendHandle": "@blake" }))
                .expect("body should encode"),
        });
        let channel_id = create.body["channelId"].as_str().expect("channel id");

        let sender_summaries = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-a".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let recipient_summaries = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-b".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(sender_summaries.body[0]["handle"], "@blake");
        assert_eq!(sender_summaries.body[0]["publicId"], "@blake");
        assert_eq!(sender_summaries.body[0]["channelId"], channel_id);
        assert_eq!(
            sender_summaries.body[0]["beepThreadProjection"]["kind"],
            "outgoing"
        );
        assert_eq!(
            sender_summaries.body[0]["summaryStatus"]["kind"],
            "outgoing-beep"
        );
        assert_eq!(sender_summaries.body[0]["badgeStatus"], "outgoing-beep");
        assert_eq!(sender_summaries.body[0]["membership"]["kind"], "absent");
        assert_eq!(
            recipient_summaries.body[0]["beepThreadProjection"]["kind"],
            "incoming"
        );
        assert_eq!(
            recipient_summaries.body[0]["summaryStatus"]["kind"],
            "incoming"
        );
        assert_eq!(recipient_summaries.body[0]["hasIncomingBeep"], true);
        assert_eq!(recipient_summaries.body[0]["requestCount"], 1);
    }

    #[test]
    fn self_hosted_http_route_probe_cancelled_beep_does_not_leave_ghost_contact_summary() {
        let mut service = service();
        let create = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/beeps".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "friendHandle": "@blake" }))
                .expect("body should encode"),
        });
        let beep_id = create.body["beepId"].as_str().expect("beep id");

        let cancel = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/beeps/{beep_id}/cancel"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(cancel.status, 200);

        let avery_summaries = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-a".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let blake_summaries = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-b".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(avery_summaries.body.as_array().expect("summaries").len(), 0);
        assert_eq!(blake_summaries.body.as_array().expect("summaries").len(), 0);
    }

    #[test]
    fn self_hosted_http_route_probe_projects_pending_beep_in_channel_state() {
        let mut service = service();
        let create = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/beeps".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({
                "friendHandle": "@blake",
                "operationId": "connect-1"
            }))
            .expect("body should encode"),
        });
        let channel_id = create.body["channelId"].as_str().expect("channel id");

        let sender_state = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let recipient_state = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });
        let recipient_readiness = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/readiness/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(
            sender_state.body["beepThreadProjection"]["kind"],
            "outgoing"
        );
        assert_eq!(
            sender_state.body["conversationStatus"]["kind"],
            "outgoing-beep"
        );
        assert_eq!(sender_state.body["membership"]["kind"], "absent");
        assert_eq!(sender_state.body["canTransmit"], false);
        assert_eq!(
            recipient_state.body["beepThreadProjection"]["kind"],
            "incoming"
        );
        assert_eq!(
            recipient_state.body["conversationStatus"]["kind"],
            "incoming-beep"
        );
        assert_eq!(recipient_state.body["membership"]["kind"], "absent");
        assert_eq!(recipient_readiness.body["readiness"]["kind"], "inactive");
        assert_eq!(recipient_readiness.body["selfHasActiveDevice"], false);
    }

    #[test]
    fn self_hosted_http_receiver_ready_during_pending_beep_does_not_join_membership() {
        let mut service = service();
        let create = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/beeps".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({
                "friendHandle": "@blake",
                "operationId": "connect-1"
            }))
            .expect("body should encode"),
        });
        let channel_id = create.body["channelId"].as_str().expect("channel id");

        let receiver_ready = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/receiver-audio-readiness"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({
                "deviceId": "device-b",
                "type": "receiver-ready",
                "payload": "foreground-beep-prewarm"
            }))
            .expect("body should encode"),
        });
        assert_eq!(receiver_ready.status, 200);

        let sender_state = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let recipient_state = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(
            sender_state.body["conversationStatus"]["kind"],
            "outgoing-beep"
        );
        assert_eq!(sender_state.body["membership"]["kind"], "absent");
        assert_eq!(
            recipient_state.body["conversationStatus"]["kind"],
            "incoming-beep"
        );
        assert_eq!(recipient_state.body["membership"]["kind"], "absent");
    }

    #[test]
    fn self_hosted_http_pending_beep_suppresses_stale_joined_membership_projection() {
        let mut service = service();
        let channel = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/direct".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        let channel_id = channel.body["channelId"]
            .as_str()
            .expect("channel id")
            .to_owned();

        for (handle, device_id) in [("@avery", "device-a"), ("@blake", "device-b")] {
            let join = service.handle(HttpRequest {
                method: "POST".to_owned(),
                path: format!("/v1/channels/{channel_id}/join"),
                headers: vec![("x-turbo-user-handle".to_owned(), handle.to_owned())],
                body: serde_json::to_vec(&serde_json::json!({ "deviceId": device_id }))
                    .expect("body should encode"),
            });
            assert_eq!(join.status, 200);
        }

        let create = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/beeps".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({
                "friendHandle": "@blake",
                "operationId": "connect-2"
            }))
            .expect("body should encode"),
        });
        assert_eq!(
            create.body["channelId"]
                .as_str()
                .expect("created channel id"),
            channel_id
        );

        let sender_state = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let recipient_state = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });
        let sender_readiness = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/readiness/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let recipient_summaries = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-b".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(
            sender_state.body["conversationStatus"]["kind"],
            "outgoing-beep"
        );
        assert_eq!(sender_state.body["membership"]["kind"], "absent");
        assert_eq!(sender_state.body["canTransmit"], false);
        assert_eq!(
            recipient_state.body["conversationStatus"]["kind"],
            "incoming-beep"
        );
        assert_eq!(recipient_state.body["membership"]["kind"], "absent");
        assert_eq!(sender_readiness.body["readiness"]["kind"], "inactive");
        assert_eq!(sender_readiness.body["selfHasActiveDevice"], false);
        assert_eq!(sender_readiness.body["peerHasActiveDevice"], false);
        assert_eq!(
            sender_readiness.body["audioReadiness"]["self"]["kind"],
            "unknown"
        );
        assert_eq!(
            sender_readiness.body["audioReadiness"]["peer"]["kind"],
            "unknown"
        );
        assert_eq!(
            recipient_summaries.body[0]["beepThreadProjection"]["kind"],
            "incoming"
        );
        assert_eq!(recipient_summaries.body[0]["membership"]["kind"], "absent");
        assert_eq!(recipient_summaries.body[0]["selfJoined"], false);
        assert_eq!(recipient_summaries.body[0]["peerJoined"], false);
    }

    #[test]
    fn self_hosted_http_websocket_receiver_ready_during_pending_beep_does_not_join_membership() {
        let mut service = service();
        let create = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/beeps".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({
                "friendHandle": "@blake",
                "operationId": "connect-1"
            }))
            .expect("body should encode"),
        });
        let channel_id = create.body["channelId"]
            .as_str()
            .expect("channel id")
            .to_owned();

        service.observe_app_compatible_control_command(
            "receiver-ready",
            "user-blake",
            "device-b",
            Some(&channel_id),
            Some("foreground-beep-prewarm"),
        );

        let sender_state = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let recipient_state = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(sender_state.body["membership"]["kind"], "absent");
        assert_eq!(recipient_state.body["membership"]["kind"], "absent");
        assert_eq!(
            sender_state.body["beepThreadProjection"]["kind"],
            "outgoing"
        );
        assert_eq!(
            recipient_state.body["beepThreadProjection"]["kind"],
            "incoming"
        );
    }

    #[test]
    fn self_hosted_http_route_probe_projects_join_membership_by_perspective() {
        let mut service = service();
        for (handle, device_id, fingerprint) in [
            ("@avery", "device-a", "sha256:avery-direct-quic"),
            ("@blake", "device-b", "sha256:blake-direct-quic"),
        ] {
            let register = service.handle(HttpRequest {
                method: "POST".to_owned(),
                path: "/v1/devices/register".to_owned(),
                headers: vec![("x-turbo-user-handle".to_owned(), handle.to_owned())],
                body: serde_json::to_vec(&serde_json::json!({
                    "deviceId": device_id,
                    "deviceLabel": device_id,
                    "directQuicIdentity": {
                        "fingerprint": fingerprint,
                        "certificateDerBase64": "must-not-leak"
                    }
                }))
                .expect("body should encode"),
            });
            assert_eq!(register.status, 200);
        }

        let channel = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/direct".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        let channel_id = channel.body["channelId"].as_str().expect("channel id");

        let join_blake = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/join"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-b" }))
                .expect("body should encode"),
        });
        assert_eq!(join_blake.status, 200);

        let a_state_after_b_join = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let b_state_after_b_join = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(a_state_after_b_join.body["membership"]["kind"], "peer-only");
        assert_eq!(
            a_state_after_b_join.body["conversationStatus"]["kind"],
            "waiting-for-peer"
        );
        assert_eq!(b_state_after_b_join.body["membership"]["kind"], "self-only");

        let a_summaries_after_b_join = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-a".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let b_summaries_after_b_join = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-b".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(
            a_summaries_after_b_join.body[0]["membership"]["kind"],
            "peer-only"
        );
        assert_eq!(
            a_summaries_after_b_join.body[0]["summaryStatus"]["kind"],
            "ready"
        );
        assert_eq!(a_summaries_after_b_join.body[0]["selfJoined"], false);
        assert_eq!(a_summaries_after_b_join.body[0]["peerJoined"], true);
        assert_eq!(
            b_summaries_after_b_join.body[0]["membership"]["kind"],
            "self-only"
        );
        assert_eq!(
            b_summaries_after_b_join.body[0]["summaryStatus"]["kind"],
            "ready"
        );

        let join_avery = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/join"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-a" }))
                .expect("body should encode"),
        });
        assert_eq!(join_avery.status, 200);

        let a_state_after_both_join = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let a_readiness_after_both_join = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/readiness/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(a_state_after_both_join.body["membership"]["kind"], "both");
        assert_eq!(
            a_state_after_both_join.body["conversationStatus"]["kind"],
            "ready"
        );
        assert_eq!(a_state_after_both_join.body["canTransmit"], true);
        assert_eq!(
            a_readiness_after_both_join.body["readiness"]["kind"],
            "ready"
        );
        assert_eq!(
            a_readiness_after_both_join.body["selfHasActiveDevice"],
            true
        );
        assert_eq!(
            a_readiness_after_both_join.body["peerHasActiveDevice"],
            true
        );
        assert_eq!(
            a_readiness_after_both_join.body["peerDirectQuicIdentity"]["fingerprint"],
            "sha256:blake-direct-quic"
        );
        assert_eq!(
            a_readiness_after_both_join.body["peerDirectQuicIdentity"]["status"],
            "active"
        );
        assert!(
            a_readiness_after_both_join.body["peerDirectQuicIdentity"]["certificateDerBase64"]
                .is_null()
        );

        let a_summaries_after_both_join = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-a".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(
            a_summaries_after_both_join.body[0]["membership"]["kind"],
            "both"
        );
        assert_eq!(
            a_summaries_after_both_join.body[0]["summaryStatus"]["kind"],
            "ready"
        );
        assert_eq!(
            a_summaries_after_both_join.body[0]["beepThreadProjection"]["kind"],
            "none"
        );
    }

    #[test]
    fn self_hosted_http_route_probe_preserves_last_sender_after_passive_leave() {
        let mut service = service();
        let channel = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/direct".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        let channel_id = channel.body["channelId"].as_str().expect("channel id");
        for (handle, device_id) in [("@avery", "device-a"), ("@blake", "device-b")] {
            let join = service.handle(HttpRequest {
                method: "POST".to_owned(),
                path: format!("/v1/channels/{channel_id}/join"),
                headers: vec![("x-turbo-user-handle".to_owned(), handle.to_owned())],
                body: serde_json::to_vec(&serde_json::json!({ "deviceId": device_id }))
                    .expect("body should encode"),
            });
            assert_eq!(join.status, 200);
        }

        let begin = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/begin-transmit"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-a" }))
                .expect("body should encode"),
        });
        assert_eq!(begin.status, 200);
        let end = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/end-transmit"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-a" }))
                .expect("body should encode"),
        });
        assert_eq!(end.status, 200);

        let leave_blake = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/leave"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-b" }))
                .expect("body should encode"),
        });
        assert_eq!(leave_blake.status, 200);

        let a_first_projection = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(a_first_projection.body["membership"]["kind"], "self-only");

        let b_projection = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(b_projection.body["membership"]["kind"], "peer-only");

        let a_after_repeated_projection = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(
            a_after_repeated_projection.body["membership"]["kind"],
            "self-only"
        );
    }

    #[test]
    fn self_hosted_http_route_probe_projects_app_compatible_transmit_state() {
        let mut service = service();
        let channel = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/direct".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        let channel_id = channel.body["channelId"].as_str().expect("channel id");
        for (handle, device_id) in [("@avery", "device-a"), ("@blake", "device-b")] {
            let join = service.handle(HttpRequest {
                method: "POST".to_owned(),
                path: format!("/v1/channels/{channel_id}/join"),
                headers: vec![("x-turbo-user-handle".to_owned(), handle.to_owned())],
                body: serde_json::to_vec(&serde_json::json!({ "deviceId": device_id }))
                    .expect("body should encode"),
            });
            assert_eq!(join.status, 200);
        }

        let begin = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/begin-transmit"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-a" }))
                .expect("body should encode"),
        });
        assert_eq!(begin.status, 200);
        assert_eq!(begin.body["status"], "transmitting");
        assert_eq!(begin.body["targetUserId"], "user-blake");
        assert_eq!(begin.body["targetDeviceId"], "device-b");

        let sender_state = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        let recipient_state = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(
            sender_state.body["conversationStatus"]["kind"],
            "self-transmitting"
        );
        assert_eq!(
            recipient_state.body["conversationStatus"]["kind"],
            "peer-transmitting"
        );
        assert_eq!(
            sender_state.body["conversationStatus"]["activeTransmitterUserId"],
            "user-avery"
        );

        let end = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/end-transmit"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-a" }))
                .expect("body should encode"),
        });
        assert_eq!(end.status, 200);
        let sender_after_end = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(sender_after_end.body["conversationStatus"]["kind"], "ready");
    }

    #[test]
    fn self_hosted_http_route_probe_expires_app_compatible_transmit_lease() {
        let mut service = service();
        let channel = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/direct".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        let channel_id = channel.body["channelId"].as_str().expect("channel id");
        for (handle, device_id) in [("@avery", "device-a"), ("@blake", "device-b")] {
            let join = service.handle(HttpRequest {
                method: "POST".to_owned(),
                path: format!("/v1/channels/{channel_id}/join"),
                headers: vec![("x-turbo-user-handle".to_owned(), handle.to_owned())],
                body: serde_json::to_vec(&serde_json::json!({ "deviceId": device_id }))
                    .expect("body should encode"),
            });
            assert_eq!(join.status, 200);
        }

        let begin = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/begin-transmit"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-a" }))
                .expect("body should encode"),
        });
        assert_eq!(begin.status, 200);
        assert_eq!(begin.body["status"], "transmitting");
        assert_ne!(begin.body["expiresAt"], "2999-01-01T00:00:00Z");

        service
            .state
            .channels
            .get_mut(channel_id)
            .expect("channel should exist")
            .active_transmit_expires_at_ms = Some(runtime_now_millis().saturating_sub(1));

        let sender_state = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-a"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(sender_state.body["conversationStatus"]["kind"], "ready");
        assert_eq!(sender_state.body["activeTransmitId"], Value::Null);
        assert_eq!(sender_state.body["transmitLeaseExpiresAt"], Value::Null);

        let delayed_renew = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/renew-transmit"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-a" }))
                .expect("body should encode"),
        });
        assert_eq!(delayed_renew.status, 409);
        assert_eq!(
            delayed_renew.body["error"],
            "no active transmit state for sender"
        );
    }

    #[test]
    fn self_hosted_http_route_probe_wake_token_revocation_clears_active_transmit() {
        let mut service = service();
        let channel = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/direct".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        let channel_id = channel.body["channelId"].as_str().expect("channel id");
        for (handle, device_id) in [("@avery", "device-a"), ("@blake", "device-b")] {
            let join = service.handle(HttpRequest {
                method: "POST".to_owned(),
                path: format!("/v1/channels/{channel_id}/join"),
                headers: vec![("x-turbo-user-handle".to_owned(), handle.to_owned())],
                body: serde_json::to_vec(&serde_json::json!({ "deviceId": device_id }))
                    .expect("body should encode"),
            });
            assert_eq!(join.status, 200);
        }
        service.mark_channel_wake_disconnected(channel_id, "@avery", "device-a");
        service.record_ephemeral_token(
            channel_id,
            "@avery",
            "device-a",
            "wake-token-a",
            Some("sandbox".to_owned()),
        );

        let begin = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/begin-transmit"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-b" }))
                .expect("body should encode"),
        });
        assert_eq!(begin.status, 200);

        let revoke = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/ephemeral-token/revoke"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-a" }))
                .expect("body should encode"),
        });
        assert_eq!(revoke.status, 200);

        let sender_state = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/state/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(
            sender_state.body["conversationStatus"]["kind"],
            "waiting-for-peer"
        );
        assert_eq!(sender_state.body["activeTransmitId"], Value::Null);
        assert_eq!(sender_state.body["canTransmit"], false);

        let sender_readiness = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/readiness/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(
            sender_readiness.body["readiness"]["kind"],
            "waiting-for-peer"
        );
        assert_eq!(
            sender_readiness.body["wakeReadiness"]["peer"]["kind"],
            "unavailable"
        );
    }

    #[test]
    fn self_hosted_begin_transmit_sends_worker_wake_for_wake_capable_peer() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("worker listener should bind");
        let worker_address = listener.local_addr().expect("worker address should exist");
        let worker = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("worker should accept request");
            let mut request = vec![0_u8; 8192];
            let read = stream
                .read(&mut request)
                .expect("worker should read request");
            let request = String::from_utf8_lossy(&request[..read]);
            assert!(request.starts_with("POST /apns/send HTTP/1.1"));
            assert!(request.contains("x-turbo-worker-secret: secret"));
            assert!(request.contains("wake-token-a"));
            assert!(request.contains("\"event\":\"transmit-start\""));
            assert!(request.contains("\"senderDeviceId\":\"device-b\""));
            assert!(request.contains("\"sandbox\":true"));
            let body = br#"{"ok":true,"result":"sent","status":200,"reason":null}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
                body.len(),
                String::from_utf8_lossy(body)
            );
            stream
                .write_all(response.as_bytes())
                .expect("worker should write response");
        });

        let mut service = service_with_config(RuntimeHttpConfig {
            supports_websocket: false,
            apns_worker: Some(RuntimeApnsWorkerConfig {
                base_url: format!("http://{worker_address}"),
                secret: "secret".to_owned(),
                bundle_id: "com.rounded.Turbo".to_owned(),
                use_sandbox: true,
                timeout_ms: 1_000,
            }),
            ..RuntimeHttpConfig::default()
        });
        let channel = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/direct".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        let channel_id = channel.body["channelId"].as_str().expect("channel id");
        for (handle, device_id) in [("@avery", "device-a"), ("@blake", "device-b")] {
            let join = service.handle(HttpRequest {
                method: "POST".to_owned(),
                path: format!("/v1/channels/{channel_id}/join"),
                headers: vec![("x-turbo-user-handle".to_owned(), handle.to_owned())],
                body: serde_json::to_vec(&serde_json::json!({ "deviceId": device_id }))
                    .expect("body should encode"),
            });
            assert_eq!(join.status, 200);
        }
        service.mark_channel_wake_disconnected(channel_id, "@avery", "device-a");
        service.record_ephemeral_token(
            channel_id,
            "@avery",
            "device-a",
            "wake-token-a",
            Some("sandbox".to_owned()),
        );

        let begin = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/begin-transmit"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-b" }))
                .expect("body should encode"),
        });
        assert_eq!(begin.status, 200);
        assert_eq!(begin.body["status"], "transmitting");
        assert_eq!(begin.body["targetDeviceId"], "device-a");

        let wake_events = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/dev/wake-events/recent".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(wake_events.status, 200);
        let event = wake_events.body["events"][0]
            .as_object()
            .expect("wake event should be an object");
        assert_eq!(event["result"], "sent");
        assert_eq!(event["statusCode"], "200");
        assert_eq!(event["channelId"], channel_id);
        assert_eq!(event["senderDeviceId"], "device-b");
        assert_eq!(event["targetDeviceId"], "device-a");
        assert_eq!(event["startedAt"], begin.body["startedAt"]);

        worker.join().expect("worker should finish");
    }

    #[test]
    fn self_hosted_leave_channel_sends_worker_leave_to_peer_token() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("worker listener should bind");
        let worker_address = listener.local_addr().expect("worker address should exist");
        let worker = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("worker should accept request");
            let mut request = vec![0_u8; 8192];
            let read = stream
                .read(&mut request)
                .expect("worker should read request");
            let request = String::from_utf8_lossy(&request[..read]);
            assert!(request.starts_with("POST /apns/send HTTP/1.1"));
            assert!(request.contains("x-turbo-worker-secret: secret"));
            assert!(request.contains("wake-token-b"));
            assert!(request.contains("\"event\":\"leave-channel\""));
            assert!(request.contains("\"activeSpeaker\":\"@avery\""));
            assert!(request.contains("\"senderDeviceId\":\"device-a\""));
            let body = br#"{"ok":true,"result":"sent","status":200,"reason":null}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
                body.len(),
                String::from_utf8_lossy(body)
            );
            stream
                .write_all(response.as_bytes())
                .expect("worker should write response");
        });

        let mut service = service_with_config(RuntimeHttpConfig {
            supports_websocket: false,
            apns_worker: Some(RuntimeApnsWorkerConfig {
                base_url: format!("http://{worker_address}"),
                secret: "secret".to_owned(),
                bundle_id: "com.rounded.Turbo".to_owned(),
                use_sandbox: true,
                timeout_ms: 1_000,
            }),
            ..RuntimeHttpConfig::default()
        });
        let channel = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/direct".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        let channel_id = channel.body["channelId"].as_str().expect("channel id");
        for (handle, device_id) in [("@avery", "device-a"), ("@blake", "device-b")] {
            let join = service.handle(HttpRequest {
                method: "POST".to_owned(),
                path: format!("/v1/channels/{channel_id}/join"),
                headers: vec![("x-turbo-user-handle".to_owned(), handle.to_owned())],
                body: serde_json::to_vec(&serde_json::json!({ "deviceId": device_id }))
                    .expect("body should encode"),
            });
            assert_eq!(join.status, 200);
        }
        service.record_ephemeral_token(
            channel_id,
            "@blake",
            "device-b",
            "wake-token-b",
            Some("sandbox".to_owned()),
        );

        let leave = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: format!("/v1/channels/{channel_id}/leave"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-a" }))
                .expect("body should encode"),
        });
        assert_eq!(leave.status, 200);

        let wake_events = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/dev/wake-events/recent".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(wake_events.status, 200);
        let event = wake_events.body["events"][0]
            .as_object()
            .expect("wake event should be an object");
        assert_eq!(event["event"], "leave-channel");
        assert_eq!(event["result"], "sent");
        assert_eq!(event["statusCode"], "200");
        assert_eq!(event["channelId"], channel_id);
        assert_eq!(event["senderDeviceId"], "device-a");
        assert_eq!(event["targetDeviceId"], "device-b");

        worker.join().expect("worker should finish");
    }

    #[test]
    fn self_hosted_http_route_probe_websocket_disconnect_degrades_joined_peer() {
        let mut service = service();
        let channel = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/direct".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "otherHandle": "@blake" }))
                .expect("body should encode"),
        });
        let channel_id = channel.body["channelId"].as_str().expect("channel id");
        for (handle, device_id) in [("@avery", "device-a"), ("@blake", "device-b")] {
            let join = service.handle(HttpRequest {
                method: "POST".to_owned(),
                path: format!("/v1/channels/{channel_id}/join"),
                headers: vec![("x-turbo-user-handle".to_owned(), handle.to_owned())],
                body: serde_json::to_vec(&serde_json::json!({ "deviceId": device_id }))
                    .expect("body should encode"),
            });
            assert_eq!(join.status, 200);
        }
        service.record_ephemeral_token(
            channel_id,
            "@avery",
            "device-a",
            "wake-token-a",
            Some("sandbox".to_owned()),
        );

        service.observe_app_compatible_websocket_disconnected(
            "user-avery",
            "device-a",
            "app-compatible-conversation",
        );

        let peer_after_disconnect = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/readiness/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(
            peer_after_disconnect.body["readiness"]["kind"],
            "waiting-for-peer"
        );
        assert_eq!(peer_after_disconnect.body["peerHasActiveDevice"], false);
        assert_eq!(
            peer_after_disconnect.body["wakeReadiness"]["peer"]["kind"],
            "wake-capable"
        );
        let peer_summaries_after_disconnect = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-b".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(
            peer_summaries_after_disconnect.body[0]["membership"]["kind"],
            "both"
        );
        assert_eq!(
            peer_summaries_after_disconnect.body[0]["membership"]["peerDeviceConnected"],
            false
        );
        assert_eq!(
            peer_summaries_after_disconnect.body[0]["summaryStatus"]["kind"],
            "online"
        );

        let heartbeat = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/presence/heartbeat".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({ "deviceId": "device-a" }))
                .expect("body should encode"),
        });
        assert_eq!(heartbeat.status, 200);
        let peer_after_heartbeat = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/readiness/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(
            peer_after_heartbeat.body["readiness"]["kind"],
            "waiting-for-peer"
        );
        assert_eq!(peer_after_heartbeat.body["peerHasActiveDevice"], false);

        service.observe_app_compatible_websocket_connected(
            "user-avery",
            "device-a",
            "app-compatible-conversation",
        );

        let peer_after_reconnect = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: format!("/v1/channels/{channel_id}/readiness/device-b"),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });
        assert_eq!(peer_after_reconnect.body["readiness"]["kind"], "ready");
        assert_eq!(peer_after_reconnect.body["peerHasActiveDevice"], true);
    }

    #[test]
    fn self_hosted_http_route_probe_dev_reset_clears_beeps() {
        let mut service = service();
        let create = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/beeps".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: serde_json::to_vec(&serde_json::json!({
                "friendHandle": "@blake",
                "operationId": "connect-1"
            }))
            .expect("body should encode"),
        });
        assert_eq!(create.status, 200);

        let reset = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/dev/reset-state".to_owned(),
            headers: Vec::new(),
            body: serde_json::json!({}).to_string().into_bytes(),
        });
        let incoming = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/beeps/incoming".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@blake".to_owned())],
            body: Vec::new(),
        });
        let summaries = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/v1/contacts/summaries/device-a".to_owned(),
            headers: vec![("x-turbo-user-handle".to_owned(), "@avery".to_owned())],
            body: Vec::new(),
        });

        assert_eq!(reset.body["clearedBeeps"], 1);
        assert_eq!(incoming.body.as_array().expect("incoming list").len(), 0);
        assert_eq!(summaries.body.as_array().expect("summary list").len(), 0);
    }

    #[test]
    fn self_hosted_http_route_probe_handles_native_request_talk_turn() {
        let mut service = service();
        let response = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/conversations/conversation-1/talk-turns/request".to_owned(),
            headers: Vec::new(),
            body: serde_json::to_vec(&granted_case().command).expect("command should encode"),
        });

        assert_eq!(response.status, 200);
        assert_eq!(response.body["status"], "granted");
        assert_eq!(response.body["conversationId"], "conversation-1");
        assert_eq!(
            service
                .route_service()
                .store()
                .current_talk_turn("conversation-1")
                .map(|turn| turn.target_device_id.as_str()),
            Some("device-b")
        );
    }

    #[test]
    fn self_hosted_http_route_probe_handles_native_release_talk_turn() {
        let mut service = service();
        let grant = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/conversations/conversation-1/talk-turns/request".to_owned(),
            headers: Vec::new(),
            body: serde_json::to_vec(&granted_case().command).expect("command should encode"),
        });
        assert_eq!(grant.status, 200);
        assert_eq!(grant.body["status"], "granted");

        let release = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/conversations/conversation-1/talk-turns/release".to_owned(),
            headers: Vec::new(),
            body: serde_json::to_vec(&released_case().command).expect("command should encode"),
        });

        assert_eq!(release.status, 200);
        assert_eq!(release.body["status"], "released");
        assert_eq!(release.body["talkTurnEpoch"], 1);
        assert!(
            service
                .route_service()
                .store()
                .current_talk_turn("conversation-1")
                .is_none()
        );
        assert_eq!(
            service.route_service().store().talk_turn_actor_events()[0].event_kind,
            "talk-turn-released"
        );
    }

    #[test]
    fn self_hosted_http_route_probe_handles_native_renew_talk_turn() {
        let mut service = service();
        let grant = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/conversations/conversation-1/talk-turns/request".to_owned(),
            headers: Vec::new(),
            body: serde_json::to_vec(&granted_case().command).expect("command should encode"),
        });
        assert_eq!(grant.status, 200);

        let renew = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/conversations/conversation-1/talk-turns/renew".to_owned(),
            headers: Vec::new(),
            body: serde_json::to_vec(&renew_command()).expect("command should encode"),
        });

        assert_eq!(renew.status, 200);
        assert_eq!(renew.body["status"], "renewed");
        assert_eq!(renew.body["expiresAtMs"], 35_000);
        assert_eq!(
            service
                .route_service()
                .store()
                .current_talk_turn("conversation-1")
                .map(|turn| turn.expires_at_ms),
            Some(35_000)
        );
    }

    #[test]
    fn self_hosted_http_route_probe_handles_legacy_begin_transmit() {
        let mut service = service();
        let response = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/conversation-1/begin-transmit".to_owned(),
            headers: Vec::new(),
            body: serde_json::to_vec(&serde_json::json!({
                "deviceId": "device-a",
                "requestingParticipantId": "participant-a",
                "requestingSessionEpoch": 0,
                "targetParticipantId": "participant-b",
                "operationId": "op-http-1",
                "policyVersion": "policy-v1",
                "kernelVersion": "kernel-contract-v1"
            }))
            .expect("body should encode"),
        });

        assert_eq!(response.status, 200);
        assert_eq!(response.body["status"], "transmitting");
        assert_eq!(response.body["channelId"], "conversation-1");
        assert_eq!(response.body["transmitId"], "1");
    }

    #[test]
    fn self_hosted_http_route_probe_handles_legacy_renew_transmit() {
        let mut service = service();
        let begin = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/conversation-1/begin-transmit".to_owned(),
            headers: Vec::new(),
            body: serde_json::to_vec(&serde_json::json!({
                "deviceId": "device-a",
                "requestingParticipantId": "participant-a",
                "requestingSessionEpoch": 0,
                "targetParticipantId": "participant-b",
                "operationId": "op-http-1",
                "policyVersion": "policy-v1",
                "kernelVersion": "kernel-contract-v1"
            }))
            .expect("body should encode"),
        });
        assert_eq!(begin.status, 200);

        let renew = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/conversation-1/renew-transmit".to_owned(),
            headers: Vec::new(),
            body: serde_json::to_vec(&serde_json::json!({
                "deviceId": "device-a"
            }))
            .expect("body should encode"),
        });

        assert_eq!(renew.status, 200);
        assert_eq!(renew.body["status"], "transmitting");
        assert_eq!(renew.body["transmitId"], "1");
        assert_eq!(renew.body["expiresAtMs"], 35_000);
    }

    #[test]
    fn self_hosted_http_route_probe_handles_legacy_end_transmit() {
        let mut service = service();
        let begin = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/conversation-1/begin-transmit".to_owned(),
            headers: Vec::new(),
            body: serde_json::to_vec(&serde_json::json!({
                "deviceId": "device-a",
                "requestingParticipantId": "participant-a",
                "requestingSessionEpoch": 0,
                "targetParticipantId": "participant-b",
                "operationId": "op-http-1",
                "policyVersion": "policy-v1",
                "kernelVersion": "kernel-contract-v1"
            }))
            .expect("body should encode"),
        });
        assert_eq!(begin.status, 200);

        let end = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/channels/conversation-1/end-transmit".to_owned(),
            headers: Vec::new(),
            body: serde_json::to_vec(&serde_json::json!({
                "deviceId": "device-a"
            }))
            .expect("body should encode"),
        });

        assert_eq!(end.status, 200);
        assert_eq!(end.body["channelId"], "conversation-1");
        assert_eq!(end.body["status"], "stopped");
        assert!(
            service
                .route_service()
                .store()
                .current_talk_turn("conversation-1")
                .is_none()
        );
    }

    #[test]
    fn self_hosted_http_route_probe_accepts_app_compatible_prefix() {
        let mut service = service();
        let response = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/s/turbo/v1/conversations/conversation-1/talk-turns/request".to_owned(),
            headers: Vec::new(),
            body: serde_json::to_vec(&granted_case().command).expect("command should encode"),
        });

        assert_eq!(response.status, 200);
        assert_eq!(response.body["status"], "granted");
        assert_eq!(response.body["conversationId"], "conversation-1");
    }

    #[test]
    fn self_hosted_http_route_probe_serves_app_compatible_health() {
        let mut service = service();
        let response = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/s/turbo/v1/health".to_owned(),
            headers: Vec::new(),
            body: Vec::new(),
        });

        assert_eq!(response.status, 200);
        assert_eq!(response.body["status"], "ok");
        assert_eq!(response.body["runtime"], "self-hosted");
    }

    #[test]
    fn self_hosted_http_route_probe_serves_apple_app_site_association() {
        let mut service = service();
        let response = service.handle(HttpRequest {
            method: "GET".to_owned(),
            path: "/.well-known/apple-app-site-association".to_owned(),
            headers: Vec::new(),
            body: Vec::new(),
        });

        assert_eq!(response.status, 200);
        let details = response.body["applinks"]["details"]
            .as_array()
            .expect("AASA details should be an array");
        let first = details.first().expect("AASA should include app details");
        assert_eq!(first["appIDs"][0], "7MQU7TLQQ2.com.rounded.Turbo");
        let components = first["components"]
            .as_array()
            .expect("AASA components should be an array");
        let paths = components
            .iter()
            .filter_map(|component| component.get("/").and_then(Value::as_str))
            .collect::<BTreeSet<_>>();
        assert!(paths.contains("/*"));
        assert!(paths.contains("/@*"));
        assert!(paths.contains("/p/*"));
        assert!(paths.contains("/id/*/did.json"));
    }

    #[test]
    fn self_hosted_http_route_probe_maps_bad_input_to_400() {
        let mut service = service();
        let response = service.handle(HttpRequest {
            method: "POST".to_owned(),
            path: "/v1/conversations/other/talk-turns/request".to_owned(),
            headers: Vec::new(),
            body: serde_json::to_vec(&granted_case().command).expect("command should encode"),
        });

        assert_eq!(response.status, 400);
        assert!(
            response.body["error"]
                .as_str()
                .expect("error should be string")
                .contains("path conversation")
        );
    }

    #[test]
    fn self_hosted_http_route_probe_serves_one_tcp_request() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener
            .local_addr()
            .expect("listener address should exist");
        let service = Arc::new(Mutex::new(service()));
        let server_service = service.clone();
        let server = thread::spawn(move || {
            serve_one_connection(&listener, &server_service)
                .expect("single HTTP request should be served");
        });
        let body = serde_json::to_string(&granted_case().command).expect("command should encode");
        let mut stream = TcpStream::connect(address).expect("client should connect");
        write!(
            stream,
            "POST /v1/conversations/conversation-1/talk-turns/request HTTP/1.1\r\nhost: localhost\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
            body.len(),
            body
        )
        .expect("request should write");
        stream
            .shutdown(Shutdown::Write)
            .expect("request write side should close");
        let mut response = String::new();
        stream
            .read_to_string(&mut response)
            .expect("response should read");
        server.join().expect("server thread should join");

        assert!(response.starts_with("HTTP/1.1 200 OK"));
        assert!(response.contains(r#""status":"granted""#));
    }

    #[test]
    fn self_hosted_http_route_probe_serves_get_without_content_length() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener
            .local_addr()
            .expect("listener address should exist");
        let service = Arc::new(Mutex::new(service()));
        let server_service = service.clone();
        let server = thread::spawn(move || {
            serve_one_connection(&listener, &server_service)
                .expect("single HTTP request should be served");
        });
        let mut stream = TcpStream::connect(address).expect("client should connect");
        write!(
            stream,
            "GET /s/turbo/v1/health HTTP/1.1\r\nhost: localhost\r\n\r\n",
        )
        .expect("request should write");
        stream
            .shutdown(Shutdown::Write)
            .expect("request write side should close");
        let mut response = String::new();
        stream
            .read_to_string(&mut response)
            .expect("response should read");
        server.join().expect("server thread should join");

        assert!(response.starts_with("HTTP/1.1 200 OK"));
        assert!(response.contains(r#""runtime":"self-hosted""#));
    }

    #[test]
    fn self_hosted_http_route_probe_serves_empty_post_without_content_length() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener
            .local_addr()
            .expect("listener address should exist");
        let service = Arc::new(Mutex::new(service()));
        let server_service = service.clone();
        let server = thread::spawn(move || {
            serve_one_connection(&listener, &server_service)
                .expect("single HTTP request should be served");
        });
        let mut stream = TcpStream::connect(address).expect("client should connect");
        write!(
            stream,
            "POST /v1/dev/seed HTTP/1.1\r\nhost: localhost\r\nx-turbo-user-handle: @avery\r\n\r\n",
        )
        .expect("request should write");
        stream
            .shutdown(Shutdown::Write)
            .expect("request write side should close");
        let mut response = String::new();
        stream
            .read_to_string(&mut response)
            .expect("response should read");
        server.join().expect("server thread should join");

        assert!(response.starts_with("HTTP/1.1 200 OK"));
        assert!(response.contains(r#""status":"seeded""#));
    }
}
