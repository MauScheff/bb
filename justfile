set shell := ["bash", "-cu"]

default:
  @just --list

venv:
  rm -rf .venv
  python3 -m venv .venv --without-pip
  .venv/bin/python -m ensurepip --upgrade
  .venv/bin/python -m pip install --upgrade pip
  .venv/bin/python -m pip install -r requirements.txt

kernel-test:
  sh -c 'cd {{justfile_directory()}} && printf "test beepbeep\nquit\n" | direnv exec . ucm -p bb/main --no-file-watch'

kernel-fuzz:
  sh -c 'cd {{justfile_directory()}} && printf "test beepbeep.tests\nquit\n" | direnv exec . ucm -p bb/main --no-file-watch'

kernel-corpus-json output="/tmp/turbo-kernel-corpus.json":
  sh -c 'cd {{justfile_directory()}} && DIRENV_LOG_FORMAT= direnv exec . ucm run bb/main:.beepbeep.tests.corpus.printJson > "{{output}}"'

rust-runtime-test:
  cargo test -q -p beepbeep-runtime

rust-runtime-fuzz seed="123" count="32" output="/tmp/turbo-rust-runtime-fuzz/report.json":
  cargo test -q -p beepbeep-runtime --lib rust_runtime_fuzz
  TURBO_FUZZ_SEED="{{seed}}" TURBO_FUZZ_COUNT="{{count}}" TURBO_FUZZ_OUTPUT="{{output}}" cargo run -q -p beepbeep-runtime --bin rust-runtime-fuzz

runtime-postgres-test:
  cargo test -q -p beepbeep-runtime request_talk_turn_postgres

runtime-kernel-worker-test:
  cargo test -q -p beepbeep-runtime request_talk_turn_postgres_process_worker

runtime-live-test:
  cargo test -q -p beepbeep-runtime live_runtime_config
  cargo build -q -p beepbeep-runtime --bin beepbeep-runtime

self-hosted-preflight output="/tmp/turbo-self-hosted-preflight.json":
  python3 backend/scripts/self_hosted_infra_preflight.py \
    --compose-file backend/infra/self-hosted/docker-compose.yml \
    --postgres-host 127.0.0.1 \
    --postgres-port 55432 \
    --redis-host 127.0.0.1 \
    --redis-port 56379 \
    --output "{{output}}"

self-hosted-up output="/tmp/turbo-self-hosted-preflight.json":
  just self-hosted-preflight "{{output}}"
  docker compose -f backend/infra/self-hosted/docker-compose.yml up -d postgres redis

self-hosted-down:
  docker compose -f backend/infra/self-hosted/docker-compose.yml down

rust-runtime-integration output="/tmp/turbo-rust-runtime-integration.json":
  python3 backend/scripts/runtime_postgres_integration_proof.py \
    --compose-file backend/infra/self-hosted/docker-compose.yml \
    --preflight-output /tmp/turbo-self-hosted-preflight.json \
    --output "{{output}}"

runtime-postgres-integration output="/tmp/turbo-rust-runtime-integration.json":
  just rust-runtime-integration "{{output}}"

self-hosted-serve bind="127.0.0.1:8091" websocket_mode="single" runtime_id="runtime-single" owner_ttl_ms="15000" database_url="postgres://turbo_runtime:turbo_runtime@127.0.0.1:55432/turbo_runtime":
  TURBO_RUNTIME_BIND={{bind}} \
  TURBO_RUNTIME_DATABASE_URL={{database_url}} \
  TURBO_RUNTIME_WEBSOCKET_MODE={{websocket_mode}} \
  TURBO_RUNTIME_ID={{runtime_id}} \
  TURBO_RUNTIME_WEBSOCKET_OWNER_TTL_MS={{owner_ttl_ms}} \
  cargo run -q -p beepbeep-runtime --bin beepbeep-runtime

self-hosted-serve-smoke bind="127.0.0.1:8091":
  TURBO_RUNTIME_BIND={{bind}} cargo run -q -p beepbeep-runtime --bin beepbeep-runtime-smoke

self-hosted-route-probe:
  cargo test -q -p beepbeep-runtime self_hosted_route_probe

self-hosted-http-probe output="/tmp/turbo-self-hosted-http-probe.json":
  cargo test -q -p beepbeep-runtime self_hosted_http_route_probe
  cargo test -q -p beepbeep-runtime --lib self_hosted_http_process_probe
  TURBO_HTTP_PROBE_OUTPUT="{{output}}" cargo run -q -p beepbeep-runtime --bin self-hosted-http-probe

shadow-backend-compare:
  cargo test -q -p beepbeep-runtime shadow_request_talk_turn

shadow-backend-fuzz seed="123" count="32" output="/tmp/turbo-shadow-backend-fuzz/report.json":
  cargo test -q -p beepbeep-runtime --lib shadow_backend_fuzz
  TURBO_FUZZ_SEED="{{seed}}" TURBO_FUZZ_COUNT="{{count}}" TURBO_FUZZ_OUTPUT="{{output}}" cargo run -q -p beepbeep-runtime --bin shadow-backend-fuzz

websocket-single-instance-test:
  cargo test -q -p beepbeep-runtime websocket_single_instance

self-hosted-websocket-probe output="/tmp/turbo-self-hosted-websocket-probe.json":
  cargo test -q -p beepbeep-runtime --lib websocket_self_hosted_probe
  TURBO_WEBSOCKET_PROBE_OUTPUT="{{output}}" cargo run -q -p beepbeep-runtime --bin websocket-probe

