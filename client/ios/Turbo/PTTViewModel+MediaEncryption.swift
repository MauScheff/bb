import CryptoKit
import Foundation

extension PTTViewModel {
    func provisionMediaEncryptionIdentityForRegistration(
        deviceID: String
    ) -> MediaEncryptionIdentityRegistrationMetadata? {
        mediaEncryptionProvisioningStatus = "provisioning"
        do {
            let identity = try MediaEncryptionIdentityManager.provisionIdentity(deviceID: deviceID)
            mediaEncryptionLocalIdentity = identity
            mediaEncryptionProvisioningStatus = "ready"
            diagnostics.record(
                .media,
                message: "Media encryption identity provisioned",
                metadata: [
                    "deviceId": deviceID,
                    "scheme": identity.registration.scheme,
                    "fingerprint": identity.registration.fingerprint,
                ]
            )
            return identity.registration
        } catch {
            mediaEncryptionProvisioningStatus = "failed"
            diagnostics.record(
                .media,
                level: .error,
                message: "Media encryption identity provisioning failed",
                metadata: [
                    "deviceId": deviceID,
                    "error": error.localizedDescription,
                ]
            )
            return nil
        }
    }

    func currentMediaEncryptionIdentityRegistrationMetadata() -> MediaEncryptionIdentityRegistrationMetadata? {
        guard let backend = backendServices else { return mediaEncryptionLocalIdentity?.registration }
        if let existing = mediaEncryptionLocalIdentity,
           existing.registration.fingerprint == MediaEncryptionIdentityManager.fingerprint(
            forPublicKey: existing.privateKey.publicKey.rawRepresentation
           ) {
            return existing.registration
        }
        return provisionMediaEncryptionIdentityForRegistration(deviceID: backend.deviceID)
    }

