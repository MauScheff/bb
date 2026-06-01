import Foundation

extension PTTViewModel {
    func observePeerVoiceMediaCapabilities(
        _ capabilities: VoiceMediaCapabilities?,
        contactID: UUID,
        peerDeviceID: String,
        source: String
    ) {
        guard let capabilities else { return }
        let changed = mediaRuntime.markVoiceMediaCapabilities(
            capabilities,
            for: contactID,
            peerDeviceID: peerDeviceID,
            source: source
        )
        if changed {
            diagnostics.record(
                .media,
                message: "Peer voice media capabilities observed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "peerDeviceId": peerDeviceID,
                    "source": source,
                    "capabilities": capabilities.diagnosticsValue,
                    "supportsOpusV2": String(capabilities.supportsOpusV2),
                ]
            )
        }
        updateActiveMediaSessionVoicePolicyIfNeeded(
            for: contactID,
            reason: source
        )
    }

    func outboundVoiceMediaPayloadFormat(for target: TransmitTarget) -> VoiceMediaPayloadFormat {
        return mediaRuntime.outboundVoiceMediaPayloadFormat(for: target.contactID)
    }

    func updateActiveMediaSessionVoicePolicyIfNeeded(
        for contactID: UUID,
        reason: String
    ) {
        let target = transmitProjection.activeTarget
        guard target?.contactID == contactID || mediaSessionContactID == contactID else { return }
        let policy: VoiceMediaPayloadFormat
        if let target, target.contactID == contactID {
            policy = outboundVoiceMediaPayloadFormat(for: target)
        } else {
            policy = mediaRuntime.outboundVoiceMediaPayloadFormat(for: contactID)
        }
        mediaServices.session()?.updateOutboundVoiceMediaPolicy(policy)
        let opusPolicy = outboundOpusEncodingPolicy(for: contactID)
        mediaServices.session()?.updateOutboundOpusEncodingPolicy(opusPolicy)
        diagnostics.record(
            .media,
            message: "Applied outbound voice media policy",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": target?.channelID ?? contacts.first(where: { $0.id == contactID })?.backendChannelId ?? "unknown",
                "peerDeviceId": target?.deviceID
                    ?? mediaRuntime.voiceMediaCapabilityEvidence(for: contactID)?.peerDeviceID
                    ?? "unknown",
                "policy": policy.rawValue,
                "reason": reason,
            ].merging(opusPolicy.diagnosticsMetadata, uniquingKeysWith: { current, _ in current })
        )
    }
}