runtime-quic-probe endpoint="api.beepbeep.to:443" output="/tmp/turbo-runtime-quic-probe.json":
  TURBO_RUNTIME_QUIC_PROBE_ENDPOINT="{{endpoint}}" \
  TURBO_RUNTIME_QUIC_PROBE_OUTPUT="{{output}}" \
  cargo run -q -p beepbeep-runtime --bin runtime-quic-probe

self-hosted-scenario-fuzz-local seed count output="/tmp/turbo-self-hosted-fuzz/report.json":
  cargo test -q -p beepbeep-runtime --lib self_hosted_scenario_fuzz_local
  TURBO_FUZZ_SEED="{{seed}}" TURBO_FUZZ_COUNT="{{count}}" TURBO_FUZZ_OUTPUT="/tmp/turbo-self-hosted-fuzz/in-memory-report.json" cargo run -q -p beepbeep-runtime --bin self-hosted-scenario-fuzz
  python3 backend/scripts/self_hosted_production_scenario_fuzz.py \
    --seed "{{seed}}" \
    --count "{{count}}" \
    --deterministic-report /tmp/turbo-self-hosted-fuzz/in-memory-report.json \
    --output "{{output}}"

reliability-fuzz-self-hosted-overnight seed count output="/tmp/turbo-self-hosted-fuzz/overnight-report.json":
  cargo test -q -p beepbeep-runtime --lib reliability_fuzz_self_hosted_overnight
  TURBO_FUZZ_SEED="{{seed}}" TURBO_FUZZ_COUNT="{{count}}" TURBO_FUZZ_OUTPUT="{{output}}" cargo run -q -p beepbeep-runtime --bin reliability-fuzz-self-hosted-overnight

self-hosted-cutover-readiness output="/tmp/turbo-self-hosted-cutover-readiness.json":
  python3 backend/scripts/self_hosted_cutover_readiness.py --output "{{output}}"

beepbeep-backend-gate mode="local" seed="123" count="3" output="/tmp/beepbeep-backend-reliability-gate.json":
  python3 backend/scripts/reliability_gate.py "{{mode}}" \
    --seed "{{seed}}" \
    --count "{{count}}" \
    --output "{{output}}"

beepbeep-backend-gate-dry-run mode="local" seed="123" count="3" output="/tmp/beepbeep-backend-reliability-gate-dry-run.json":
  python3 backend/scripts/reliability_gate.py "{{mode}}" \
    --seed "{{seed}}" \
    --count "{{count}}" \
    --output "{{output}}" \
    --dry-run

beepbeep-backend-production-gate base="https://api.beepbeep.to" seed="123" count="3" output="/tmp/beepbeep-backend-production-gate.json":
  python3 backend/scripts/reliability_gate.py production \
    --base-url "{{base}}" \
    --seed "{{seed}}" \
    --count "{{count}}" \
    --output "{{output}}"

beepbeep-backend-cutover-readiness output="/tmp/turbo-self-hosted-cutover-readiness.json":
  python3 backend/scripts/reliability_gate.py cutover --output "{{output}}"

kernel-compile output_dir="backend/infra/vm/build/kernel" summary="/tmp/turbo-kernel-compile.json":
  python3 backend/scripts/compile_unison_kernel_artifacts.py \
    --output-dir "{{output_dir}}" \
    --summary "{{summary}}"

kernel-invocation-audit output="/tmp/bb-kernel-invocation-audit.json" limit="20":
  python3 backend/scripts/kernel_invocation_audit.py \
    --output "{{output}}" \
    --limit "{{limit}}"

resident-kernel-invocation-audit output="/tmp/bb-resident-kernel-invocation-audit.json" limit="20":
  python3 backend/scripts/kernel_invocation_audit.py \
    --mode resident \
    --output "{{output}}" \
    --limit "{{limit}}"

gce-self-hosted-deploy-dry-run project="" zone="europe-west6-a" instance="turbo-self-hosted-1" output="/tmp/turbo-gce-self-hosted-deploy.json":
  python3 backend/scripts/gce_vm_self_hosted_deploy.py \
    --project "{{project}}" \
    --zone "{{zone}}" \
    --instance "{{instance}}" \
    --output "{{output}}" \
    --dry-run

gce-self-hosted-deploy project="" zone="europe-west6-a" instance="turbo-self-hosted-1" output="/tmp/turbo-gce-self-hosted-deploy.json":
  python3 backend/scripts/gce_vm_self_hosted_deploy.py \
    --project "{{project}}" \
    --zone "{{zone}}" \
    --instance "{{instance}}" \
    --output "{{output}}"

gce-relay-deploy-dry-run project="" zone="europe-west6-a" instance="turbo-relay-1" output="/tmp/bb-gce-relay-deploy.json":
  python3 backend/scripts/gce_vm_relay_deploy.py \
    --project "{{project}}" \
    --zone "{{zone}}" \
    --instance "{{instance}}" \
    --output "{{output}}" \
    --dry-run

gce-relay-deploy project="" zone="europe-west6-a" instance="turbo-relay-1" output="/tmp/bb-gce-relay-deploy.json":
  python3 backend/scripts/gce_vm_relay_deploy.py \
    --project "{{project}}" \
    --zone "{{zone}}" \
    --instance "{{instance}}" \
    --output "{{output}}"

gce-self-hosted-deploy-relay project="" zone="europe-west6-a" instance="turbo-relay-1" output="/tmp/bb-gce-relay-deploy.json":
  just gce-relay-deploy "{{project}}" "{{zone}}" "{{instance}}" "{{output}}"

