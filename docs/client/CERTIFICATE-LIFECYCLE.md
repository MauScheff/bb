# Direct QUIC Certificate Lifecycle

Status: active reference.
Scope: Direct QUIC fingerprint-only device identity, certificate lifecycle, registration contract, verification.
Related docs: [`DIRECT_QUIC_TRANSPORT.md`](/Users/mau/Development/bb/docs/client/DIRECT_QUIC_TRANSPORT.md) owns the broader Direct QUIC transport plan.

## Summary

Production Direct QUIC uses fingerprint-only device identity. Each iOS device creates/reuses a local P-256 key and self-signed certificate in Keychain. Private key and certificate DER stay on device; backend stores and projects only the active fingerprint for the authenticated device id.

Direct path requires three matching facts:

- the backend-authenticated user and device registration;
- the backend-projected active fingerprint for the currently connected peer device;
- the TLS peer certificate fingerprint observed locally by Network.framework.

Any missing/mismatched fact disables Direct QUIC for that attempt; relay remains active.

## Production Contract

Device registration accepts:

```json
{
  "deviceId": "device-id",
  "directQuicIdentity": {
    "fingerprint": "sha256:<64 hex chars>"
  }
}
```

During migration, registration may still receive `certificateDerBase64` from older clients. The backend ignores that field and must not store or return it.

Registration and readiness responses expose:

```json
{
  "directQuicIdentity": {
    "fingerprint": "sha256:<64 hex chars>",
    "status": "active",
    "createdAt": "...",
    "updatedAt": "..."
  }
}
```

Readiness uses `peerDirectQuicIdentity` with the same fingerprint-only shape. It is only projected for the currently connected peer target device.

## Lifecycle Rules

- One active Direct QUIC fingerprint exists per backend `deviceId`.
- Registering the same fingerprint is idempotent.
- Registering a different fingerprint for the same `deviceId` rotates the identity by replacing the active fingerprint.
- A missing, invalid, or unregistered local identity disables Direct QUIC for that attempt.
- A missing peer fingerprint disables Direct QUIC for that attempt.
- A signaled offer/answer fingerprint must match the backend-projected peer fingerprint.
- The observed TLS peer certificate fingerprint must match the expected signaled/backend fingerprint.
- Relay fallback is the required behavior for any uncertainty.

The current implementation does not need a separate certificate chain, CA, or backend X.509 parser. The backend is authoritative for `deviceId -> active fingerprint`; the iOS TLS layer proves the peer owns the matching certificate during the direct connection.

## `.p12` Status

Production no longer needs installed or imported `.p12` identities.

The `.p12` import path remains a debug/developer fallback for diagnostics and older test workflows. Production provisioning should prefer the generated local identity:

1. generate or reuse the local production identity;
2. register only its fingerprint;
3. use that local identity for Direct QUIC TLS;
4. validate the peer by fingerprint.

Old `.p12` files can be left installed, but they should not be required for normal production Direct QUIC. A production Direct QUIC offer should not depend on `debugBypass=true`.

## Verification

Use these checks after certificate or identity changes:

```bash
just direct-quic-provisioning-probe
just route-probe
```

The provisioning probe verifies:

- config advertises Direct QUIC provisioning and upgrade state;
- invalid fingerprints are rejected;
- fingerprint-only registration succeeds;
- old `certificateDerBase64` payloads are accepted but not returned;
- rotation replaces the active fingerprint;
- readiness projects the connected peer fingerprint;
- responses do not expose certificate DER material.

The route probe verifies the broader production control plane and peer readiness projection.

For physical-device verification, connect two devices and confirm diagnostics show:

- `directQuicProvisioningStatus=ready`;
- `supportsDirectQuicUpgrade=true`;
- automatic Direct QUIC probe with `debugBypass=false`;
- Direct QUIC offer/answer fingerprints;
- `Direct QUIC media path activated`;
- no `certificateDerBase64` in registration or readiness payloads.
