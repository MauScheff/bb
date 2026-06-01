import Foundation
import UIKit

extension PTTViewModel {
    func submitShakeReport(
        incidentID: String,
        requestedAt: Date = .now,
        userReport: String = ""
    ) async throws -> ShakeReportResult {
        let selected = selectedContact
        let channelID = selected?.backendChannelId
        let metadata = shakeReportMetadata(
            incidentID: incidentID,
            requestedAt: requestedAt,
            selected: selected,
            channelID: channelID,
            userReport: userReport
        )

        diagnostics.record(
            .app,
            level: .notice,
            message: "Shake report requested",
            metadata: metadata
        )
        captureDiagnosticsState("shake-report")

        do {
            let result = try await publishDiagnosticsIfPossible(
                trigger: "shake-report:\(incidentID)",
                recordSuccess: true,
                preferredUploadMode: .compact
            )
            let response = result.response
            let diagnosticsLatestURL = latestDiagnosticsURL(
                baseURLString: response.report.backendBaseURL,
                deviceID: response.report.deviceId
            )
            var reportMetadata = metadata
            reportMetadata["deviceId"] = response.report.deviceId
            reportMetadata["uploadedAt"] = response.report.uploadedAt
            reportMetadata["uploadMode"] = result.uploadMode.rawValue
            if let fallbackError = result.fallbackFromFullError {
                reportMetadata["fallbackFromFullError"] = fallbackError
            }
            if let diagnosticsLatestURL {
                reportMetadata["diagnosticsLatestURL"] = diagnosticsLatestURL
            }

            sendTelemetryEvent(
                eventName: "ios.problem_report.shake",
                severity: .notice,
                reason: "shake-report",
                message: shakeReportTelemetryMessage(diagnosticsLatestURL: diagnosticsLatestURL),
                metadata: reportMetadata,
                alert: true,
                peerHandle: selected?.handle,
                channelId: channelID
            )

            return ShakeReportResult(
                incidentID: incidentID,
                deviceID: response.report.deviceId,
                uploadedAt: response.report.uploadedAt,
                diagnosticsLatestURL: diagnosticsLatestURL
            )
        } catch {
            diagnostics.record(
                .app,
                level: .error,
                message: "Shake report upload failed",
                metadata: metadata.merging(
                    ["error": error.localizedDescription],
                    uniquingKeysWith: { _, new in new }
                )
            )
            sendTelemetryEvent(
                eventName: "ios.problem_report.shake_upload_failed",
                severity: .error,
                reason: "shake-report",
                message: "Shake report upload failed",
                metadata: metadata.merging(
                    ["error": error.localizedDescription],
                    uniquingKeysWith: { _, new in new }
                ),
                alert: true,
                peerHandle: selected?.handle,
                channelId: channelID
            )
            throw error
        }
    }

    func handleHighSignalDiagnosticsEvent(_ event: DiagnosticsHighSignalEvent) {
        switch event {
        case .errorEntry(let entry):
            sendTelemetryEvent(
                eventName: "ios.error.\(entry.subsystem.rawValue)",
                severity: TurboTelemetrySeverity(diagnosticsLevel: entry.level),
                phase: diagnosticsStateFields["selectedConversationPhase"],
                reason: entry.subsystem.rawValue,
                message: entry.message,
                invariantID: entry.metadata["invariantID"],
                metadata: entry.metadata,
                alert: shouldAlertForDiagnosticsEntry(entry)
            )
        case .invariantViolation(let violation):
            sendTelemetryEvent(
                eventName: "ios.invariant.violation",
                severity: .error,
                phase: diagnosticsStateFields["selectedConversationPhase"],
                reason: violation.scope.rawValue,
                message: violation.message,
                invariantID: violation.invariantID,
                metadata: violation.metadata,
                alert: true
            )
        }
    }