physical-device-boundary-proof manifest="/tmp/turbo-physical-device-boundaries-manifest.json" output="/tmp/turbo-physical-device-boundaries.json":
  python3 tools/scripts/physical_device_boundary_proof.py \
    --manifest "{{manifest}}" \
    --output "{{output}}" \
    --write-template

physical-device-boundary-manifest artifacts="" devices="" output="/tmp/turbo-physical-device-boundaries-manifest.json":
  python3 tools/scripts/physical_device_boundary_manifest.py \
    --output "{{output}}" \
    {{devices}} \
    {{artifacts}}

physical-device-boundary-merge manifests="" output="/tmp/turbo-physical-device-boundaries-manifest.json":
  python3 tools/scripts/physical_device_boundary_merge.py \
    --output "{{output}}" \
    {{manifests}}

physical-device-boundary-finalize inputs="" manifest="/tmp/turbo-physical-device-boundaries-manifest.json" proof="/tmp/turbo-physical-device-boundaries.json" summary="/tmp/turbo-physical-device-boundary-finalize.json":
  python3 tools/scripts/physical_device_boundary_finalize.py \
    --manifest-output "{{manifest}}" \
    --proof-output "{{proof}}" \
    --summary-output "{{summary}}" \
    {{inputs}}

physical-device-boundary-status readiness="/tmp/turbo-self-hosted-cutover-readiness-current.json" runs="" output="/tmp/turbo-physical-device-boundary-status.json":
  python3 tools/scripts/physical_device_boundary_status.py \
    --readiness "{{readiness}}" \
    --output "{{output}}" \
    {{runs}}

physical-device-boundary-collect handles="" devices="" physical_devices="" artifacts="" output_dir="/tmp/turbo-physical-device-boundary-run" insecure="" launch_profile="current" wake_args="" wait="0" target_args="":
  python3 tools/scripts/physical_device_boundary_collect.py \
    --output-dir "{{output_dir}}" \
    --launch-profile "{{launch_profile}}" \
    --pre-collect-wait-seconds "{{wait}}" \
    {{target_args}} \
    {{devices}} \
    {{physical_devices}} \
    {{artifacts}} \
    {{wake_args}} \
    {{insecure}} \
    {{handles}}

talk-turn-actor-test:
  cargo test -q -p beepbeep-runtime talk_turn_actor

quic-protocol-test:
  cargo test -q -p beepbeep-runtime quic_protocol

multi-node-routing-test:
  cargo test -q -p beepbeep-runtime multi_node_routing

relay-test:
  cargo test -q -p beepbeep-relay
  cargo build --release -p beepbeep-relay --bin beepbeep-relay

postdeploy-check base="https://api.beepbeep.to" caller="@quinn" callee="@sasha" iterations="1" output_dir="/tmp/turbo-postdeploy-check" insecure="--insecure":
  python3 tools/scripts/postdeploy_check.py \
    --base-url "{{base}}" \
    --caller "{{caller}}" \
    --callee "{{callee}}" \
    --iterations "{{iterations}}" \
    --output-dir "{{output_dir}}" \
    {{insecure}}

production-preflight:
  just swift-test-suite
  just reliability-gate-regressions
  just reliability-gate-full

testflight:
  direnv exec . python3 tools/scripts/start_testflight_release.py

testflight-assign build_id:
  direnv exec . python3 tools/scripts/start_testflight_release.py --skip-git-checks --assign-build-id "{{build_id}}"

device-list:
  python3 tools/scripts/device_app.py list

device-info device="":
  python3 tools/scripts/device_app.py info --device "{{device}}"

device-lock-state device="" json="":
  python3 tools/scripts/device_app.py lock-state --device "{{device}}" {{json}}

device-lock-state-connected json="":
  python3 tools/scripts/device_app.py lock-state-connected {{json}}

device-build device="" configuration="Debug":
  python3 tools/scripts/device_app.py --configuration "{{configuration}}" build --device "{{device}}"

device-install device app_path:
  python3 tools/scripts/device_app.py install --device "{{device}}" --app-path "{{app_path}}"

device-build-install device="" configuration="Debug":
  python3 tools/scripts/device_app.py --configuration "{{configuration}}" install --device "{{device}}"

device-launch device="" bundle_id="com.rounded.Turbo":
  python3 tools/scripts/device_app.py launch --device "{{device}}" --bundle-id "{{bundle_id}}" --terminate-existing

device-launch-connected bundle_id="com.rounded.Turbo" json="":
  python3 tools/scripts/device_app.py launch-connected --bundle-id "{{bundle_id}}" --terminate-existing --continue-on-device-error {{json}}

device-launch-connected-json output="/tmp/turbo-device-launch-connected-current.json" bundle_id="com.rounded.Turbo":
  python3 tools/scripts/device_app.py launch-connected --bundle-id "{{bundle_id}}" --terminate-existing --continue-on-device-error --json --output "{{output}}"

device-run device="" configuration="Debug" bundle_id="com.rounded.Turbo":
  python3 tools/scripts/device_app.py --configuration "{{configuration}}" run --device "{{device}}" --bundle-id "{{bundle_id}}" --terminate-existing

device-run-connected configuration="Debug" bundle_id="com.rounded.Turbo":
  python3 tools/scripts/device_app.py --configuration "{{configuration}}" run-connected --bundle-id "{{bundle_id}}" --terminate-existing

