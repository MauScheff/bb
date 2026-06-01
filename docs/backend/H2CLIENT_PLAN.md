# H2 Client Plan

Status: active/paused implementation plan.
Scope: standalone Unison HTTP/2 client boundary, MVP, phases, APNs transport proof.
Related docs: [`APNS_DELIVERY_PLAN.md`](/Users/mau/Development/bb/docs/client/APNS_DELIVERY_PLAN.md) owns Turbo APNs delivery architecture; [`APNS_ES256_PLAN.md`](/Users/mau/Development/bb/docs/client/APNS_ES256_PLAN.md) owns ES256 signing work.

## Goal

Build the smallest viable outbound HTTP/2 client path for TLS HTTPS requests, with APNs as the forcing case. This is a library plan, not a Turbo feature plan; Turbo consumes it later as a local dependency.

## Project Boundary

Current isolated project:

- codebase: `.unison-h2-codebase`
- project: `h2client/main`

Turbo integration should happen later via `lib.install.local` into `turbo`.

## Non-Goals

Not in scope for the first version:

- server-side HTTP/2
- general browser-grade HTTP/2 support
- proxy support
- connection pooling
- connection reuse
- websocket support
- HTTP/2 push
- trailer-heavy edge cases
- full multiplexing API surface

## MVP Target

The MVP should be able to:

1. open an outbound TLS connection
2. negotiate or assume an HTTP/2-capable connection as required by the target
3. send the HTTP/2 client preface and initial SETTINGS
4. send one request on one stream
5. receive response HEADERS and DATA
6. expose response status, headers, and body

That is enough to prove the APNs transport path.

## Namespace Shape

Suggested public namespace root:

- `h2client`

Suggested modules:

- `h2client.bytes`
  - byte helpers
- `h2client.bits`
  - fixed-width integer encoding/decoding
- `h2client.frame`
  - frame types
  - frame header encoding/decoding
- `h2client.hpack`
  - header representation
  - static table support
  - literal header encoding/decoding
- `h2client.connection`
  - connection preface
  - SETTINGS exchange
  - stream bookkeeping
- `h2client.client`
  - single-request API
- `h2client.apns`
  - APNs-specific wrapper later

## Implementation Phases

### Phase 1: Foundation

Pure types and helpers only:

- protocol constants
- frame header structure
- stream identifiers
- settings representation
- pure bytes helpers

### Phase 2: Frame Codec

Implement:

- frame header encode/decode
- SETTINGS encode/decode
- DATA frame encode/decode
- HEADERS frame shell
- GOAWAY / RST_STREAM parsing as needed

### Phase 3: Minimal HPACK

Implement the smallest useful header codec:

- static table lookup
- literal header encoding without dynamic table reliance
- just enough decode support to inspect response headers

### Phase 4: Client Connection Flow

Implement:

- client preface
- initial SETTINGS send
- peer SETTINGS receive
- SETTINGS ACK
- one stream request lifecycle

### Phase 5: High-Level Request API

Expose a narrow request/response API suitable for:

- method
- path
- authority
- headers
- optional body

### Phase 6: APNs Proof

Use the library against:

1. a known HTTP/2-capable endpoint
2. then APNs

## Proof Plan

### Pure proof first

For pure modules, require:

- example tests
- property-style tests where appropriate

### Concrete tests

Add tests for:

- frame header roundtrips
- known SETTINGS payload encoding
- stream identifier constraints
- HPACK static-table examples

### Integration proof later

Only after the pure layers are stable:

- local end-to-end connection proof
- then hosted proof
- then Turbo integration

## Exit Criteria For Turbo Integration

Do not integrate into Turbo until:

1. `h2client/main` has a stable request/response surface
2. pure tests are green
3. the client has proven one successful HTTP/2 response
4. the APNs path is at least transport-valid

Only then should Turbo consume it as a local library.

## Current Status

As of April 14, 2026, the standalone project has:

- a tested pure HTTP/2 frame/settings/request/session core
- a loaded TLS executor in `h2client/main`
- standalone probe entrypoints that run from the `h2client` project itself
- a local Unison runtime patch that exposes ALPN configuration via
  `Tls.ClientConfig.alpn.set`

The current transport finding is:

- with the stock runtime, `h2client.probe.run.unisonCloud.firstChunk` returned
  `HTTP/1.1 400 Bad Request`
- with the patched local runtime and `Tls.ClientConfig.alpn.set ["h2"]`, the
  same probe now returns a real HTTP/2 server preface chunk:
  `SETTINGS conn len:30 flags:0`

So the ALPN/runtime boundary is now proven locally. The remaining blocker is no
longer protocol negotiation. It is the client session loop: the current
request/response path still hangs on full end-to-end fetch, which means the
next work is stream/session handling after the initial HTTP/2 handshake rather
than TLS negotiation itself.
