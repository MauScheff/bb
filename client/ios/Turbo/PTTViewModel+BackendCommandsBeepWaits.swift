//
//  PTTViewModel+BackendCommandsBeepWaits.swift
//  Turbo
//
//  Created by Codex on 13.05.2026.
//

import Foundation

extension PTTViewModel {
    func waitForAcceptedIncomingBeepToDisappear(
        _ acceptedBeep: TurboBeepResponse,
        request: BackendJoinRequest,
        backend: BackendServices
    ) async {
        for attempt in 1 ... 20 {
            do {
                let incomingBeeps = try await backend.incomingBeeps()
                let stillPending = incomingBeeps.contains { $0.beepId == acceptedBeep.beepId }
                if !stillPending {
                    diagnostics.record(
                        .backend,
                        message: "Incoming beep acceptance became visible",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                            "attempt": "\(attempt)",
                        ]
                    )
                    return
                }
            } catch {
                diagnostics.record(
                    .backend,
                    level: .error,
                    message: "Incoming beep acceptance visibility check failed",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                        "attempt": "\(attempt)",
                        "error": error.localizedDescription,
                    ]
                )
                return
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        diagnostics.record(
            .backend,
            message: "Incoming beep acceptance still pending after visibility wait",
            metadata: [
                "contactId": request.contactID.uuidString,
                "handle": request.handle,
                "beepId": acceptedBeep.beepId,
            ]
        )
    }

    func shouldIgnoreBeepNotFoundFailure(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "beep not found"
    }

    func shouldIgnoreIncomingBeepAcceptFailure(_ error: Error) -> Bool {
        shouldIgnoreBeepNotFoundFailure(error)
    }

    func waitForBeepToDisappear(
        beepID: String,
        contactID: UUID,
        handle: String,
        label: String,
        fetchBeeps: @escaping () async throws -> [TurboBeepResponse]
    ) async {
        for attempt in 1 ... 20 {
            do {
                let beeps = try await fetchBeeps()
                let stillPresent = beeps.contains { $0.beepId == beepID }
                if !stillPresent {
                    diagnostics.record(
                        .backend,
                        message: "\(label) became visible",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "handle": handle,
                            "attempt": "\(attempt)",
                            "beepId": beepID
                        ]
                    )
                    return
                }
            } catch {
                diagnostics.record(
                    .backend,
                    level: .error,
                    message: "\(label) visibility check failed",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "handle": handle,
                        "attempt": "\(attempt)",
                        "beepId": beepID,
                        "error": error.localizedDescription
                    ]
                )
                return
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        diagnostics.record(
            .backend,
            message: "\(label) still pending after visibility wait",
            metadata: [
                "contactId": contactID.uuidString,
                "handle": handle,
                "beepId": beepID
            ]
        )
    }

    func shouldTreatBackendJoinChannelNotFoundAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "channel not found"
    }

    func shouldTreatBackendJoinMetadataFailureAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "missing otheruserid or otherhandle"
    }

    func shouldTreatBackendJoinDisconnectedDeviceSessionAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "device session not connected"
    }

}