    func configureMediaEncryptionSessionIfPossible(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String?,
        logPreservedSession: Bool = true
    ) {
        if let existing = compatibleMediaEncryptionSession(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: peerDeviceID
        ) {
            guard logPreservedSession else { return }
            if channelReadinessByContactID[contactID]?.peerMediaEncryptionRegistration == nil {
                diagnostics.record(
                    .media,
                    message: "Preserved existing media E2EE session while peer identity is transiently unavailable",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": existing.peerDeviceID,
                    ]
                )
            } else {
                diagnostics.record(
                    .media,
                    message: "Preserved existing media E2EE session for stable channel peer",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": existing.peerDeviceID,
                        "keyId": existing.keyID,
                    ]
                )
            }
            return
        }
        guard let localIdentity = mediaEncryptionLocalIdentity else {
            mediaRuntime.setMediaEncryptionSession(nil, for: contactID)
            if mediaRuntime.takeShouldLogMediaEncryptionUnavailable(
                contactID: contactID,
                reason: "missing-local-identity"
            ) {
                diagnostics.record(
                    .media,
                    message: "Media E2EE unavailable because local identity is missing",
                    metadata: ["contactId": contactID.uuidString, "channelId": channelID]
                )
            }
            return
        }
        guard let peerDeviceID,
              let peerIdentity = channelReadinessByContactID[contactID]?.peerMediaEncryptionRegistration else {
            mediaRuntime.setMediaEncryptionSession(nil, for: contactID)
            return
        }
        let session: MediaEncryptionSession
        do {
            session = try MediaEncryptionSession(
                channelID: channelID,
                localDeviceID: backendServices?.deviceID ?? "",
                peerDeviceID: peerDeviceID,
                localFingerprint: localIdentity.registration.fingerprint,
                peerFingerprint: peerIdentity.fingerprint,
                localPrivateKey: localIdentity.privateKey,
                peerIdentity: peerIdentity
            )
        } catch {
            mediaRuntime.setMediaEncryptionSession(nil, for: contactID)
            diagnostics.record(
                .media,
                level: .error,
                message: "Media E2EE session configuration failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "scheme": peerIdentity.scheme,
                    "error": error.localizedDescription,
                ]
            )
            return
        }
        mediaRuntime.setMediaEncryptionSession(session, for: contactID)
        diagnostics.record(
            .media,
            message: "Configured media E2EE session",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "peerDeviceId": peerDeviceID,
                "scheme": peerIdentity.scheme,
                "keyId": session.keyID,
            ]
        )
    }

    func sealOutgoingMediaPayloadIfPossible(
        _ payload: String,
        target: TransmitTarget
    ) throws -> String {
        try outgoingMediaPayloadSealer(target: target).seal(payload)
    }

    func outgoingMediaPayloadSealer(target: TransmitTarget) -> OutgoingMediaPayloadSealer {
        var session = matchingMediaEncryptionSession(
            contactID: target.contactID,
            channelID: target.channelID,
            peerDeviceID: target.deviceID
        )
        if session == nil, isMediaEncryptionRequired(for: target.contactID) {
            configureMediaEncryptionSessionIfPossible(
                contactID: target.contactID,
                channelID: target.channelID,
                peerDeviceID: target.deviceID
            )
            session = mediaRuntime.mediaEncryptionSession(for: target.contactID)
        }
        guard let session else {
            if mediaRuntime.takeShouldLogMediaEncryptionPlaintextFallback(
                contactID: target.contactID,
                direction: "outgoing"
            ) {
                diagnostics.record(
                    .media,
                    level: .notice,
                    message: "Sending plaintext media payload because E2EE session is unavailable",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "toDeviceId": target.deviceID,
                        "peerIdentityAdvertised": String(isMediaEncryptionRequired(for: target.contactID)),
                        "localIdentityPresent": String(mediaEncryptionLocalIdentity != nil),
                    ]
                )
            }
            return OutgoingMediaPayloadSealer(session: nil, sequenceCounter: nil)
        }
        return OutgoingMediaPayloadSealer(
            session: session,
            sequenceCounter: mediaRuntime.mediaEncryptionSendSequenceCounter(for: target.contactID)
        )
    }

    func openIncomingMediaPayloadIfPossible(
        _ payload: String,
        channelID: String,
        fromDeviceID: String,
        contactID: UUID
    ) throws -> String? {
        guard MediaEncryptedAudioPacket.isEncodedPacket(payload) else {
            if isMediaEncryptionRequired(for: contactID) {
                if mediaRuntime.takeShouldLogMediaEncryptionPlaintextFallback(
                    contactID: contactID,
                    direction: "incoming"
                ) {
                    diagnostics.record(
                        .media,
                        level: .notice,
                        message: "Accepted plaintext media payload during opportunistic E2EE fallback",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "fromDeviceId": fromDeviceID,
                            "peerIdentityAdvertised": "true",
                            "sessionConfigured": String(mediaRuntime.mediaEncryptionSession(for: contactID) != nil),
                        ]
                    )
                }
            }
            return payload
        }
        guard let session = mediaRuntime.mediaEncryptionSession(for: contactID) else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Encrypted media payload arrived without an E2EE session",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                ]
            )
            return nil
        }
        guard session.channelID == channelID,
              session.peerDeviceID == fromDeviceID else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Encrypted media payload matched a stale E2EE session",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "sessionChannelId": session.channelID,
                    "sessionPeerDeviceId": session.peerDeviceID,
                ]
            )
            return nil
        }
        let packet = try MediaEndToEndEncryption.decodePacket(payload)
        let opened = try MediaEndToEndEncryption.openTransportPayload(
            payload,
            using: session.incomingSymmetricKey,
            context: session.incomingContext
        )
        switch mediaRuntime.acceptMediaEncryptionReceiveSequence(
            packet.sequenceNumber,
            for: contactID
        ) {
        case .accepted:
            return opened

        case .duplicate:
            diagnostics.record(
                .media,
                message: "Ignored duplicate encrypted audio packet",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "sequenceNumber": String(packet.sequenceNumber),
                ]
            )
            return nil

        case .replayOrReordered:
            diagnostics.recordInvariantViolation(
                invariantID: "media.e2ee_replayed_audio_packet",
                scope: .local,
                message: "encrypted audio packet sequence was replayed or reordered",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "sequenceNumber": String(packet.sequenceNumber),
                ]
            )
            return nil
        }
    }

    func mediaEncryptionIsRequired(for contactID: UUID) -> Bool {
        channelReadinessByContactID[contactID]?.peerMediaEncryptionRegistration != nil
    }

    func mediaEndToEndEncryptionIsActive(
        contactID: UUID,
        channelID: String?
    ) -> Bool {
        guard let session = mediaRuntime.mediaEncryptionSession(for: contactID) else {
            return false
        }
        guard let channelID else {
            return true
        }
        return session.channelID == channelID
    }

    func localReceiverMediaEncryptionReadyForLiveMedia(
        contactID: UUID,
        channelID: String?,
        peerDeviceID: String?
    ) -> Bool {
        guard mediaEncryptionIsRequired(for: contactID) else { return true }
        guard let channelID,
              let peerDeviceID else {
            return false
        }
        if matchingMediaEncryptionSession(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: peerDeviceID
        ) != nil {
            return true
        }
        configureMediaEncryptionSessionIfPossible(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: peerDeviceID
        )
        return matchingMediaEncryptionSession(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: peerDeviceID
        ) != nil
    }

    func shouldDeferIncomingEncryptedMediaUntilSessionReady(
        _ payload: String,
        channelID: String,
        fromDeviceID: String,
        contactID: UUID
    ) -> Bool {
        guard MediaEncryptedAudioPacket.isEncodedPacket(payload) else { return false }
        return matchingMediaEncryptionSession(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: fromDeviceID
        ) == nil
    }

    private func matchingMediaEncryptionSession(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String?
    ) -> MediaEncryptionSession? {
        guard let peerDeviceID,
              let session = mediaRuntime.mediaEncryptionSession(for: contactID),
              session.channelID == channelID,
              session.peerDeviceID == peerDeviceID else {
            return nil
        }
        return session
    }

    private func compatibleMediaEncryptionSession(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String?
    ) -> MediaEncryptionSession? {
        guard let session = mediaRuntime.mediaEncryptionSession(for: contactID),
              session.channelID == channelID else {
            return nil
        }
        if let peerDeviceID, session.peerDeviceID != peerDeviceID {
            return nil
        }
        return session
    }

    private func isMediaEncryptionRequired(for contactID: UUID) -> Bool {
        mediaEncryptionIsRequired(for: contactID)
    }
}