device-diagnostics device="" output_dir="":
  python3 tools/scripts/device_app.py diagnostics --device "{{device}}" --output-dir "{{output_dir}}"

device-diagnostics-connected output_dir="":
  python3 tools/scripts/device_app.py diagnostics-connected --output-dir "{{output_dir}}"

device-diagnostics-crash-logs device="" output_dir="":
  python3 tools/scripts/device_app.py diagnostics --device "{{device}}" --output-dir "{{output_dir}}" --include-crash-logs

device-sysdiagnose device="" output_dir="" timeout="900":
  python3 tools/scripts/device_app.py --timeout "{{timeout}}" sysdiagnose --device "{{device}}" --output-dir "{{output_dir}}"

device-test device="" only_testing="TurboTests" skip_testing="TurboUITests":
  python3 tools/scripts/device_app.py test --device "{{device}}" --only-testing "{{only_testing}}" --skip-testing "{{skip_testing}}"

device-test-target device name:
  python3 tools/scripts/device_app.py test --device "{{device}}" --name "{{name}}"

device-ui-test device="" only_testing="TurboUITests":
  python3 tools/scripts/device_app.py test --device "{{device}}" --only-testing "{{only_testing}}"

route-probe:
  .venv/bin/python tools/scripts/route_probe.py --base-url https://api.beepbeep.to --caller @quinn --callee @sasha --insecure

backend-stability-probe base="https://api.beepbeep.to" handle="@mau" iterations="10" timeout="8":
  python3 tools/scripts/backend_stability_probe.py --base-url "{{base}}" --handle "{{handle}}" --iterations "{{iterations}}" --timeout "{{timeout}}"

websocket-stability-probe base="https://api.beepbeep.to" caller="@quinn" callee="@sasha" duration="90" heartbeat_interval="20" telemetry_interval="0" insecure="--insecure":
  python3 tools/scripts/websocket_stability_probe.py --base-url "{{base}}" --caller "{{caller}}" --callee "{{callee}}" --duration "{{duration}}" --heartbeat-interval "{{heartbeat_interval}}" --telemetry-interval "{{telemetry_interval}}" {{insecure}}

hosted-backend-client-probe base="https://api.beepbeep.to" duration="60" heartbeat_interval="20" telemetry_interval="20" output="/tmp/turbo-debug/hosted_backend_client_probe_latest.json":
  python3 tools/scripts/run_hosted_backend_client_probe.py --base-url "{{base}}" --duration "{{duration}}" --heartbeat-interval "{{heartbeat_interval}}" --telemetry-interval "{{telemetry_interval}}" --output "{{output}}"

direct-quic-provisioning-probe:
  .venv/bin/python tools/scripts/direct_quic_provisioning_probe.py --base-url https://api.beepbeep.to --caller @quinn --callee @sasha --insecure

turn-policy-probe require_enabled="":
  .venv/bin/python tools/scripts/turn_policy_probe.py --base-url https://api.beepbeep.to --handle @quinn --insecure {{require_enabled}}

route-probe-local base="http://127.0.0.1:8091/s/turbo" caller="@avery" callee="@blake":
  .venv/bin/python tools/scripts/route_probe.py --base-url "{{base}}" --caller "{{caller}}" --callee "{{callee}}"

clean-scratch:
  find . -maxdepth 1 -type f -name '*.u' | sort
  find . -maxdepth 1 -type f -name '*.u' -delete

seed base="https://api.beepbeep.to" handle="@avery":
  curl --fail-with-body -i -X POST \
    -H "x-turbo-user-handle: {{handle}}" \
    -H "Authorization: Bearer {{handle}}" \
    "{{base}}/v1/dev/seed"

reset base="https://api.beepbeep.to" handle="@avery":
  curl --fail-with-body -i -X POST \
    -H "x-turbo-user-handle: {{handle}}" \
    -H "Authorization: Bearer {{handle}}" \
    "{{base}}/v1/dev/reset-state"

reset-all base="https://api.beepbeep.to" handle="@avery":
  curl --fail-with-body -i -X POST \
    -H "x-turbo-user-handle: {{handle}}" \
    -H "Authorization: Bearer {{handle}}" \
    "{{base}}/v1/dev/reset-all"

reset-pair-all base="https://api.beepbeep.to" handle_a="@avery" handle_b="@blake":
  just reset-all "{{base}}" "{{handle_a}}"
  just reset-all "{{base}}" "{{handle_b}}"
  just seed "{{base}}" "{{handle_a}}"

diagnostics-latest device_id base="https://api.beepbeep.to" handle="@turbo-ios":
  curl --fail-with-body -sS \
    -H "x-turbo-user-handle: {{handle}}" \
    -H "Authorization: Bearer {{handle}}" \
    "{{base}}/v1/dev/diagnostics/latest/{{device_id}}/"

diagnostics-latest-current base="https://api.beepbeep.to" handle="@turbo-ios":
  curl --fail-with-body -sS \
    -H "x-turbo-user-handle: {{handle}}" \
    -H "Authorization: Bearer {{handle}}" \
    "{{base}}/v1/dev/diagnostics/latest"

diagnostics-merge base="https://api.beepbeep.to" handles="" insecure="--insecure":
  python3 tools/scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} {{handles}}

diagnostics-merge-pair base="https://api.beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  python3 tools/scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} "{{handle_a}}" "{{handle_b}}"

reliability-intake handle_a handle_b="" base="https://api.beepbeep.to" surface="auto" incident_id="" insecure="--insecure":
  python3 tools/scripts/reliability_intake.py \
    --base-url "{{base}}" \
    --surface "{{surface}}" \
    --incident-id "{{incident_id}}" \
    {{insecure}} \
    "{{handle_a}}" "{{handle_b}}"

