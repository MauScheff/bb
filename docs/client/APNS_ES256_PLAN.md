# Unison ES256 Library Plan

Status: active/paused implementation plan.
Scope: standalone Unison ES256 signing library design, namespace shape, phases, verification.
Related docs: [`APNS_DELIVERY_PLAN.md`](/Users/mau/Development/bb/docs/client/APNS_DELIVERY_PLAN.md) owns Turbo APNs delivery architecture; [`H2CLIENT_PLAN.md`](/Users/mau/Development/bb/docs/backend/H2CLIENT_PLAN.md) owns outbound HTTP/2 transport work.

## Goal

Build a standalone Unison library for:

- ASN.1 DER decoding
- PKCS#8 EC private-key parsing
- `secp256r1` / P-256 arithmetic
- deterministic ECDSA signing
- JWT `ES256` token construction

Keep the library generic, separately provable, and pluggable into Turbo after proof.

## Non-Goals

Out of scope:

- APNs-specific request sending
- Turbo-specific routes
- Turbo-specific wake flows
- backend integration details

Those belong to a separate integration slice after the library is proven.

## Extraction Boundary

Treat this as a separate project boundary, even if the first implementation lives locally. Design for later extraction.

Suggested namespace root:

- `turbo.lib.es256`

If we later extract it, the public API should already be generic enough to rename cleanly, for example:

- `es256.der`
- `es256.pkcs8`
- `es256.p256`
- `es256.jwt`

## Public API Shape

The library should expose a small, typed surface:

- parse PEM/PKCS#8 private key bytes into a validated P-256 signing key
- derive a public key from that signing key
- sign arbitrary message bytes with deterministic ECDSA P-256
- encode JWT `ES256` tokens from header + claims bytes/text
- verify signatures for test/proof use

The public API should not expose loose partial parsing state or invalid key material.

## Namespace Plan

- `turbo.lib.es256.integer`
  - modular arithmetic
  - extended gcd
  - modular inverse
  - modular exponentiation
- `turbo.lib.es256.bytes`
  - byte/integer conversion
  - fixed-width encodings
  - base64url helpers
- `turbo.lib.es256.der`
  - minimal DER reader
  - INTEGER / OCTET STRING / BIT STRING / SEQUENCE / OBJECT IDENTIFIER parsing
- `turbo.lib.es256.pkcs8`
  - PEM decoding entrypoint
  - PKCS#8 parser
  - EC private-key extraction
  - P-256 OID validation
- `turbo.lib.es256.p256`
  - curve constants
  - scalar normalization
  - point representation
  - point add / double / scalar multiply
  - public-key derivation
  - point validity checks
- `turbo.lib.es256.ecdsa`
  - deterministic nonce derivation
  - sign
  - verify
  - raw `r || s` encoding
- `turbo.lib.es256.jwt`
  - JWT signing-input formatting
  - `ES256` token construction

## Data Model

Prefer strong internal types over raw `Bytes`.

Examples:

- `PemDocument`
- `DerValue`
- `Pkcs8PrivateKey`
- `P256Scalar`
- `P256Point`
- `SigningKey`
- `VerificationKey`
- `Signature`
- `JwtHeader`
- `JwtClaims`
- `JwtSigningInput`

Illegal states should be unrepresentable where practical.

## Implementation Phases

### Phase 1: Foundation

Pure helpers only:

- modular arithmetic
- byte/integer conversion
- base64url encoding

Current scratch work started here:

- [turbo_es256_foundation.u](/Users/mau/Development/bb/turbo_es256_foundation.u)

That file should be treated as provisional scaffolding and moved under the library namespace as the implementation matures.

### Phase 2: DER

Implement a minimal strict DER parser:

- short/long length decoding
- SEQUENCE parsing
- INTEGER parsing
- OCTET STRING parsing
- BIT STRING parsing
- OBJECT IDENTIFIER parsing

The parser should fail closed on malformed encodings.

### Phase 3: PKCS#8

Parse the private-key format used by Apple `.p8` EC keys, but keep the implementation generic:

- PEM armor stripping
- base64 decode
- PKCS#8 structure parse
- algorithm OID validation
- curve OID validation
- extract private scalar

Do not bake Apple assumptions into the parser beyond standards-based OIDs.

### Phase 4: P-256 Arithmetic

Implement:

- point-at-infinity
- affine point addition
- point doubling
- scalar multiplication
- public-key derivation from private scalar
- on-curve checks

Start with clarity first. Optimize only if needed later.

### Phase 5: Deterministic ECDSA

Implement deterministic signing.

Requirements:

- valid scalar range checks
- deterministic nonce derivation
- nonzero `r` / `s`
- fixed-width raw signature encoding
- verification routine for proof/tests

### Phase 6: JWT ES256

Implement generic JWT token creation:

- base64url header encoding
- base64url claims encoding
- signing-input assembly
- `ES256` signing
- compact token output

This layer should know nothing about APNs.

## Verification Plan

## 1. Purity and Isolation

Most of the library should be pure and testable without `Http`, `Config`, `IO`, or backend abilities.

That is the first verification boundary:

- parser logic pure
- curve arithmetic pure
- ECDSA sign/verify pure
- JWT formatting pure

## 2. Example Tests

Add concrete test vectors for:

- modular inverse known values
- DER decoding examples
- PKCS#8 parsing of fixed fixtures
- public-key derivation known answers
- ECDSA known-answer vectors
- JWT token structure examples

## 3. Property-Based Tests

Property tests should cover the pure math and encoding core:

- `modNormalize m x` always lands in `[0, m)` for positive `m`
- `modInverse m x = Some y` implies `(x * y) mod m = 1`
- valid points remain on-curve after add/double
- scalar multiplication identities:
  - `0 * G = infinity`
  - `1 * G = G`
  - `n * G = infinity` for the curve order `n`
- derived public keys are on-curve
- deterministic signing:
  - same key + same message => same signature
- sign/verify roundtrip:
  - signature produced by `sign` verifies with the derived public key
- fixed-width signature encoding:
  - raw signature size is exactly `64` bytes

## 4. Independent Cross-Checks

The library should not only prove itself against itself.

We need cross-checks against an independent implementation:

- compare public-key derivation against OpenSSL reference output
- compare signature bytes against OpenSSL/Python vectors
- compare JWT compact output against an external reference

This is the strongest practical verification we can do here without machine-checked proofs.

## 5. “Formal” Verification Scope

If by “formal” we mean theorem-prover-level proof, that is out of scope for the current repo and toolchain.

What we can do rigorously:

- precise typed model
- pure functions
- total parsing where possible
- property-based tests
- known-answer vectors
- cross-implementation differential tests

That should be the required proof bar for accepting the library into Turbo.

## 6. Integration Contract

Only after the library is proven should we add a thin integration layer for Turbo:

- load key/config
- build APNs JWT claims
- send APNs request

That integration layer should be small and disposable.

## Definition of Done

The library is ready to integrate when:

1. it is isolated under its own namespace boundary
2. the core parser/curve/signing/JWT layers are pure
3. example tests pass
4. property-based tests pass
5. cross-checks against an independent implementation pass
6. the public API is generic and contains no Turbo/APNs assumptions

## Immediate Next Step

Implement the first library-owned modules:

- `turbo.lib.es256.der`
- `turbo.lib.es256.pkcs8`

and keep them pure and typechecked before any Turbo integration work.
