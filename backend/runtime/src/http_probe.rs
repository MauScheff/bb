use std::{
    io::{Read, Write},
    net::{Shutdown, TcpListener, TcpStream},
    sync::{Arc, Mutex},
    thread,
};

use serde::{Deserialize, Serialize};

use crate::{
    KernelCommandKind, KernelCorpus, KernelCorpusCase,
    http::{RuntimeHttpConfig, RuntimeHttpService, serve_one_connection},
    postgres::{CorpusKernelDecisionWorker, InMemoryRequestTalkTurnSnapshotLoader},
    routes::SelfHostedRouteService,
};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SelfHostedHttpProbeReport {
    pub status: String,
    pub native_status_code: u16,
    pub native_granted: bool,
    pub health_status_code: u16,
    pub health_ok: bool,
    pub bootstrap_ok: bool,
    pub discovery_ok: bool,
    pub prefixed_native_status_code: u16,
    pub prefixed_native_granted: bool,
    pub native_renew_status_code: u16,
    pub native_renewed: bool,
    pub native_release_status_code: u16,
    pub native_released: bool,
    pub legacy_status_code: u16,
    pub legacy_transmitting: bool,
    pub legacy_renew_status_code: u16,
    pub legacy_renew_transmitting: bool,
    pub legacy_end_status_code: u16,
    pub legacy_end_stopped: bool,
    pub bad_request_status_code: u16,
    pub bad_request_rejected: bool,
    pub observations: Vec<SelfHostedHttpRouteObservation>,
    pub steps: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SelfHostedHttpRouteObservation {
    pub kind: String,
    pub method: String,
    pub path: String,
    pub status_code: u16,
    pub expected_status_code: u16,
    pub ok: bool,
    pub semantic: String,
}

type ProbeHttpService =
    RuntimeHttpService<InMemoryRequestTalkTurnSnapshotLoader, CorpusKernelDecisionWorker>;

pub fn build_probe_http_service() -> ProbeHttpService {
    build_probe_http_service_with_config(RuntimeHttpConfig::default())
}

pub fn build_probe_http_service_with_config(runtime_config: RuntimeHttpConfig) -> ProbeHttpService {
    let corpus = KernelCorpus {
        cases: vec![
            granted_case("http-native", "op-http-native"),
            granted_case_for_conversation(
                "http-prefixed-native",
                "conversation-prefixed",
                "op-http-prefixed-native",
            ),
            granted_case("http-legacy", "op-http-legacy"),
            granted_case("http-bad-path", "op-http-bad-path"),
            released_case("http-native-release", "op-http-native-release"),
        ],
    };
    let loader = InMemoryRequestTalkTurnSnapshotLoader::from_cases(corpus.cases.iter());
    let worker = CorpusKernelDecisionWorker::new(&corpus);
    RuntimeHttpService::new_with_config(SelfHostedRouteService::new(loader, worker), runtime_config)
}

pub fn run_self_hosted_http_process_probe() -> Result<SelfHostedHttpProbeReport, String> {
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|error| error.to_string())?;
    let address = listener.local_addr().map_err(|error| error.to_string())?;
    let service = Arc::new(Mutex::new(build_probe_http_service()));
    let server_service = service.clone();
    let server = thread::spawn(move || -> Result<(), String> {
        for _ in 0..25 {
            serve_one_connection(&listener, &server_service).map_err(|error| error.to_string())?;
        }
        Ok(())
    });

    let mut steps = Vec::new();
    let mut observations = Vec::new();
    let health = get(address, "/s/turbo/v1/health")?;
    let health_ok = health.status_code == 200
        && health.body.contains(r#""status":"ok""#)
        && health.body.contains(r#""runtime":"self-hosted""#);
    observations.push(http_observation(
        "app-compatible-health",
        "GET",
        "/s/turbo/v1/health",
        &health,
        200,
        health_ok,
        "self-hosted runtime health",
    ));
    steps.push("app-compatible /s/turbo health route served over TCP".to_owned());

    let config = get(address, "/s/turbo/v1/config")?;
    let config_ok = config.status_code == 200
        && config.body.contains(r#""mode":"self-hosted""#)
        && config.body.contains(r#""supportsWebSocket":false"#);
    observations.push(http_observation(
        "app-compatible-runtime-config",
        "GET",
        "/s/turbo/v1/config",
        &config,
        200,
        config_ok,
        "self-hosted runtime config",
    ));
    steps.push("app-compatible runtime config route served over TCP".to_owned());

    let auth = post_json_with_headers(
        address,
        "/s/turbo/v1/auth/session",
        &serde_json::json!({}),
        &[("x-turbo-user-handle", "@avery")],
    )?;
    let auth_ok = auth.status_code == 200
        && auth.body.contains(r#""handle":"@avery""#)
        && auth.body.contains(r#""userId":"user-avery""#);
    observations.push(http_observation(
        "app-compatible-auth-session",
        "POST",
        "/s/turbo/v1/auth/session",
        &auth,
        200,
        auth_ok,
        "handle-bound auth session",
    ));
    steps.push("app-compatible auth session route served over TCP".to_owned());

    let device = post_json_with_headers(
        address,
        "/s/turbo/v1/devices/register",
        &serde_json::json!({
            "deviceId": "device-a",
            "deviceLabel": "Avery Phone"
        }),
        &[("x-turbo-user-handle", "@avery")],
    )?;
    let device_ok = device.status_code == 200
        && device.body.contains(r#""deviceId":"device-a""#)
        && device.body.contains(r#""userId":"user-avery""#);
    observations.push(http_observation(
        "app-compatible-device-register",
        "POST",
        "/s/turbo/v1/devices/register",
        &device,
        200,
        device_ok,
        "registered device bound to handle",
    ));
    steps.push("app-compatible device registration route served over TCP".to_owned());

    let heartbeat = post_json_with_headers(
        address,
        "/s/turbo/v1/presence/heartbeat",
        &serde_json::json!({ "deviceId": "device-a" }),
        &[("x-turbo-user-handle", "@avery")],
    )?;
    let heartbeat_ok = heartbeat.status_code == 200
        && heartbeat.body.contains(r#""deviceId":"device-a""#)
        && heartbeat.body.contains(r#""status":"online""#);
    observations.push(http_observation(
        "app-compatible-presence-heartbeat",
        "POST",
        "/s/turbo/v1/presence/heartbeat",
        &heartbeat,
        200,
        heartbeat_ok,
        "device presence heartbeat",
    ));
    steps.push("app-compatible presence heartbeat route served over TCP".to_owned());

    let telemetry = post_json_with_headers(
        address,
        "/s/turbo/v1/telemetry/events",
        &serde_json::json!({ "eventName": "runtime.smoke" }),
        &[("x-turbo-user-handle", "@avery")],
    )?;
    let telemetry_ok = telemetry.status_code == 200
        && telemetry.body.contains(r#""status":"ok""#)
        && telemetry.body.contains(r#""delivered":true"#);
    observations.push(http_observation(
        "app-compatible-telemetry-events",
        "POST",
        "/s/turbo/v1/telemetry/events",
        &telemetry,
        200,
        telemetry_ok,
        "telemetry accepted",
    ));
    steps.push("app-compatible telemetry events route served over TCP".to_owned());

    let lookup = get(address, "/s/turbo/v1/users/by-handle/%40blake")?;
    let lookup_ok = lookup.status_code == 200
        && lookup.body.contains(r#""handle":"@blake""#)
        && lookup.body.contains(r#""userId":"user-blake""#);
    observations.push(http_observation(
        "app-compatible-user-lookup",
        "GET",
        "/s/turbo/v1/users/by-handle/%40blake",
        &lookup,
        200,
        lookup_ok,
        "handle resolves to user",
    ));
    steps.push("app-compatible user lookup route served over TCP".to_owned());

    let presence = get(address, "/s/turbo/v1/users/by-handle/%40blake/presence")?;
    let presence_ok = presence.status_code == 200
        && presence.body.contains(r#""handle":"@blake""#)
        && presence.body.contains(r#""isOnline":false"#);
    observations.push(http_observation(
        "app-compatible-user-presence",
        "GET",
        "/s/turbo/v1/users/by-handle/%40blake/presence",
        &presence,
        200,
        presence_ok,
        "peer presence lookup",
    ));
    steps.push("app-compatible user presence lookup route served over TCP".to_owned());

    let resolve = post_json_with_headers(
        address,
        "/s/turbo/v1/identities/resolve",
        &serde_json::json!({ "reference": "@blake" }),
        &[("x-turbo-user-handle", "@avery")],
    )?;
    let resolve_ok = resolve.status_code == 200 && resolve.body.contains(r#""handle":"@blake""#);
    observations.push(http_observation(
        "app-compatible-identity-resolve",
        "POST",
        "/s/turbo/v1/identities/resolve",
        &resolve,
        200,
        resolve_ok,
        "identity reference resolves",
    ));
    steps.push("app-compatible identity resolve route served over TCP".to_owned());

    let direct = post_json_with_headers(
        address,
        "/s/turbo/v1/channels/direct",
        &serde_json::json!({ "otherUserId": "user-blake" }),
        &[("x-turbo-user-handle", "@avery")],
    )?;
    let direct_ok = direct.status_code == 200
        && direct
            .body
            .contains(r#""channelId":"direct-user-avery-user-blake""#);
    observations.push(http_observation(
        "app-compatible-direct-channel",
        "POST",
        "/s/turbo/v1/channels/direct",
        &direct,
        200,
        direct_ok,
        "direct channel created",
    ));
    steps.push("app-compatible direct channel route served over TCP".to_owned());

    let join = post_json_with_headers(
        address,
        "/s/turbo/v1/channels/direct-user-avery-user-blake/join",
        &serde_json::json!({ "deviceId": "device-a" }),
        &[("x-turbo-user-handle", "@avery")],
    )?;
    let join_ok = join.status_code == 200 && join.body.contains(r#""status":"joined""#);
    observations.push(http_observation(
        "app-compatible-channel-join-self",
        "POST",
        "/s/turbo/v1/channels/direct-user-avery-user-blake/join",
        &join,
        200,
        join_ok,
        "local device joined channel",
    ));
    steps.push("app-compatible channel join route served over TCP".to_owned());

    let peer_join = post_json_with_headers(
        address,
        "/s/turbo/v1/channels/direct-user-avery-user-blake/join",
        &serde_json::json!({ "deviceId": "device-b" }),
        &[("x-turbo-user-handle", "@blake")],
    )?;
    let peer_join_ok =
        peer_join.status_code == 200 && peer_join.body.contains(r#""status":"joined""#);
    observations.push(http_observation(
        "app-compatible-channel-join-peer",
        "POST",
        "/s/turbo/v1/channels/direct-user-avery-user-blake/join",
        &peer_join,
        200,
        peer_join_ok,
        "peer device joined channel",
    ));
    steps.push("app-compatible peer channel join route served over TCP".to_owned());

    let state = get_with_headers(
        address,
        "/s/turbo/v1/channels/direct-user-avery-user-blake/state/device-a",
        &[("x-turbo-user-handle", "@avery")],
    )?;
    let state_ok = state.status_code == 200
        && state.body.contains(r#""conversationStatus":"#)
        && state.body.contains(r#""kind":"ready""#);
    observations.push(http_observation(
        "app-compatible-channel-state",
        "GET",
        "/s/turbo/v1/channels/direct-user-avery-user-blake/state/device-a",
        &state,
        200,
        state_ok,
        "channel state projects ready conversation",
    ));
    steps.push("app-compatible channel state route served over TCP".to_owned());

    let readiness = get_with_headers(
        address,
        "/s/turbo/v1/channels/direct-user-avery-user-blake/readiness/device-a",
        &[("x-turbo-user-handle", "@avery")],
    )?;
    let readiness_ok = readiness.status_code == 200
        && readiness.body.contains(r#""readiness":"#)
        && readiness.body.contains(r#""kind":"ready""#);
    observations.push(http_observation(
        "app-compatible-channel-readiness",
        "GET",
        "/s/turbo/v1/channels/direct-user-avery-user-blake/readiness/device-a",
        &readiness,
        200,
        readiness_ok,
        "device readiness projects ready",
    ));
    steps.push("app-compatible channel readiness route served over TCP".to_owned());

    let receiver_audio_readiness = post_json_with_headers(
        address,
        "/s/turbo/v1/channels/direct-user-avery-user-blake/receiver-audio-readiness",
        &serde_json::json!({
            "deviceId": "device-a",
            "type": "receiver-ready",
            "payload": "receiver-ready"
        }),
        &[("x-turbo-user-handle", "@avery")],
    )?;
    let receiver_audio_readiness_ok = receiver_audio_readiness.status_code == 200
        && receiver_audio_readiness
            .body
            .contains(r#""audioReadiness":"ready""#);
    observations.push(http_observation(
        "app-compatible-receiver-audio-readiness",
        "POST",
        "/s/turbo/v1/channels/direct-user-avery-user-blake/receiver-audio-readiness",
        &receiver_audio_readiness,
        200,
        receiver_audio_readiness_ok,
        "receiver audio readiness accepted",
    ));
    steps.push("app-compatible receiver audio readiness route served over TCP".to_owned());

    let incoming = get(address, "/s/turbo/v1/beeps/incoming")?;
    let outgoing = get(address, "/s/turbo/v1/beeps/outgoing")?;
    let beeps_ok = incoming.status_code == 200
        && incoming.body.trim() == "[]"
        && outgoing.status_code == 200
        && outgoing.body.trim() == "[]";
    observations.push(http_observation(
        "app-compatible-beeps-incoming",
        "GET",
        "/s/turbo/v1/beeps/incoming",
        &incoming,
        200,
        incoming.status_code == 200 && incoming.body.trim() == "[]",
        "incoming beep list empty",
    ));
    observations.push(http_observation(
        "app-compatible-beeps-outgoing",
        "GET",
        "/s/turbo/v1/beeps/outgoing",
        &outgoing,
        200,
        outgoing.status_code == 200 && outgoing.body.trim() == "[]",
        "outgoing beep list empty",
    ));
    steps.push("app-compatible beep list routes served over TCP".to_owned());

    let native = post_json(
        address,
        "/v1/conversations/conversation-1/talk-turns/request",
        &request_talk_turn_command("op-http-native"),
    )?;
    let native_granted = native.status_code == 200 && native.body.contains(r#""status":"granted""#);
    observations.push(http_observation(
        "native-request-talk-turn",
        "POST",
        "/v1/conversations/conversation-1/talk-turns/request",
        &native,
        200,
        native_granted,
        "native request granted",
    ));
    steps.push("native RequestTalkTurn route served over TCP".to_owned());

    let prefixed_native = post_json(
        address,
        "/s/turbo/v1/conversations/conversation-prefixed/talk-turns/request",
        &request_talk_turn_command_for_conversation(
            "conversation-prefixed",
            "op-http-prefixed-native",
        ),
    )?;
    let prefixed_native_granted = prefixed_native.status_code == 200
        && prefixed_native.body.contains(r#""status":"granted""#);
    observations.push(http_observation(
        "prefixed-native-request-talk-turn",
        "POST",
        "/s/turbo/v1/conversations/conversation-prefixed/talk-turns/request",
        &prefixed_native,
        200,
        prefixed_native_granted,
        "app-compatible native request granted",
    ));
    steps.push("app-compatible /s/turbo RequestTalkTurn route served over TCP".to_owned());

    let native_renew = post_json(
        address,
        "/v1/conversations/conversation-1/talk-turns/renew",
        &renew_talk_turn_command("op-http-native-renew"),
    )?;
    let native_renewed =
        native_renew.status_code == 200 && native_renew.body.contains(r#""status":"renewed""#);
    observations.push(http_observation(
        "native-renew-talk-turn",
        "POST",
        "/v1/conversations/conversation-1/talk-turns/renew",
        &native_renew,
        200,
        native_renewed,
        "native renew accepted",
    ));
    steps.push("native RenewTalkTurn route served over TCP".to_owned());

    let native_release = post_json(
        address,
        "/v1/conversations/conversation-1/talk-turns/release",
        &release_talk_turn_command("op-http-native-release"),
    )?;
    let native_released =
        native_release.status_code == 200 && native_release.body.contains(r#""status":"released""#);
    observations.push(http_observation(
        "native-release-talk-turn",
        "POST",
        "/v1/conversations/conversation-1/talk-turns/release",
        &native_release,
        200,
        native_released,
        "native release accepted",
    ));
    steps.push("native ReleaseTalkTurn route served over TCP".to_owned());

    let legacy = post_json(
        address,
        "/v1/channels/conversation-1/begin-transmit",
        &serde_json::json!({
            "deviceId": "device-a",
            "requestingParticipantId": "participant-a",
            "requestingSessionEpoch": 0,
            "targetParticipantId": "participant-b",
            "operationId": "op-http-legacy",
            "policyVersion": "policy-v1",
            "kernelVersion": "kernel-contract-v1"
        }),
    )?;
    let legacy_transmitting =
        legacy.status_code == 200 && legacy.body.contains(r#""status":"transmitting""#);
    observations.push(http_observation(
        "legacy-begin-transmit",
        "POST",
        "/v1/channels/conversation-1/begin-transmit",
        &legacy,
        200,
        legacy_transmitting,
        "legacy begin-transmit projects transmitting",
    ));
    steps.push("legacy begin-transmit compatibility route served over TCP".to_owned());

    let legacy_renew = post_json(
        address,
        "/v1/channels/conversation-1/renew-transmit",
        &serde_json::json!({
            "deviceId": "device-a"
        }),
    )?;
    let legacy_renew_transmitting =
        legacy_renew.status_code == 200 && legacy_renew.body.contains(r#""status":"transmitting""#);
    observations.push(http_observation(
        "legacy-renew-transmit",
        "POST",
        "/v1/channels/conversation-1/renew-transmit",
        &legacy_renew,
        200,
        legacy_renew_transmitting,
        "legacy renew-transmit preserves transmitting",
    ));
    steps.push("legacy renew-transmit compatibility route served over TCP".to_owned());

    let legacy_end = post_json(
        address,
        "/v1/channels/conversation-1/end-transmit",
        &serde_json::json!({
            "deviceId": "device-a"
        }),
    )?;
    let legacy_end_stopped =
        legacy_end.status_code == 200 && legacy_end.body.contains(r#""status":"stopped""#);
    observations.push(http_observation(
        "legacy-end-transmit",
        "POST",
        "/v1/channels/conversation-1/end-transmit",
        &legacy_end,
        200,
        legacy_end_stopped,
        "legacy end-transmit stops transmit",
    ));
    steps.push("legacy end-transmit compatibility route served over TCP".to_owned());

    let bad_request = post_json(
        address,
        "/v1/conversations/other/talk-turns/request",
        &request_talk_turn_command("op-http-bad-path"),
    )?;
    let bad_request_rejected =
        bad_request.status_code == 400 && bad_request.body.contains("path conversation");
    observations.push(http_observation(
        "mismatched-conversation-rejected",
        "POST",
        "/v1/conversations/other/talk-turns/request",
        &bad_request,
        400,
        bad_request_rejected,
        "path conversation mismatch rejected",
    ));
    steps.push("mismatched Conversation path rejected over TCP".to_owned());

    server
        .join()
        .map_err(|_| "HTTP probe server thread panicked".to_owned())??;

    let status = if health_ok
        && config_ok
        && auth_ok
        && device_ok
        && heartbeat_ok
        && telemetry_ok
        && lookup_ok
        && presence_ok
        && resolve_ok
        && direct_ok
        && join_ok
        && peer_join_ok
        && state_ok
        && readiness_ok
        && receiver_audio_readiness_ok
        && beeps_ok
        && native_granted
        && prefixed_native_granted
        && native_renewed
        && native_released
        && legacy_transmitting
        && legacy_renew_transmitting
        && legacy_end_stopped
        && bad_request_rejected
    {
        "ok"
    } else {
        "failed"
    }
    .to_owned();

    Ok(SelfHostedHttpProbeReport {
        status,
        native_status_code: native.status_code,
        native_granted,
        health_status_code: health.status_code,
        health_ok,
        bootstrap_ok: config_ok && auth_ok && device_ok && heartbeat_ok && telemetry_ok,
        discovery_ok: lookup_ok
            && presence_ok
            && resolve_ok
            && direct_ok
            && join_ok
            && peer_join_ok
            && state_ok
            && readiness_ok
            && receiver_audio_readiness_ok
            && beeps_ok,
        prefixed_native_status_code: prefixed_native.status_code,
        prefixed_native_granted,
        native_renew_status_code: native_renew.status_code,
        native_renewed,
        native_release_status_code: native_release.status_code,
        native_released,
        legacy_status_code: legacy.status_code,
        legacy_transmitting,
        legacy_renew_status_code: legacy_renew.status_code,
        legacy_renew_transmitting,
        legacy_end_status_code: legacy_end.status_code,
        legacy_end_stopped,
        bad_request_status_code: bad_request.status_code,
        bad_request_rejected,
        observations,
        steps,
    })
}

fn http_observation(
    kind: &str,
    method: &str,
    path: &str,
    response: &RawHttpResponse,
    expected_status_code: u16,
    ok: bool,
    semantic: &str,
) -> SelfHostedHttpRouteObservation {
    SelfHostedHttpRouteObservation {
        kind: kind.to_owned(),
        method: method.to_owned(),
        path: path.to_owned(),
        status_code: response.status_code,
        expected_status_code,
        ok,
        semantic: semantic.to_owned(),
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RawHttpResponse {
    status_code: u16,
    body: String,
}

fn post_json(
    address: std::net::SocketAddr,
    path: &str,
    body: &serde_json::Value,
) -> Result<RawHttpResponse, String> {
    post_json_with_headers(address, path, body, &[])
}

fn post_json_with_headers(
    address: std::net::SocketAddr,
    path: &str,
    body: &serde_json::Value,
    headers: &[(&str, &str)],
) -> Result<RawHttpResponse, String> {
    let body = serde_json::to_string(body).map_err(|error| error.to_string())?;
    let mut stream = TcpStream::connect(address).map_err(|error| error.to_string())?;
    let rendered_headers = headers
        .iter()
        .map(|(name, value)| format!("{name}: {value}\r\n"))
        .collect::<String>();
    write!(
        stream,
        "POST {path} HTTP/1.1\r\nhost: localhost\r\n{rendered_headers}content-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
        body.len(),
        body
    )
    .map_err(|error| error.to_string())?;
    stream
        .shutdown(Shutdown::Write)
        .map_err(|error| error.to_string())?;
    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .map_err(|error| error.to_string())?;
    parse_response(&response)
}

fn get(address: std::net::SocketAddr, path: &str) -> Result<RawHttpResponse, String> {
    get_with_headers(address, path, &[])
}

fn get_with_headers(
    address: std::net::SocketAddr,
    path: &str,
    headers: &[(&str, &str)],
) -> Result<RawHttpResponse, String> {
    let mut stream = TcpStream::connect(address).map_err(|error| error.to_string())?;
    let rendered_headers = headers
        .iter()
        .map(|(name, value)| format!("{name}: {value}\r\n"))
        .collect::<String>();
    write!(
        stream,
        "GET {path} HTTP/1.1\r\nhost: localhost\r\n{rendered_headers}content-length: 0\r\n\r\n",
    )
    .map_err(|error| error.to_string())?;
    stream
        .shutdown(Shutdown::Write)
        .map_err(|error| error.to_string())?;
    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .map_err(|error| error.to_string())?;
    parse_response(&response)
}

fn parse_response(response: &str) -> Result<RawHttpResponse, String> {
    let (head, body) = response
        .split_once("\r\n\r\n")
        .ok_or_else(|| "HTTP response was missing header terminator".to_owned())?;
    let status_code = head
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .ok_or_else(|| "HTTP response was missing status code".to_owned())?
        .parse()
        .map_err(|error| format!("HTTP status code was invalid: {error}"))?;
    Ok(RawHttpResponse {
        status_code,
        body: body.to_owned(),
    })
}

fn granted_case(id: &str, operation_id: &str) -> KernelCorpusCase {
    granted_case_for_conversation(id, "conversation-1", operation_id)
}

fn granted_case_for_conversation(
    id: &str,
    conversation_id: &str,
    operation_id: &str,
) -> KernelCorpusCase {
    KernelCorpusCase {
        id: id.to_owned(),
        kind: KernelCommandKind::RequestTalkTurn,
        command: request_talk_turn_command_for_conversation(conversation_id, operation_id),
        snapshot: serde_json::json!({
            "conversationId": { "value": conversation_id },
            "snapshotBuiltAtMs": 10000
        }),
        policy: serde_json::json!({ "policyVersion": { "value": "policy-v1" } }),
        expected_decision: serde_json::json!({
            "kind": "granted",
            "grant": {
                "conversationId": { "value": conversation_id },
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
                        "conversationId": { "value": conversation_id },
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

fn request_talk_turn_command(operation_id: &str) -> serde_json::Value {
    request_talk_turn_command_for_conversation("conversation-1", operation_id)
}

fn request_talk_turn_command_for_conversation(
    conversation_id: &str,
    operation_id: &str,
) -> serde_json::Value {
    serde_json::json!({
        "kind": "request-talk-turn",
        "conversationId": { "value": conversation_id },
        "requestingParticipantId": { "value": "participant-a" },
        "requestingDeviceId": { "value": "device-a" },
        "requestingSessionEpoch": { "value": 0 },
        "targetParticipantId": { "value": "participant-b" },
        "operationId": operation_id,
        "policyVersion": { "value": "policy-v1" },
        "kernelVersion": { "value": "kernel-contract-v1" }
    })
}

fn renew_talk_turn_command(operation_id: &str) -> serde_json::Value {
    serde_json::json!({
        "kind": "renew-talk-turn",
        "conversationId": { "value": "conversation-1" },
        "participantId": { "value": "participant-a" },
        "deviceId": { "value": "device-a" },
        "talkTurnEpoch": { "value": 1 },
        "operationId": operation_id,
        "nowMs": 20_000,
        "policyVersion": { "value": "policy-v1" },
        "maxTalkTurnLeaseMs": 15_000,
        "grantsEnabled": true,
        "ownerRuntimeId": "runtime-a",
        "ownerEpoch": { "value": 1 },
        "ownerLeaseExpiresAtMs": 60_000
    })
}

fn released_case(id: &str, operation_id: &str) -> KernelCorpusCase {
    KernelCorpusCase {
        id: id.to_owned(),
        kind: KernelCommandKind::ReleaseTalkTurn,
        command: release_talk_turn_command(operation_id),
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

fn release_talk_turn_command(operation_id: &str) -> serde_json::Value {
    serde_json::json!({
        "kind": "release-talk-turn",
        "conversationId": { "value": "conversation-1" },
        "participantId": { "value": "participant-a" },
        "deviceId": { "value": "device-a" },
        "sessionEpoch": { "value": 0 },
        "talkTurnEpoch": { "value": 1 },
        "operationId": operation_id,
        "policyVersion": { "value": "policy-v1" },
        "kernelVersion": { "value": "kernel-contract-v1" }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn self_hosted_http_process_probe_serves_tcp_routes() {
        let report = run_self_hosted_http_process_probe()
            .expect("self-hosted HTTP process probe should run");

        assert_eq!(report.status, "ok");
        assert!(report.health_ok);
        assert!(report.bootstrap_ok);
        assert!(report.discovery_ok);
        assert!(report.native_granted);
        assert!(report.prefixed_native_granted);
        assert!(report.native_renewed);
        assert!(report.native_released);
        assert!(report.legacy_transmitting);
        assert!(report.legacy_renew_transmitting);
        assert!(report.legacy_end_stopped);
        assert!(report.bad_request_rejected);
        assert_eq!(report.observations.len(), 25);
        assert!(report.observations.iter().all(|observation| observation.ok));
        assert!(report.observations.iter().any(|observation| {
            observation.kind == "mismatched-conversation-rejected"
                && observation.status_code == 400
                && observation.expected_status_code == 400
        }));
    }
}