reliability-intake-shake handle incident_id peer="" base="https://api.beepbeep.to" surface="production" insecure="--insecure":
  python3 tools/scripts/reliability_intake.py \
    --base-url "{{base}}" \
    --surface "{{surface}}" \
    --incident-id "{{incident_id}}" \
    {{insecure}} \
    "{{handle}}" "{{peer}}"

ptt-push-target channel_id base="https://api.beepbeep.to" handle="@avery":
  curl --fail-with-body -sS \
    -H "x-turbo-user-handle: {{handle}}" \
    -H "Authorization: Bearer {{handle}}" \
    "{{base}}/v1/channels/{{channel_id}}/ptt-push-target"

ptt-apns-start channel_id base="https://api.beepbeep.to" handle="@avery" bundle_id="com.rounded.Turbo" insecure="--insecure":
  python3 tools/scripts/send_ptt_apns.py \
    --base-url "{{base}}" \
    --handle "{{handle}}" \
    --channel-id "{{channel_id}}" \
    --bundle-id "{{bundle_id}}" \
    {{insecure}}

ptt-apns-print-only channel_id base="https://api.beepbeep.to" handle="@avery" bundle_id="com.rounded.Turbo" insecure="--insecure":
  python3 tools/scripts/send_ptt_apns.py \
    --base-url "{{base}}" \
    --handle "{{handle}}" \
    --channel-id "{{channel_id}}" \
    --bundle-id "{{bundle_id}}" \
    --print-only \
    {{insecure}}

ptt-apns-bridge base="https://api.beepbeep.to" handle_a="@avery" handle_b="@blake" bundle_id="com.rounded.Turbo" insecure="--insecure":
  python3 tools/scripts/ptt_apns_bridge.py \
    --base-url "{{base}}" \
    --handle-a "{{handle_a}}" \
    --handle-b "{{handle_b}}" \
    --bundle-id "{{bundle_id}}" \
    {{insecure}}

ptt-apns-worker base="https://api.beepbeep.to" bundle_id="com.rounded.Turbo" insecure="--insecure":
  python3 tools/scripts/ptt_apns_worker.py \
    --base-url "{{base}}" \
    --bundle-id "{{bundle_id}}" \
    {{insecure}}

cf-apns-worker-dev:
  sh -c 'cd {{justfile_directory()}}/cloudflare/apns-worker && wrangler dev'

cf-apns-worker-deploy:
  sh -c 'cd {{justfile_directory()}}/cloudflare/apns-worker && wrangler deploy'

cf-telemetry-worker-dev:
  sh -c 'cd {{justfile_directory()}}/cloudflare/telemetry-worker && wrangler dev'

cf-telemetry-worker-deploy:
  sh -c 'cd {{justfile_directory()}}/cloudflare/telemetry-worker && wrangler deploy'

telemetry-query query="SHOW TABLES":
  sh -c 'query="$1"; query="${query#query=}"; python3 tools/scripts/query_telemetry.py --query "$query"' _ {{quote(query)}}

telemetry-recent hours="24" limit="50" insecure="":
  sh -c 'hours="{{hours}}"; limit="{{limit}}"; insecure="{{insecure}}"; hours="${hours#hours=}"; limit="${limit#limit=}"; insecure="${insecure#insecure=}"; python3 tools/scripts/query_telemetry.py --hours "$hours" --limit "$limit" $insecure'

telemetry-recent-signal hours="24" limit="50" insecure="":
  sh -c 'hours="{{hours}}"; limit="{{limit}}"; insecure="{{insecure}}"; hours="${hours#hours=}"; limit="${limit#limit=}"; insecure="${insecure#insecure=}"; python3 tools/scripts/query_telemetry.py --hours "$hours" --limit "$limit" --exclude-event-name "backend.presence.heartbeat" $insecure'

telemetry-recent-dev hours="24" limit="50" insecure="":
  sh -c 'hours="{{hours}}"; limit="{{limit}}"; insecure="{{insecure}}"; hours="${hours#hours=}"; limit="${limit#limit=}"; insecure="${insecure#insecure=}"; python3 tools/scripts/query_telemetry.py --hours "$hours" --limit "$limit" --dev-traffic true $insecure'

telemetry-follow hours="1" limit="50" poll="5" insecure="":
  sh -c 'hours="{{hours}}"; limit="{{limit}}"; poll="{{poll}}"; insecure="{{insecure}}"; hours="${hours#hours=}"; limit="${limit#limit=}"; poll="${poll#poll=}"; insecure="${insecure#insecure=}"; python3 tools/scripts/query_telemetry.py --hours "$hours" --limit "$limit" --follow --poll-seconds "$poll" $insecure'

telemetry-follow-signal hours="1" limit="50" poll="5" insecure="":
  sh -c 'hours="{{hours}}"; limit="{{limit}}"; poll="{{poll}}"; insecure="{{insecure}}"; hours="${hours#hours=}"; limit="${limit#limit=}"; poll="${poll#poll=}"; insecure="${insecure#insecure=}"; python3 tools/scripts/query_telemetry.py --hours "$hours" --limit "$limit" --exclude-event-name "backend.presence.heartbeat" --follow --poll-seconds "$poll" $insecure'