    func sendTelemetryEvent(
        eventName: String,
        severity: TurboTelemetrySeverity = .info,
        phase: String? = nil,
        reason: String? = nil,
        message: String? = nil,
        invariantID: String? = nil,
        metadata: [String: String] = [:],
        alert: Bool = false,
        peerHandle: String? = nil,
        channelId: String? = nil
    ) {
        guard let backend = backendServices, backend.telemetryEnabled else { return }
        let payload = TurboTelemetryEventRequest(
            eventName: eventName,
            source: "ios",
            severity: severity.rawValue,
            userId: backend.currentUserID,
            userHandle: currentDevUserHandle,
            deviceId: backend.deviceID,
            sessionId: nil,
            channelId: channelId ?? selectedContact?.backendChannelId,
            peerUserId: selectedContact?.remoteUserId,
            peerHandle: peerHandle ?? selectedContact?.handle,
            appVersion: appVersionDescription,
            backendVersion: nil,
            invariantId: invariantID,
            phase: phase ?? diagnosticsStateFields["selectedConversationPhase"],
            reason: reason,
            message: message,
            metadata: baseTelemetryMetadata().merging(metadata, uniquingKeysWith: { _, new in new }),
            devTraffic: isDevTelemetryTraffic,
            alert: alert
        )

        Task { @MainActor [weak self] in
            do {
                _ = try await backend.uploadTelemetry(payload)
            } catch {
                self?.diagnostics.record(
                    .app,
                    level: .notice,
                    message: "Telemetry upload failed",
                    metadata: [
                        "eventName": eventName,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func flushPendingDirectQuicIdentityProvisioningFailureTelemetry(reason: String) {
        guard backendServices?.telemetryEnabled == true else {
            return
        }
        guard var metadata = pendingDirectQuicIdentityProvisioningFailureTelemetry else {
            return
        }
        metadata["flushReason"] = reason
        pendingDirectQuicIdentityProvisioningFailureTelemetry = nil
        sendTelemetryEvent(
            eventName: "ios.direct_quic.identity_provisioning_failed",
            severity: .error,
            reason: "direct-quic-identity",
            message: "Direct QUIC production identity provisioning failed",
            metadata: metadata,
            alert: true
        )
    }

    private func baseTelemetryMetadata() -> [String: String] {
        var metadata = [
            "applicationState": String(describing: currentApplicationState()),
            "backendMode": backendRuntime.mode,
            "isJoined": String(isJoined),
            "isTransmitting": String(isTransmitting),
            "selectedHandle": selectedContact?.handle ?? "none",
            "iosVersion": UIDevice.current.systemVersion,
            "deviceModel": UIDevice.current.model,
        ]
        for key in [
            "selectedConversationPhase",
            "selectedConversationPhaseDetail",
            "selectedConversationRelationship",
            "pendingAction",
            "activeChannelId",
            "systemSession",
            "transmitPhase",
            "backendChannelStatus",
            "backendReadiness",
            "backendSelfJoined",
            "backendPeerJoined",
            "backendPeerDeviceConnected",
            "backendCanTransmit",
            "backendActiveTransmitId",
            "backendServerTimestamp",
            "hadConnectedDevicePTTContinuity",
            "remoteAudioReadiness",
            "remoteWakeCapabilityKind",
            "directQuicAttemptId",
            "directQuicChannelId",
            "directQuicLocalDeviceId",
            "directQuicPeerDeviceId",
        ] {
            if let value = diagnosticsStateFields[key] {
                metadata[key] = value
            }
        }
        return metadata
    }

    private func shouldAlertForDiagnosticsEntry(_ entry: DiagnosticsEntry) -> Bool {
        switch entry.subsystem {
        case .selfCheck:
            return false
        default:
            return entry.level == .error
        }
    }

    private var isDevTelemetryTraffic: Bool {
#if DEBUG
        true
#else
        backendRuntime.mode != "cloud"
#endif
    }

    private func shakeReportMetadata(
        incidentID: String,
        requestedAt: Date,
        selected: Contact?,
        channelID: String?,
        userReport: String
    ) -> [String: String] {
        let traceWindowStart = requestedAt.addingTimeInterval(-300)
        var metadata = [
            "incidentId": incidentID,
            "requestedAt": iso8601String(requestedAt),
            "traceWindowStart": iso8601String(traceWindowStart),
            "traceWindowEnd": iso8601String(requestedAt),
            "traceWindowSeconds": "300",
            "selectedHandle": selected?.handle ?? "none",
            "selectedConversationPhase": diagnosticsStateFields["selectedConversationPhase"] ?? "unknown",
            "selectedConversationRelationship": diagnosticsStateFields["selectedConversationRelationship"] ?? "unknown",
            "channelId": channelID ?? "none",
            "isJoined": String(isJoined),
            "isTransmitting": String(isTransmitting),
            "backendMode": backendRuntime.mode,
            "telemetryEnabled": String(backendServices?.telemetryEnabled ?? false),
        ]
        let trimmedUserReport = trimmedReportText(userReport)
        if !trimmedUserReport.isEmpty {
            metadata["userReport"] = trimmedUserReport
        }
        return metadata
    }

    private func trimmedReportText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1000 else { return trimmed }
        return String(trimmed.prefix(1000))
    }

    private func shakeReportTelemetryMessage(diagnosticsLatestURL: String?) -> String {
        guard let diagnosticsLatestURL else {
            return "Shake report uploaded"
        }
        return "Shake report uploaded. Latest diagnostics: \(diagnosticsLatestURL)"
    }

    private func latestDiagnosticsURL(baseURLString: String, deviceID: String) -> String? {
        guard !baseURLString.isEmpty else { return nil }
        let trimmedBaseURL = baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let escapedDeviceID = deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceID
        return "\(trimmedBaseURL)/v1/dev/diagnostics/latest/\(escapedDeviceID)/"
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