telemetry-follow-dev hours="1" limit="50" poll="5" insecure="":
  sh -c 'hours="{{hours}}"; limit="{{limit}}"; poll="{{poll}}"; insecure="{{insecure}}"; hours="${hours#hours=}"; limit="${limit#limit=}"; poll="${poll#poll=}"; insecure="${insecure#insecure=}"; python3 tools/scripts/query_telemetry.py --hours "$hours" --limit "$limit" --dev-traffic true --follow --poll-seconds "$poll" $insecure'

telemetry-user handle hours="24" limit="50" insecure="":
  sh -c 'handle="{{handle}}"; hours="{{hours}}"; limit="{{limit}}"; insecure="{{insecure}}"; handle="${handle#handle=}"; hours="${hours#hours=}"; limit="${limit#limit=}"; insecure="${insecure#insecure=}"; python3 tools/scripts/query_telemetry.py --hours "$hours" --limit "$limit" --user-handle "$handle" $insecure'

simulator-scenario scenario="" base="https://api.beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  python3 tools/scripts/run_simulator_scenarios.py \
    --scenario "{{scenario}}" \
    --base-url "{{base}}" \
    --handle-a "{{handle_a}}" \
    --handle-b "{{handle_b}}"

simulator-scenario-merge base="https://api.beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  python3 tools/scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} \
    --device "{{handle_a}}=sim-scenario-avery" \
    --device "{{handle_b}}=sim-scenario-blake"

simulator-scenario-merge-strict base="https://api.beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  python3 tools/scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} --fail-on-violations \
    --device "{{handle_a}}=sim-scenario-avery" \
    --device "{{handle_b}}=sim-scenario-blake"

simulator-scenario-hosted-strict scenario="" base="https://api.beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  sh -c 'device_a="sim-scenario-avery-$(uuidgen | tr "[:upper:]" "[:lower:]")"; device_b="sim-scenario-blake-$(uuidgen | tr "[:upper:]" "[:lower:]")"; python3 tools/scripts/run_simulator_scenarios.py --scenario "{{scenario}}" --base-url "{{base}}" --handle-a "{{handle_a}}" --handle-b "{{handle_b}}" --device-id-a "$device_a" --device-id-b "$device_b" && python3 tools/scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} --fail-on-violations --device "{{handle_a}}=$device_a" --device "{{handle_b}}=$device_b"'

simulator-scenario-http-control scenario="" base="https://api.beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  sh -c 'device_a="sim-scenario-avery-$(uuidgen | tr "[:upper:]" "[:lower:]")"; device_b="sim-scenario-blake-$(uuidgen | tr "[:upper:]" "[:lower:]")"; python3 tools/scripts/run_simulator_scenarios.py --scenario "{{scenario}}" --base-url "{{base}}" --handle-a "{{handle_a}}" --handle-b "{{handle_b}}" --device-id-a "$device_a" --device-id-b "$device_b" --control-command-transport-policy "http-only" && python3 tools/scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} --fail-on-violations --device "{{handle_a}}=$device_a" --device "{{handle_b}}=$device_b"'

simulator-scenario-local scenario="" base="http://127.0.0.1:8091/s/turbo" handle_a="@avery" handle_b="@blake":
  python3 tools/scripts/run_simulator_scenarios.py \
    --scenario "{{scenario}}" \
    --base-url "{{base}}" \
    --handle-a "{{handle_a}}" \
    --handle-b "{{handle_b}}"

simulator-scenario-merge-local base="http://127.0.0.1:8091/s/turbo" handle_a="@avery" handle_b="@blake":
  python3 tools/scripts/merged_diagnostics.py --base-url "{{base}}" --no-telemetry \
    --device "{{handle_a}}=sim-scenario-avery" \
    --device "{{handle_b}}=sim-scenario-blake"

simulator-scenario-merge-local-strict base="http://127.0.0.1:8091/s/turbo" handle_a="@avery" handle_b="@blake":
  python3 tools/scripts/merged_diagnostics.py --base-url "{{base}}" --no-telemetry --fail-on-violations \
    --device "{{handle_a}}=sim-scenario-avery" \
    --device "{{handle_b}}=sim-scenario-blake"

simulator-ptt-push channel_id event="transmit-start" active_speaker="@blake" sender_user_id="user-blake" sender_device_id="device-blake" device="booted" bundle_id="com.rounded.Turbo":
  python3 tools/scripts/sim_ptt_push.py \
    --device "{{device}}" \
    --bundle-id "{{bundle_id}}" \
    --event "{{event}}" \
    --channel-id "{{channel_id}}" \
    --active-speaker "{{active_speaker}}" \
    --sender-user-id "{{sender_user_id}}" \
    --sender-device-id "{{sender_device_id}}"

simulator-scenario-suite:
  just simulator-scenario

simulator-scenario-suite-hosted-smoke:
  sh -c 'python3 tools/scripts/run_simulator_scenarios.py --scenario "presence_online_projection,beep_accept_ready_refresh_stability" --base-url "https://api.beepbeep.to" --handle-a "@avery" --handle-b "@blake" --device-id-a "sim-scenario-avery-$(uuidgen | tr "[:upper:]" "[:lower:]")" --device-id-b "sim-scenario-blake-$(uuidgen | tr "[:upper:]" "[:lower:]")"'

simulator-scenario-suite-local:
  just simulator-scenario-local "" http://127.0.0.1:8091/s/turbo

simulator-scenario-suite-self-hosted base="http://127.0.0.1:8091/s/turbo" output="/tmp/turbo-simulator-self-hosted-suite.json" scenario="" insecure="":
  python3 backend/scripts/simulator_self_hosted_suite_proof.py \
    --base-url "{{base}}" \
    --scenario "{{scenario}}" \
    --output "{{output}}" \
    {{insecure}}

simulator-fuzz-local seed count base="http://127.0.0.1:8091/s/turbo":
  python3 tools/scripts/run_simulator_fuzz.py run \
    --seed "{{seed}}" \
    --count "{{count}}" \
    --base-url "{{base}}"

simulator-fuzz-local-overnight seed count base="http://127.0.0.1:8091/s/turbo":
  python3 tools/scripts/run_simulator_fuzz.py run \
    --seed "{{seed}}" \
    --count "{{count}}" \
    --base-url "{{base}}" \
    --stop-on-first-failure

reliability-fuzz-local-overnight seed count base="http://127.0.0.1:8091/s/turbo":
  just engine-fuzz-local "{{seed}}" "{{count}}" "{{base}}"
  just simulator-fuzz-local-overnight "{{seed}}" "{{count}}" "{{base}}"

simulator-fuzz-replay artifact_dir:
  python3 tools/scripts/run_simulator_fuzz.py replay --artifact-dir "{{artifact_dir}}"

simulator-fuzz-shrink artifact_dir:
  python3 tools/scripts/run_simulator_fuzz.py shrink --artifact-dir "{{artifact_dir}}"

production-replay diagnostics_json output_dir="/tmp/turbo-production-replay" name="":
  python3 tools/scripts/convert_production_replay.py \
    --merged-diagnostics-json "{{diagnostics_json}}" \
    --output-dir "{{output_dir}}" \
    --name "{{name}}"

synthetic-conversation-probe base="https://api.beepbeep.to" caller="@quinn" callee="@sasha" iterations="1" artifact_dir="/tmp/turbo-synthetic-conversation-probe" insecure="--insecure":
  python3 tools/scripts/synthetic_conversation_probe.py \
    --base-url "{{base}}" \
    --caller "{{caller}}" \
    --callee "{{callee}}" \
    --iterations "{{iterations}}" \
    --artifact-dir "{{artifact_dir}}" \
    {{insecure}}

slo-dashboard synthetic_conversation output_dir="/tmp/turbo-slo-dashboard" name="turbo-slo-dashboard":
  python3 tools/scripts/slo_dashboard.py \
    --synthetic-conversation "{{synthetic_conversation}}" \
    --output-dir "{{output_dir}}" \
    --name "{{name}}" \
    --fail-on-breach

protocol-model-checks tla_jar="/tmp/tla2tools.jar" output_dir="/tmp/turbo-protocol-model-checks":
  python3 tools/scripts/protocol_model_check.py \
    --tla-jar "{{tla_jar}}" \
    --output-dir "{{output_dir}}"

protocol-session-generation-model-check tla_jar="/tmp/tla2tools.jar" output_dir="/tmp/turbo-protocol-session-generation-model-check":
  python3 tools/scripts/protocol_model_check.py \
    --module TurboSessionGeneration \
    --config TurboSessionGeneration.cfg \
    --tla-jar "{{tla_jar}}" \
    --output-dir "{{output_dir}}" \
    --skip-swift-properties

protocol-talk-turn-actor-model-check tla_jar="/tmp/tla2tools.jar" output_dir="/tmp/turbo-protocol-talk-turn-actor-model-check":
  python3 tools/scripts/protocol_model_check.py \
    --spec-dir backend/specs/tla \
    --module TurboTalkTurnActor \
    --config TurboTalkTurnActor.cfg \
    --tla-jar "{{tla_jar}}" \
    --output-dir "{{output_dir}}" \
    --skip-swift-properties

swift-test-target name:
  python3 tools/scripts/run_targeted_swift_tests.py \
    --project client/ios/Turbo.xcodeproj \
    --test-source-dir client/ios/TurboTests \
    --name "{{name}}"

ptt-readiness-fuzz:
  just swift-test-target pttReadinessAdapterFuzz

audio-packet-fuzz:
  just swift-test-target audioPacketPlaybackGateFuzz
  just swift-test-target adaptiveVoicePlayoutBufferFuzzesLossReorderDuplicateAndDrain
  just swift-test-target audioTransportLoopbackFuzzesCaptureEnvelopeGateAndPlayout
  just swift-test-target audioPlaybackSchedulerFuzzesLateIOCycleCushionAndDrain
  just swift-test-target pttWakeActivationTimingFuzzesBufferedAudioUntilFlushOrFallback
  just swift-test-target audioIncidentCorpusReplaysExtractedDeviceTimelines
  just swift-test-target audioIncidentCorpusMutatesAcrossPlaybackStateEnvelopes

audio-incident-corpus source output="/tmp/turbo-audio-incident-corpus.json" name="":
  python3 tools/scripts/audio_incident_corpus.py "{{source}}" --output "{{output}}" --name "{{name}}"

audio-incident-replay corpus="shared/fixtures/audio_incidents/device_audio_smoke_corpus.json":
  TURBO_AUDIO_INCIDENT_CORPUS_PATH="{{corpus}}" just swift-test-target audioIncidentCorpusReplaysExtractedDeviceTimelines

audio-incident-mutate corpus="shared/fixtures/audio_incidents/device_audio_smoke_corpus.json":
  TURBO_AUDIO_INCIDENT_CORPUS_PATH="{{corpus}}" just swift-test-target audioIncidentCorpusMutatesAcrossPlaybackStateEnvelopes

audio-media-core-replay trace:
  python3 tools/scripts/audio_media_core_replay.py "{{trace}}"

swift-test-suite:
  python3 tools/scripts/run_swift_test_suite.py

engine-test:
  swift test --package-path client/ios/Packages/TurboEngine

engine-scenario scenario="":
  swift run --package-path client/ios/Packages/TurboEngine turbo-engine scenario "{{scenario}}"

engine-scenario-local scenario="" base="http://127.0.0.1:8091/s/turbo":
  swift run --package-path client/ios/Packages/TurboEngine turbo-engine scenario-local "{{scenario}}" "{{base}}"

engine-scenario-diff-local scenario="" base="http://127.0.0.1:8091/s/turbo":
  swift run --package-path client/ios/Packages/TurboEngine turbo-engine scenario-diff-local "{{scenario}}" "{{base}}"

engine-fuzz-local seed count base="http://127.0.0.1:8091/s/turbo":
  swift run --package-path client/ios/Packages/TurboEngine turbo-engine fuzz-local "{{seed}}" "{{count}}" "{{base}}"

engine-fuzz-corpus corpus="client/ios/Packages/TurboEngine/Fixtures/fuzz-corpus.json":
  swift run --package-path client/ios/Packages/TurboEngine turbo-engine fuzz-corpus "{{corpus}}"

engine-trace-replay trace:
  swift run --package-path client/ios/Packages/TurboEngine turbo-engine trace-replay "{{trace}}"

engine-trace-extract source output="/tmp/turbo-engine-trace.json":
  python3 tools/scripts/extract_engine_trace.py "{{source}}" --output "{{output}}"

engine-invariant-coverage:
  python3 tools/scripts/check_engine_invariant_coverage.py

reliability-gate-regressions:
  just engine-test
  just engine-fuzz-corpus
  just engine-trace-replay client/ios/Packages/TurboEngine/Fixtures/trace-replay-smoke.json
  jq -n --slurpfile trace client/ios/Packages/TurboEngine/Fixtures/trace-replay-smoke.json '{reports:[{structuredDiagnostics:{engineTrace:$trace[0]}}]}' > /tmp/turbo-merged-engine-trace-smoke.json
  just engine-trace-extract /tmp/turbo-merged-engine-trace-smoke.json /tmp/turbo-engine-trace-smoke-extracted.json
  just engine-trace-replay /tmp/turbo-engine-trace-smoke-extracted.json
  python3 -m py_compile tools/scripts/run_simulator_scenarios.py tools/scripts/run_targeted_swift_tests.py tools/scripts/run_swift_test_suite.py tools/scripts/device_app.py tools/scripts/test_device_app.py tools/scripts/merged_diagnostics.py tools/scripts/reliability_intake.py tools/scripts/check_invariant_registry.py tools/scripts/check_engine_invariant_coverage.py tools/scripts/extract_engine_trace.py tools/scripts/audio_incident_corpus.py tools/scripts/test_audio_incident_corpus.py tools/scripts/audio_media_core_replay.py tools/scripts/test_audio_media_core_replay.py tools/scripts/convert_production_replay.py tools/scripts/synthetic_conversation_probe.py tools/scripts/slo_dashboard.py tools/scripts/protocol_model_check.py tools/scripts/postdeploy_check.py tools/scripts/physical_device_boundary_manifest.py tools/scripts/physical_device_boundary_proof.py tools/scripts/physical_device_boundary_collect.py tools/scripts/physical_device_boundary_merge.py tools/scripts/physical_device_boundary_finalize.py
  python3 tools/scripts/test_audio_incident_corpus.py
  python3 tools/scripts/test_audio_media_core_replay.py
  python3 tools/scripts/convert_production_replay.py --merged-diagnostics-json shared/fixtures/production_replay/merged_diagnostics.json --output-dir /tmp/turbo-production-replay-smoke --name fixture_production_replay
  python3 tools/scripts/synthetic_conversation_probe.py --fixture-report shared/fixtures/synthetic_conversation_probe/route_probe_success.json --artifact-dir /tmp/turbo-synthetic-conversation-probe-smoke --iterations 2 --label fixture-smoke
  python3 tools/scripts/slo_dashboard.py --synthetic-conversation /tmp/turbo-synthetic-conversation-probe-smoke/synthetic-conversation-probe.json --output-dir /tmp/turbo-slo-dashboard-smoke --name fixture-slo-dashboard --fail-on-breach
  python3 tools/scripts/protocol_model_check.py --skip-tlc --skip-swift-properties --output-dir /tmp/turbo-protocol-model-checks-static
  python3 tools/scripts/check_invariant_registry.py
  python3 tools/scripts/check_engine_invariant_coverage.py
  just swift-test-target signalingJoinDriftReassertsRequestedBackendChannelForActiveDevicePTTEvidence
  just swift-test-target selectedConversationReducerConnectionTimeoutClearsSenderAutoJoinIdleGap
  just swift-test-target selectedConnectionTimeoutDoesNotInterruptInFlightBackendConnect
  just swift-test-target scenarioBackendExpectationAcceptsReadyWhenPhaseHasProgressed

reliability-gate-smoke:
  just reliability-gate-regressions
  just simulator-scenario-hosted-strict "presence_online_projection,beep_accept_ready_refresh_stability,background_wake_refresh_stability"

reliability-gate-full:
  just reliability-gate-regressions
  just simulator-scenario-hosted-strict

reliability-gate-local:
  just reliability-gate-regressions
  just simulator-scenario-suite-local
  just simulator-scenario-merge-local-strict
