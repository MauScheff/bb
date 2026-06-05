import Foundation
@preconcurrency import AVFAudio
import CryptoKit

nonisolated enum PlaybackBufferReceivePlan: Equatable {
    case deferUntilIOCycle
    case scheduleAndStartNode
    case scheduleOnly
}

nonisolated enum PlaybackCushionPolicy: Equatable {
    case applyTransportCushion
    case alreadyCushioned
}

nonisolated enum PlaybackStartWaitPlan: Equatable {
    case drainPendingBuffers
    case schedulePendingBuffersAndStartNode
    case waitForIOCycle
    case stopWaiting
}

nonisolated struct ReceivePlaybackFailureRecoveryPlan: Equatable {
    let failedChunkIndex: Int
    let recoveryRange: Range<Int>

    static func make(
        decodedChunkCount: Int,
        failedChunkIndex: Int
    ) -> ReceivePlaybackFailureRecoveryPlan? {
        guard decodedChunkCount > 0 else { return nil }
        guard failedChunkIndex >= 0, failedChunkIndex < decodedChunkCount else { return nil }
        return ReceivePlaybackFailureRecoveryPlan(
            failedChunkIndex: failedChunkIndex,
            recoveryRange: failedChunkIndex..<decodedChunkCount
        )
    }
}

nonisolated private struct PendingRemoteAudioChunk {
    let data: Data
    let playbackProfile: MediaSessionPlaybackProfile
    let cushionPolicy: PlaybackCushionPolicy
}

nonisolated private struct PendingRemoteAudioPayload {
    let payload: String
    let playbackProfile: MediaSessionPlaybackProfile
    let playbackDeadlineNanoseconds: UInt64?
}

nonisolated private struct DecodedCanonicalPCMChunk {
    let data: Data
    let playbackProfile: MediaSessionPlaybackProfile
    let cushionPolicy: PlaybackCushionPolicy
}

nonisolated private enum DeferredRemoteAudioPayloadValidation {
    case invalid
    case empty
    case playable
}

nonisolated private struct DecodedRemoteAudioPayload {
    let chunks: [DecodedCanonicalPCMChunk]
    let acceptedForPlayback: Bool
}

actor AudioChunkSender {
    private var sendChunk: (@Sendable (String) async throws -> Void)?
    private let reportFailure: @Sendable (String) async -> Void
    private let reportRecovery: (@Sendable () async -> Void)?
    private let reportEvent: (@Sendable (String, [String: String]) async -> Void)?
    // Keep sender-side live audio bounded; receiver-side wake buffering happens
    // after transport delivery, so stale outbound chunks are worse than drops.
    private var maximumPendingPayloads: Int
    private var maximumPayloadsPerMessage: Int
    private var payloadBatchCollectionNanoseconds: UInt64
    private var minimumPayloadDispatchSpacingNanoseconds: UInt64
    private var maximumInFlightSends: Int
    private var sendTimeoutNanoseconds: UInt64?
    private var slowSendDropThresholdNanoseconds: UInt64?
    private var dropsPendingPayloadsAfterSlowSend: Bool
    private var retainedNewestPayloadsAfterSlowSend: Int
    private var stopDrainTimeoutNanoseconds: UInt64?
    private let payloadBatchCollectionPollNanoseconds: UInt64 = 10_000_000
    private let transportAvailabilityPollNanoseconds: UInt64
    private let transportAvailabilityMaxAttempts: Int
    private var pendingPayloads: [String] = []
    private struct InFlightTransportSend {
        let id: UInt64
        let payload: String
        let pendingPayloadCount: Int
        let createdAt: UInt64
        var startedAt: UInt64?
    }
    private var nextInFlightSendID: UInt64 = 0
    private var inFlightSends: [UInt64: InFlightTransportSend] = [:]
    private var inFlightSendTasks: [UInt64: Task<Void, Never>] = [:]
    private var lastPayloadDispatchNanoseconds: UInt64?
    private var isDraining = false
    private var flushPendingImmediately = false
    private var outboundTransportDispatchReportBudget = 64
    private var outboundTransportSuccessReportBudget = 64
    private var outboundTransportDropReportBudget = 16
    private var outboundTransportSlowSendReportBudget = 16
    private var outboundTransportTaskStartReportBudget = 16
    private var transportFailureReported = false
    private static let slowTransportSendThresholdNanoseconds: UInt64 = 250_000_000
    private static let slowTransportTaskStartThresholdNanoseconds: UInt64 = 40_000_000

    init(
        sendChunk: (@Sendable (String) async throws -> Void)?,
        reportFailure: @escaping @Sendable (String) async -> Void,
        reportRecovery: (@Sendable () async -> Void)? = nil,
        reportEvent: (@Sendable (String, [String: String]) async -> Void)? = nil,
        configuration: MediaTransportSenderConfiguration = .websocketContinuity,
        maximumPendingPayloads: Int? = nil,
        maximumPayloadsPerMessage: Int? = nil,
        payloadBatchCollectionNanoseconds: UInt64? = nil,
        minimumPayloadDispatchSpacingNanoseconds: UInt64? = nil,
        maximumInFlightSends: Int? = nil,
        sendTimeoutNanoseconds: UInt64? = nil,
        dropsPendingPayloadsAfterSlowSend: Bool? = nil,
        transportAvailabilityPollNanoseconds: UInt64 = 50_000_000,
        transportAvailabilityMaxAttempts: Int = 80
    ) {
        self.sendChunk = sendChunk
        self.reportFailure = reportFailure
        self.reportRecovery = reportRecovery
        self.reportEvent = reportEvent
        self.maximumPendingPayloads = 0
        self.maximumPayloadsPerMessage = 1
        self.payloadBatchCollectionNanoseconds = 0
        self.minimumPayloadDispatchSpacingNanoseconds = 0
        self.maximumInFlightSends = 1
        self.sendTimeoutNanoseconds = nil
        self.slowSendDropThresholdNanoseconds = nil
        self.dropsPendingPayloadsAfterSlowSend = false
        self.retainedNewestPayloadsAfterSlowSend = 0
        self.stopDrainTimeoutNanoseconds = nil
        self.transportAvailabilityPollNanoseconds = transportAvailabilityPollNanoseconds
        self.transportAvailabilityMaxAttempts = transportAvailabilityMaxAttempts
        let resolvedConfiguration = Self.resolvedConfiguration(
            configuration,
            maximumPendingPayloads: maximumPendingPayloads,
            maximumPayloadsPerMessage: maximumPayloadsPerMessage,
            payloadBatchCollectionNanoseconds: payloadBatchCollectionNanoseconds,
            minimumPayloadDispatchSpacingNanoseconds: minimumPayloadDispatchSpacingNanoseconds,
            maximumInFlightSends: maximumInFlightSends,
            sendTimeoutNanoseconds: sendTimeoutNanoseconds,
            dropsPendingPayloadsAfterSlowSend: dropsPendingPayloadsAfterSlowSend
        )
        self.maximumPendingPayloads = resolvedConfiguration.maximumPendingPayloads
        self.maximumPayloadsPerMessage = resolvedConfiguration.maximumPayloadsPerMessage
        self.payloadBatchCollectionNanoseconds = resolvedConfiguration.payloadBatchCollectionNanoseconds
        self.minimumPayloadDispatchSpacingNanoseconds =
            resolvedConfiguration.minimumPayloadDispatchSpacingNanoseconds
        self.maximumInFlightSends = resolvedConfiguration.maximumInFlightSends
        self.sendTimeoutNanoseconds = resolvedConfiguration.sendTimeoutNanoseconds
        self.slowSendDropThresholdNanoseconds = resolvedConfiguration.slowSendDropThresholdNanoseconds
        self.dropsPendingPayloadsAfterSlowSend = resolvedConfiguration.dropsPendingPayloadsAfterSlowSend
        self.retainedNewestPayloadsAfterSlowSend = resolvedConfiguration.retainedNewestPayloadsAfterSlowSend
        self.stopDrainTimeoutNanoseconds = resolvedConfiguration.stopDrainTimeoutNanoseconds
    }

    func updateSendChunk(_ handler: (@Sendable (String) async throws -> Void)?) {
        sendChunk = handler
    }

    func updateConfiguration(_ configuration: MediaTransportSenderConfiguration) {
        applyConfiguration(configuration)
    }

    func enqueue(_ payload: String) async {
        await enqueue([payload])
    }

    func enqueue(_ payloads: [String]) async {
        guard !payloads.isEmpty else { return }
        pendingPayloads.append(contentsOf: payloads)
        if pendingPayloads.count > maximumPendingPayloads {
            let droppedPayloadCount = pendingPayloads.count - maximumPendingPayloads
            pendingPayloads.removeFirst(droppedPayloadCount)
            reportTransportDropIfNeeded(
                droppedPayloadCount: droppedPayloadCount,
                pendingPayloadCount: pendingPayloads.count
            )
        }
        guard !isDraining else { return }
        isDraining = true
        await drain()
    }

    func reset() {
        pendingPayloads.removeAll(keepingCapacity: false)
        cancelAllInFlightSendTasks()
        nextInFlightSendID = 0
        inFlightSends.removeAll(keepingCapacity: false)
        inFlightSendTasks.removeAll(keepingCapacity: false)
        lastPayloadDispatchNanoseconds = nil
        isDraining = false
        flushPendingImmediately = false
        transportFailureReported = false
        resetReportingBudgets()
    }

    func resetReportingBudgets() {
        outboundTransportDispatchReportBudget = 64
        outboundTransportSuccessReportBudget = 64
        outboundTransportDropReportBudget = 16
        outboundTransportSlowSendReportBudget = 16
        outboundTransportTaskStartReportBudget = 16
    }

    private func applyConfiguration(
        _ configuration: MediaTransportSenderConfiguration,
        maximumPendingPayloads: Int? = nil,
        maximumPayloadsPerMessage: Int? = nil,
        payloadBatchCollectionNanoseconds: UInt64? = nil,
        minimumPayloadDispatchSpacingNanoseconds: UInt64? = nil,
        maximumInFlightSends: Int? = nil,
        sendTimeoutNanoseconds: UInt64? = nil,
        dropsPendingPayloadsAfterSlowSend: Bool? = nil
    ) {
        let resolvedConfiguration = Self.resolvedConfiguration(
            configuration,
            maximumPendingPayloads: maximumPendingPayloads,
            maximumPayloadsPerMessage: maximumPayloadsPerMessage,
            payloadBatchCollectionNanoseconds: payloadBatchCollectionNanoseconds,
            minimumPayloadDispatchSpacingNanoseconds: minimumPayloadDispatchSpacingNanoseconds,
            maximumInFlightSends: maximumInFlightSends,
            sendTimeoutNanoseconds: sendTimeoutNanoseconds,
            dropsPendingPayloadsAfterSlowSend: dropsPendingPayloadsAfterSlowSend
        )
        self.maximumPendingPayloads = resolvedConfiguration.maximumPendingPayloads
        self.maximumPayloadsPerMessage = resolvedConfiguration.maximumPayloadsPerMessage
        self.payloadBatchCollectionNanoseconds = resolvedConfiguration.payloadBatchCollectionNanoseconds
        self.minimumPayloadDispatchSpacingNanoseconds =
            resolvedConfiguration.minimumPayloadDispatchSpacingNanoseconds
        self.maximumInFlightSends = resolvedConfiguration.maximumInFlightSends
        self.sendTimeoutNanoseconds = resolvedConfiguration.sendTimeoutNanoseconds
        self.slowSendDropThresholdNanoseconds = resolvedConfiguration.slowSendDropThresholdNanoseconds
        self.dropsPendingPayloadsAfterSlowSend = resolvedConfiguration.dropsPendingPayloadsAfterSlowSend
        self.retainedNewestPayloadsAfterSlowSend = resolvedConfiguration.retainedNewestPayloadsAfterSlowSend
        self.stopDrainTimeoutNanoseconds = resolvedConfiguration.stopDrainTimeoutNanoseconds
        trimPendingPayloadsToCurrentConfigurationIfNeeded()
        if self.maximumPayloadsPerMessage <= 1 {
            flushPendingImmediately = true
        }
    }

    nonisolated private static func resolvedConfiguration(
        _ configuration: MediaTransportSenderConfiguration,
        maximumPendingPayloads: Int? = nil,
        maximumPayloadsPerMessage: Int? = nil,
        payloadBatchCollectionNanoseconds: UInt64? = nil,
        minimumPayloadDispatchSpacingNanoseconds: UInt64? = nil,
        maximumInFlightSends: Int? = nil,
        sendTimeoutNanoseconds: UInt64? = nil,
        dropsPendingPayloadsAfterSlowSend: Bool? = nil
    ) -> MediaTransportSenderConfiguration {
        let effectiveDropsPendingPayloadsAfterSlowSend =
            dropsPendingPayloadsAfterSlowSend ?? configuration.dropsPendingPayloadsAfterSlowSend
        return MediaTransportSenderConfiguration(
            maximumPendingPayloads: maximumPendingPayloads ?? configuration.maximumPendingPayloads,
            maximumPayloadsPerMessage: max(
                1,
                maximumPayloadsPerMessage ?? configuration.maximumPayloadsPerMessage
            ),
            payloadBatchCollectionNanoseconds:
                payloadBatchCollectionNanoseconds ?? configuration.payloadBatchCollectionNanoseconds,
            minimumPayloadDispatchSpacingNanoseconds:
                minimumPayloadDispatchSpacingNanoseconds
                    ?? configuration.minimumPayloadDispatchSpacingNanoseconds,
            maximumInFlightSends: max(1, maximumInFlightSends ?? configuration.maximumInFlightSends),
            sendTimeoutNanoseconds: sendTimeoutNanoseconds ?? configuration.sendTimeoutNanoseconds,
            slowSendDropThresholdNanoseconds:
                configuration.slowSendDropThresholdNanoseconds
                    ?? (effectiveDropsPendingPayloadsAfterSlowSend
                        ? Self.slowTransportSendThresholdNanoseconds
                        : nil),
            dropsPendingPayloadsAfterSlowSend: effectiveDropsPendingPayloadsAfterSlowSend,
            retainedNewestPayloadsAfterSlowSend: max(
                0,
                configuration.retainedNewestPayloadsAfterSlowSend
            ),
            stopDrainTimeoutNanoseconds: configuration.stopDrainTimeoutNanoseconds
        )
    }

    private func trimPendingPayloadsToCurrentConfigurationIfNeeded() {
        guard pendingPayloads.count > maximumPendingPayloads else { return }
        let droppedPayloadCount = pendingPayloads.count - maximumPendingPayloads
        pendingPayloads.removeFirst(droppedPayloadCount)
        reportTransportDropIfNeeded(
            droppedPayloadCount: droppedPayloadCount,
            pendingPayloadCount: pendingPayloads.count,
            invariantID: "media.outbound_audio_transport_policy_update_drop",
            reason: "outbound-transport-policy-update"
        )
    }

    @discardableResult
    func finishDraining(
        pollNanoseconds: UInt64 = 10_000_000,
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        flushPendingImmediately = true
        let startedAt = DispatchTime.now().uptimeNanoseconds
        while isDraining || !pendingPayloads.isEmpty {
            if let timeoutNanoseconds {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= startedAt && now - startedAt >= timeoutNanoseconds {
                    dropPendingPayloadsAfterStopDrainTimeout(
                        elapsedNanoseconds: now - startedAt
                    )
                    return false
                }
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return true
    }

    private func drain() async {
        while !pendingPayloads.isEmpty || !inFlightSends.isEmpty {
            guard !pendingPayloads.isEmpty else {
                await waitForInFlightSendProgress()
                continue
            }
            await waitForInFlightSendCapacity()
            guard !pendingPayloads.isEmpty else { continue }
            let payload = await nextTransportPayload()
            guard let sendChunk = await waitForTransportIfNeeded() else {
                if dropPendingPayloadAfterUnavailableTransportIfPolicyAllows() {
                    break
                } else {
                    transportFailureReported = true
                    await reportFailure("audio send failed: audio transport is not configured")
                    pendingPayloads.removeAll(keepingCapacity: false)
                    break
                }
            }
            let pendingPayloadCount = pendingPayloads.count
            await waitForPayloadDispatchSpacingIfNeeded(
                pendingPayloadCount: pendingPayloadCount
            )
            let sendCreatedAt = DispatchTime.now().uptimeNanoseconds
            lastPayloadDispatchNanoseconds = sendCreatedAt
            reportTransportDispatchIfNeeded(
                payload: payload,
                pendingPayloadCount: pendingPayloadCount
            )
            let sendID = nextInFlightSendID
            nextInFlightSendID += 1
            inFlightSends[sendID] = InFlightTransportSend(
                id: sendID,
                payload: payload,
                pendingPayloadCount: pendingPayloadCount,
                createdAt: sendCreatedAt,
                startedAt: nil
            )
            let sendTask = Task.detached(priority: .userInitiated) { [sendChunk] in
                let sendStartedAt = DispatchTime.now().uptimeNanoseconds
                await self.markTransportSendStarted(
                    sendID: sendID,
                    startedAt: sendStartedAt
                )
                let result: Result<Void, Error>
                do {
                    try Task.checkCancellation()
                    try await sendChunk(payload)
                    try Task.checkCancellation()
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                await self.completeTransportSend(
                    sendID: sendID,
                    payload: payload,
                    pendingPayloadCount: pendingPayloadCount,
                    sendStartedAt: sendStartedAt,
                    result: result
                )
            }
            inFlightSendTasks[sendID] = sendTask
        }
        isDraining = false
    }

    private func markTransportSendStarted(
        sendID: UInt64,
        startedAt: UInt64
    ) {
        guard var inFlightSend = inFlightSends[sendID] else { return }
        inFlightSend.startedAt = startedAt
        inFlightSends[sendID] = inFlightSend
        guard startedAt >= inFlightSend.createdAt else { return }
        let startDelayNanoseconds = startedAt - inFlightSend.createdAt
        reportSlowTransportTaskStartIfNeeded(
            payload: inFlightSend.payload,
            pendingPayloadCount: inFlightSend.pendingPayloadCount,
            elapsedNanoseconds: startDelayNanoseconds
        )
    }

    private func completeTransportSend(
        sendID: UInt64,
        payload: String,
        pendingPayloadCount: Int,
        sendStartedAt: UInt64,
        result: Result<Void, Error>
    ) async {
        inFlightSendTasks.removeValue(forKey: sendID)
        guard let inFlightSend = inFlightSends.removeValue(forKey: sendID) else { return }
        let effectiveSendStartedAt = inFlightSend.startedAt ?? sendStartedAt
        switch result {
        case .success:
            let sendElapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - effectiveSendStartedAt
            let sendWasSlow = sendElapsedNanoseconds >= Self.slowTransportSendThresholdNanoseconds
            reportSlowTransportSendIfNeeded(
                payload: payload,
                pendingPayloadCount: pendingPayloadCount,
                elapsedNanoseconds: sendElapsedNanoseconds
            )
            if sendWasSlow {
                dropPendingPayloadsAfterSlowTransportSendIfPolicyAllows(
                    elapsedNanoseconds: sendElapsedNanoseconds
                )
            }
            await reportRecoveryIfNeeded()
            reportTransportSendSucceededIfNeeded(
                payload: payload,
                pendingPayloadCount: pendingPayloadCount
            )
        case .failure(let error):
            if error is CancellationError {
                pendingPayloads.removeAll(keepingCapacity: false)
                cancelAllInFlightSendTasks()
                inFlightSends.removeAll(keepingCapacity: false)
                inFlightSendTasks.removeAll(keepingCapacity: false)
                flushPendingImmediately = false
                return
            }
            transportFailureReported = true
            await reportFailure("audio send failed: \(error.localizedDescription)")
            pendingPayloads.removeAll(keepingCapacity: false)
        }
    }

    private func waitForPayloadDispatchSpacingIfNeeded(
        pendingPayloadCount: Int
    ) async {
        let delayNanoseconds = Self.dispatchSpacingDelayNanoseconds(
            minimumPayloadDispatchSpacingNanoseconds: minimumPayloadDispatchSpacingNanoseconds,
            pendingPayloadCount: pendingPayloadCount,
            lastPayloadDispatchNanoseconds: lastPayloadDispatchNanoseconds,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        guard delayNanoseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: delayNanoseconds)
    }

    nonisolated static func dispatchSpacingDelayNanoseconds(
        minimumPayloadDispatchSpacingNanoseconds: UInt64,
        pendingPayloadCount: Int,
        lastPayloadDispatchNanoseconds: UInt64?,
        nowNanoseconds: UInt64
    ) -> UInt64 {
        // Capture callbacks deliver small frame bursts; those frames are already
        // capture-paced, so waiting between them makes live send fall behind.
        guard minimumPayloadDispatchSpacingNanoseconds > 0,
              pendingPayloadCount == 0,
              let lastPayloadDispatchNanoseconds else {
            return 0
        }
        guard nowNanoseconds >= lastPayloadDispatchNanoseconds else { return 0 }
        let elapsedNanoseconds = nowNanoseconds - lastPayloadDispatchNanoseconds
        guard elapsedNanoseconds < minimumPayloadDispatchSpacingNanoseconds else { return 0 }
        return minimumPayloadDispatchSpacingNanoseconds - elapsedNanoseconds
    }

    private func waitForInFlightSendCapacity() async {
        while inFlightSends.count >= maximumInFlightSends {
            await waitForInFlightSendProgress()
        }
    }

    private func waitForInFlightSendProgress() async {
        expireTimedOutInFlightSendsIfNeeded()
        guard !inFlightSends.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }

    private func expireTimedOutInFlightSendsIfNeeded() {
        guard let sendTimeoutNanoseconds else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let timedOutSendIDs = inFlightSends.compactMap { entry -> UInt64? in
            let (sendID, inFlightSend) = entry
            guard let startedAt = inFlightSend.startedAt else { return nil }
            return now >= startedAt && now - startedAt >= sendTimeoutNanoseconds
                ? sendID
                : nil
        }
        guard !timedOutSendIDs.isEmpty else { return }
        for sendID in timedOutSendIDs {
            guard let timedOutSend = inFlightSends.removeValue(forKey: sendID) else { continue }
            inFlightSendTasks.removeValue(forKey: sendID)?.cancel()
            let startedAt = timedOutSend.startedAt ?? now
            let elapsedNanoseconds = now >= startedAt ? now - startedAt : 0
            reportSlowTransportSendIfNeeded(
                payload: timedOutSend.payload,
                pendingPayloadCount: timedOutSend.pendingPayloadCount,
                elapsedNanoseconds: elapsedNanoseconds
            )
            dropPendingPayloadsAfterSlowTransportSendIfPolicyAllows(
                elapsedNanoseconds: elapsedNanoseconds
            )
        }
    }

    private func reportSlowTransportTaskStartIfNeeded(
        payload: String,
        pendingPayloadCount: Int,
        elapsedNanoseconds: UInt64
    ) {
        guard elapsedNanoseconds >= Self.slowTransportTaskStartThresholdNanoseconds,
              outboundTransportTaskStartReportBudget > 0 else {
            return
        }
        outboundTransportTaskStartReportBudget -= 1
        guard let reportEvent else { return }
        let metadata = [
            "elapsedMilliseconds": String(elapsedNanoseconds / 1_000_000),
            "payloadLength": String(payload.count),
            "pendingPayloadCount": String(pendingPayloadCount),
            "transportDigest": AudioChunkPayloadCodec.transportDigest(payload),
        ]
        Task {
            await reportEvent("Outbound audio transport send task started late", metadata)
        }
    }

    private func nextTransportPayload() async -> String {
        await waitForBatchCollectionIfNeeded()

        let batchCount = min(maximumPayloadsPerMessage, pendingPayloads.count)
        let batch = Array(pendingPayloads.prefix(batchCount))
        pendingPayloads.removeFirst(batchCount)
        if pendingPayloads.isEmpty {
            flushPendingImmediately = false
        }
        return AudioChunkPayloadCodec.encode(batch)
    }

    private func reportRecoveryIfNeeded() async {
        guard transportFailureReported else { return }
        transportFailureReported = false
        await reportRecovery?()
    }

    private func waitForBatchCollectionIfNeeded() async {
        var waitedNanoseconds: UInt64 = 0
        while Self.shouldWaitForMorePayloads(
            pendingPayloadCount: pendingPayloads.count,
            maximumPayloadsPerMessage: maximumPayloadsPerMessage,
            flushRequested: flushPendingImmediately
        ), waitedNanoseconds < payloadBatchCollectionNanoseconds {
            let remainingNanoseconds = payloadBatchCollectionNanoseconds - waitedNanoseconds
            let sleepNanoseconds = min(payloadBatchCollectionPollNanoseconds, remainingNanoseconds)
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            waitedNanoseconds += sleepNanoseconds
        }
    }

    nonisolated static func shouldWaitForMorePayloads(
        pendingPayloadCount: Int,
        maximumPayloadsPerMessage: Int,
        flushRequested: Bool = false
    ) -> Bool {
        guard !flushRequested else { return false }
        return pendingPayloadCount > 0 && pendingPayloadCount < maximumPayloadsPerMessage
    }

    private func waitForTransportIfNeeded() async -> (@Sendable (String) async throws -> Void)? {
        if let sendChunk {
            return sendChunk
        }

        for _ in 0 ..< transportAvailabilityMaxAttempts {
            try? await Task.sleep(nanoseconds: transportAvailabilityPollNanoseconds)
            if let sendChunk {
                return sendChunk
            }
        }

        return nil
    }

    private func reportTransportDispatchIfNeeded(
        payload: String,
        pendingPayloadCount: Int
    ) {
        guard outboundTransportDispatchReportBudget > 0 else { return }
        outboundTransportDispatchReportBudget -= 1
        guard let reportEvent else { return }
        let metadata = [
            "payloadLength": String(payload.count),
            "pendingPayloadCount": String(pendingPayloadCount),
            "transportDigest": AudioChunkPayloadCodec.transportDigest(payload),
            "decodedChunkCount": String(AudioChunkPayloadCodec.decode(payload).count),
        ]
        Task {
            await reportEvent("Dispatching outbound audio transport payload", metadata)
        }
    }

    private func reportTransportSendSucceededIfNeeded(
        payload: String,
        pendingPayloadCount: Int
    ) {
        guard outboundTransportSuccessReportBudget > 0 else { return }
        outboundTransportSuccessReportBudget -= 1
        guard let reportEvent else { return }
        let metadata = [
            "payloadLength": String(payload.count),
            "pendingPayloadCount": String(pendingPayloadCount),
            "transportDigest": AudioChunkPayloadCodec.transportDigest(payload),
            "decodedChunkCount": String(AudioChunkPayloadCodec.decode(payload).count),
        ]
        Task {
            await reportEvent("Delivered outbound audio transport payload", metadata)
        }
    }

    private func reportTransportDropIfNeeded(
        droppedPayloadCount: Int,
        pendingPayloadCount: Int,
        invariantID: String = "media.outbound_audio_transport_backpressure_drop",
        reason: String = "outbound-transport-backpressure",
        additionalMetadata: [String: String] = [:]
    ) {
        guard outboundTransportDropReportBudget > 0 else { return }
        outboundTransportDropReportBudget -= 1
        guard let reportEvent else { return }
        var metadata = [
            "contractKind": DiagnosticsContractKind.liveness.rawValue,
            "droppedPayloadCount": String(droppedPayloadCount),
            "invariantID": invariantID,
            "pendingPayloadCount": String(pendingPayloadCount),
            "maximumPendingPayloads": String(maximumPendingPayloads),
            "reason": reason,
            "scope": DiagnosticsInvariantScope.local.rawValue,
        ]
        metadata.merge(additionalMetadata) { _, new in new }
        Task {
            await reportEvent("Dropped stale outbound audio transport payload", metadata)
        }
    }

    private func dropPendingPayloadsAfterSlowTransportSendIfPolicyAllows(
        elapsedNanoseconds: UInt64
    ) {
        guard dropsPendingPayloadsAfterSlowSend else { return }
        guard let slowSendDropThresholdNanoseconds,
              elapsedNanoseconds >= slowSendDropThresholdNanoseconds else { return }
        let retainedPayloadCount = min(retainedNewestPayloadsAfterSlowSend, pendingPayloads.count)
        let droppedPayloadCount = pendingPayloads.count - retainedPayloadCount
        guard droppedPayloadCount > 0 else { return }
        pendingPayloads.removeFirst(droppedPayloadCount)
        reportTransportDropIfNeeded(
            droppedPayloadCount: droppedPayloadCount,
            pendingPayloadCount: pendingPayloads.count,
            invariantID: "media.outbound_audio_transport_slow_send_drop",
            reason: "outbound-transport-slow-send",
            additionalMetadata: [
                "elapsedMilliseconds": String(elapsedNanoseconds / 1_000_000),
                "retainedPayloadCount": String(retainedPayloadCount),
            ]
        )
    }

    private func dropPendingPayloadAfterUnavailableTransportIfPolicyAllows() -> Bool {
        guard dropsPendingPayloadsAfterSlowSend else { return false }
        let droppedPayloadCount = 1 + pendingPayloads.count
        pendingPayloads.removeAll(keepingCapacity: false)
        reportTransportDropIfNeeded(
            droppedPayloadCount: droppedPayloadCount,
            pendingPayloadCount: pendingPayloads.count,
            invariantID: "media.outbound_audio_transport_unavailable_drop",
            reason: "outbound-transport-unavailable"
        )
        return true
    }

    private func dropPendingPayloadsAfterStopDrainTimeout(
        elapsedNanoseconds: UInt64
    ) {
        let droppedPayloadCount = pendingPayloads.count
        let cancelledInFlightSendCount = inFlightSends.count
        guard droppedPayloadCount > 0 || cancelledInFlightSendCount > 0 else { return }
        pendingPayloads.removeAll(keepingCapacity: false)
        cancelAllInFlightSendTasks()
        inFlightSends.removeAll(keepingCapacity: false)
        inFlightSendTasks.removeAll(keepingCapacity: false)
        isDraining = false
        flushPendingImmediately = false
        guard droppedPayloadCount > 0 else {
            reportTransportStopDrainTimeoutIfNeeded(
                cancelledInFlightSendCount: cancelledInFlightSendCount,
                elapsedNanoseconds: elapsedNanoseconds
            )
            return
        }
        reportTransportDropIfNeeded(
            droppedPayloadCount: droppedPayloadCount,
            pendingPayloadCount: pendingPayloads.count,
            invariantID: "media.outbound_audio_transport_slow_send_drop",
            reason: "outbound-transport-stop-drain-timeout",
            additionalMetadata: [
                "cancelledInFlightSendCount": String(cancelledInFlightSendCount),
                "elapsedMilliseconds": String(elapsedNanoseconds / 1_000_000),
            ]
        )
    }

    private func reportTransportStopDrainTimeoutIfNeeded(
        cancelledInFlightSendCount: Int,
        elapsedNanoseconds: UInt64
    ) {
        guard outboundTransportDropReportBudget > 0 else { return }
        outboundTransportDropReportBudget -= 1
        guard let reportEvent else { return }
        let metadata = [
            "cancelledInFlightSendCount": String(cancelledInFlightSendCount),
            "elapsedMilliseconds": String(elapsedNanoseconds / 1_000_000),
            "pendingPayloadCount": String(pendingPayloads.count),
            "maximumPendingPayloads": String(maximumPendingPayloads),
            "reason": "outbound-transport-stop-drain-timeout",
        ]
        Task {
            await reportEvent("Outbound audio transport stop drain timed out", metadata)
        }
    }

    private func cancelAllInFlightSendTasks() {
        let sendIDs = Array(inFlightSendTasks.keys)
        for sendID in sendIDs {
            inFlightSendTasks.removeValue(forKey: sendID)?.cancel()
        }
    }

    private func reportSlowTransportSendIfNeeded(
        payload: String,
        pendingPayloadCount: Int,
        elapsedNanoseconds: UInt64
    ) {
        guard elapsedNanoseconds >= Self.slowTransportSendThresholdNanoseconds else { return }
        guard outboundTransportSlowSendReportBudget > 0 else { return }
        outboundTransportSlowSendReportBudget -= 1
        guard let reportEvent else { return }
        let exceedsDestructiveDropThreshold =
            dropsPendingPayloadsAfterSlowSend
            && slowSendDropThresholdNanoseconds.map { elapsedNanoseconds >= $0 } == true
        var metadata = [
            "diagnosticLevel": DiagnosticsLevel.notice.rawValue,
            "elapsedMilliseconds": String(elapsedNanoseconds / 1_000_000),
            "invariantID": "media.outbound_audio_transport_send_slow",
            "payloadLength": String(payload.count),
            "pendingPayloadCount": String(pendingPayloadCount),
            "reason": dropsPendingPayloadsAfterSlowSend
                ? "packet-lane-slow-send"
                : "ordered-fallback-slow-send",
            "transportDigest": AudioChunkPayloadCodec.transportDigest(payload),
        ]
        if exceedsDestructiveDropThreshold {
            metadata["contractKind"] = DiagnosticsContractKind.liveness.rawValue
            metadata["scope"] = DiagnosticsInvariantScope.local.rawValue
        }
        Task {
            await reportEvent("Outbound audio transport send was slow", metadata)
        }
    }
}

nonisolated struct CaptureRouteRefreshPlan: Equatable {
    let shouldStopEngine: Bool
    let shouldResetEngine: Bool
    let shouldRemoveInputTap: Bool
    let shouldRestartEngine: Bool

    static func forLiveTransmitRoute(
        engineIsRunning: Bool,
        inputTapInstalled: Bool
    ) -> CaptureRouteRefreshPlan {
        CaptureRouteRefreshPlan(
            shouldStopEngine: engineIsRunning,
            shouldResetEngine: engineIsRunning,
            shouldRemoveInputTap: inputTapInstalled,
            shouldRestartEngine: engineIsRunning || !engineIsRunning
        )
    }
}

nonisolated struct CaptureTransmitStartPlan: Equatable {
    let shouldRefreshRoute: Bool

    static func forCurrentCapturePath(
        isCaptureReady: Bool,
        engineIsRunning: Bool,
        inputTapInstalled: Bool,
        hasCaptureConverter: Bool
    ) -> CaptureTransmitStartPlan {
        CaptureTransmitStartPlan(
            shouldRefreshRoute: !isCaptureReady || !engineIsRunning || !inputTapInstalled || !hasCaptureConverter
        )
    }
}

enum AudioChunkPayloadCodec {
    nonisolated static func encode(_ chunks: [String]) -> String {
        guard chunks.count > 1 else {
            return chunks.first ?? ""
        }

        let envelope: [String: Any] = [
            "kind": "pcm-batch-v1",
            "chunks": chunks,
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let string = String(data: data, encoding: .utf8) else {
            return chunks.first ?? ""
        }
        return string
    }

    nonisolated static func decode(_ payload: String) -> [String] {
        guard payload.first == "{",
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String,
              kind == "pcm-batch-v1",
              let chunks = object["chunks"] as? [String],
              !chunks.isEmpty else {
            return [payload]
        }

        return chunks
    }

    nonisolated static func transportDigest(_ payload: String, prefixBytes: Int = 6) -> String {
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.prefix(prefixBytes).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum PCMOutgoingPayloadSplitter {
    static let targetSampleRate: UInt64 = 16_000
    static let bytesPerInt16Sample = MemoryLayout<Int16>.size
    static let maximumFramesPerPacketMediaPayload = 267

    static func encodePayloads(fromInt16PCMData data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        let maximumBytesPerPayload = maximumFramesPerPacketMediaPayload * bytesPerInt16Sample
        guard data.count > maximumBytesPerPayload else {
            return [data.base64EncodedString()]
        }

        var payloads: [String] = []
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + maximumBytesPerPayload)
            payloads.append(data.subdata(in: offset ..< end).base64EncodedString())
            offset = end
        }
        return payloads
    }

    static func durationNanoseconds(forEncodedPayload payload: String) -> UInt64? {
        var frameCount = 0
        var opusDurationNanoseconds: UInt64 = 0
        for chunk in AudioChunkPayloadCodec.decode(payload) {
            if let opusFrame = VoiceAudioFramePayloadCodec.decode(chunk) {
                opusDurationNanoseconds += UInt64(opusFrame.frameDurationMilliseconds) * 1_000_000
                continue
            }
            guard let data = Data(base64Encoded: chunk) else { return nil }
            if (try? VoicePacketV1Codec.decode(data)) != nil {
                opusDurationNanoseconds += UInt64(VoiceFrameAccumulator.frameDurationMilliseconds) * 1_000_000
                continue
            }
            frameCount += data.count / bytesPerInt16Sample
        }
        if opusDurationNanoseconds > 0 {
            return opusDurationNanoseconds
        }
        guard frameCount > 0 else { return nil }
        return UInt64(frameCount) * 1_000_000_000 / targetSampleRate
    }
}

nonisolated struct PCMLevelMetrics: Equatable {
    let sampleCount: Int
    let nonZeroSampleCount: Int
    let peak: Double
    let rms: Double

    var isSilent: Bool {
        nonZeroSampleCount == 0 || peak == 0
    }

    var diagnosticMetadata: [String: String] {
        [
            "pcmSampleCount": String(sampleCount),
            "pcmNonZeroSamples": String(nonZeroSampleCount),
            "pcmPeak": Self.formatLevel(peak),
            "pcmRMS": Self.formatLevel(rms),
            "pcmSilent": String(isSilent),
        ]
    }

    nonisolated static func forBuffer(_ buffer: AVAudioPCMBuffer) -> PCMLevelMetrics? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        switch buffer.format.commonFormat {
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else { return nil }
            return collect(
                frameCount: frameCount,
                channelCount: channelCount,
                isInterleaved: buffer.format.isInterleaved
            ) { sampleIndex, channelIndex in
                let sample: Int16
                if buffer.format.isInterleaved {
                    sample = channelData.pointee[sampleIndex * channelCount + channelIndex]
                } else {
                    sample = channelData[channelIndex][sampleIndex]
                }
                return Double(Int(sample)) / 32768.0
            }
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else { return nil }
            return collect(
                frameCount: frameCount,
                channelCount: channelCount,
                isInterleaved: buffer.format.isInterleaved
            ) { sampleIndex, channelIndex in
                if buffer.format.isInterleaved {
                    return Double(channelData.pointee[sampleIndex * channelCount + channelIndex])
                } else {
                    return Double(channelData[channelIndex][sampleIndex])
                }
            }
        default:
            return nil
        }
    }

    nonisolated static func forInt16PCMData(_ data: Data) -> PCMLevelMetrics? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
                return nil
            }
            return collect(sampleCount: sampleCount) { sampleIndex in
                Double(Int(baseAddress[sampleIndex])) / 32768.0
            }
        }
    }

    private nonisolated static func collect(
        frameCount: Int,
        channelCount: Int,
        isInterleaved _: Bool,
        sampleAt: (Int, Int) -> Double
    ) -> PCMLevelMetrics {
        collect(sampleCount: frameCount * channelCount) { sampleIndex in
            let frameIndex = sampleIndex / channelCount
            let channelIndex = sampleIndex % channelCount
            return sampleAt(frameIndex, channelIndex)
        }
    }

    private nonisolated static func collect(
        sampleCount: Int,
        sampleAt: (Int) -> Double
    ) -> PCMLevelMetrics {
        var nonZeroSampleCount = 0
        var peak = 0.0
        var squareSum = 0.0

        for sampleIndex in 0 ..< sampleCount {
            let sample = sampleAt(sampleIndex)
            let magnitude = abs(sample)
            if magnitude > 0 {
                nonZeroSampleCount += 1
            }
            peak = max(peak, magnitude)
            squareSum += sample * sample
        }

        return PCMLevelMetrics(
            sampleCount: sampleCount,
            nonZeroSampleCount: nonZeroSampleCount,
            peak: peak,
            rms: sqrt(squareSum / Double(sampleCount))
        )
    }

    private nonisolated static func formatLevel(_ level: Double) -> String {
        String(format: "%.6f", level)
    }
}

nonisolated enum CaptureSendState: Equatable {
    case idle
    case sending
    case stopping(graceDeadlineNanoseconds: UInt64)

    static func shouldAcceptCapturedBuffer(
        _ state: CaptureSendState,
        nowNanoseconds: UInt64
    ) -> Bool {
        switch state {
        case .idle:
            return false
        case .sending:
            return true
        case .stopping:
            return false
        }
    }
}

nonisolated(unsafe) final class PCMWebSocketMediaSession: MediaSession, @unchecked Sendable {
    static let playbackCompletionCallbackType: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack

    weak var delegate: MediaSessionDelegate?

    private var stateStorage: MediaConnectionState = .idle
    nonisolated(unsafe) var state: MediaConnectionState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateStorage
    }

    private let reportEvent: (@Sendable (String, [String: String]) async -> Void)?
    private let senderConfigurationLock = NSLock()
    private var senderConfiguration: MediaTransportSenderConfiguration
    private lazy var audioChunkSender =
        AudioChunkSender(
            sendChunk: initialSendAudioChunk,
            reportFailure: { [weak self] (message: String) in
                guard let self else { return }
                await MainActor.run {
                    self.setState(.failed(message))
                }
            },
            reportRecovery: { [weak self] in
                guard let self else { return }
                let didRecover = await MainActor.run { () -> Bool in
                    guard case .failed = self.state else { return false }
                    self.setState(.connected)
                    return true
                }
                if didRecover {
                    await self.report(
                        "Recovered audio transport after successful send",
                        metadata: [:]
                    )
                }
            },
            reportEvent: { [weak self] (message: String, metadata: [String: String]) in
                guard let self else { return }
                await self.report(message, metadata: metadata)
            },
            configuration: senderConfigurationSnapshot()
        )
    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let captureProcessingQueue = DispatchQueue(
        label: "Turbo.PCMWebSocketMediaSession.capture-processing",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private let receivePlaybackLock = NSLock()
    private let mediaEncodingLock = NSLock()
    private let targetFormat: AVAudioFormat
    private var captureConverter: AVAudioConverter?
    private var playbackConverter: AVAudioConverter?
    private var outboundFrameAccumulator = VoiceFrameAccumulator()
    private var outboundVoiceMediaPolicy: VoiceMediaPayloadFormat
    private var outboundOpusEncodingPolicy: OpusVoiceEncodingPolicy
    private let opusCodec: OpusVoiceCodec?
    private let voiceMediaCoreMode: VoiceMediaCoreMode
    private var playoutEngine: VoicePlayoutEngine
    private var isPlaybackReady = false
    private var isCaptureReady = false
    private var captureSendState: CaptureSendState = .idle
    private var captureSendCancellationGeneration: UInt64 = 0
    private var inputTapInstalled = false
    private var pendingPlaybackBuffers: [AVAudioPCMBuffer] = []
    private var pendingRemoteAudioPayloads: [PendingRemoteAudioPayload] = []
    private var pendingRemoteAudioChunks: [PendingRemoteAudioChunk] = []
    private var scheduledPlaybackBufferCount = 0
    private var remoteAudioReceiveEpoch: UInt64 = 0
    private var opusPlayoutReportBudget = 8
    private var opusPlayoutInvariantBudget = 4
    private var playbackStartTask: Task<Void, Never>?
    private var playbackCushionTask: Task<Void, Never>?
    private var playbackNodeStartupReassertionTask: Task<Void, Never>?
    private var playbackRecoveryTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private let maximumPendingPlaybackBuffers = 24
    private let maximumPendingRemoteAudioChunks = 24
    private var playbackBufferReportBudget = 8
    private var playbackLockBusyReportBudget = 3
    private let initialSendAudioChunk: (@Sendable (String) async throws -> Void)?
    private var currentSendAudioChunk: (@Sendable (String) async throws -> Void)?
    private var capturedBufferReportBudget = 3
    private var convertedBufferReportBudget = 3
    private var enqueuedPayloadReportBudget = 3
    private var activeAudioSessionOwnership: MediaSessionActivationMode?
    private let captureStopGraceNanoseconds: UInt64 = 120_000_000
    private var lastLocalAudioLevelReportNanoseconds: UInt64 = 0
    private let localAudioLevelReportIntervalNanoseconds: UInt64 = 66_000_000

    init(
        sendAudioChunk: (@Sendable (String) async throws -> Void)?,
        reportEvent: (@Sendable (String, [String: String]) async -> Void)? = nil,
        senderConfiguration: MediaTransportSenderConfiguration = .websocketContinuity,
        outboundVoiceMediaPolicy: VoiceMediaPayloadFormat = .legacyPCM,
        outboundOpusEncodingPolicy: OpusVoiceEncodingPolicy = .reliableFallback,
        voiceMediaCoreMode: VoiceMediaCoreMode = TurboVoiceMediaCoreDebugOverride.liveMode()
    ) {
        self.initialSendAudioChunk = sendAudioChunk
        self.currentSendAudioChunk = sendAudioChunk
        self.reportEvent = reportEvent
        self.senderConfiguration = senderConfiguration
        self.outboundVoiceMediaPolicy = outboundVoiceMediaPolicy
        self.outboundOpusEncodingPolicy = outboundOpusEncodingPolicy
        self.voiceMediaCoreMode = voiceMediaCoreMode
        self.playoutEngine = VoicePlayoutEngineFactory.make(mode: voiceMediaCoreMode)
        self.opusCodec = try? OpusVoiceCodec(
            encodingPolicy: outboundOpusEncodingPolicy
        )
        self.targetFormat =
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(VoiceFrameAccumulator.sampleRate),
                channels: 1,
                interleaved: true
            )!
        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: targetFormat)
    }

    private nonisolated func setState(_ newState: MediaConnectionState) {
        stateLock.lock()
        let oldState = stateStorage
        stateStorage = newState
        stateLock.unlock()
        guard oldState != newState else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.mediaSession(self, didChange: newState)
        }
    }

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?) {
        currentSendAudioChunk = handler
        Task {
            await audioChunkSender.updateSendChunk(handler)
        }
        Task {
            await report(
                "Updated media session audio transport",
                metadata: ["configured": String(handler != nil)]
            )
        }
    }

    func updateSenderConfiguration(_ configuration: MediaTransportSenderConfiguration) {
        let previousConfiguration = senderConfigurationSnapshot()
        setSenderConfiguration(configuration)
        Task {
            await audioChunkSender.updateConfiguration(configuration)
        }
        guard previousConfiguration != configuration else { return }
        Task {
            await report(
                "Updated media session sender configuration",
                metadata: [
                    "maximumPayloadsPerMessage": String(configuration.maximumPayloadsPerMessage),
                    "maximumInFlightSends": String(configuration.maximumInFlightSends),
                    "minimumDispatchSpacingMs": String(
                        configuration.minimumPayloadDispatchSpacingNanoseconds / 1_000_000
                    ),
                    "sendTimeoutMs": configuration.sendTimeoutNanoseconds
                        .map { String($0 / 1_000_000) } ?? "none",
                    "dropsPendingPayloadsAfterSlowSend": String(configuration.dropsPendingPayloadsAfterSlowSend),
                ]
            )
        }
    }

    func resetOutgoingAudioTransport(reason: String) async {
        await audioChunkSender.reset()
        await report(
            "Reset outgoing audio transport",
            metadata: ["reason": reason]
        )
    }

    func updateOutboundVoiceMediaPolicy(_ policy: VoiceMediaPayloadFormat) {
        mediaEncodingLock.lock()
        let previousPolicy = outboundVoiceMediaPolicy
        outboundVoiceMediaPolicy = policy
        if previousPolicy != policy {
            outboundFrameAccumulator.reset()
        }
        mediaEncodingLock.unlock()

        guard previousPolicy != policy else { return }
        Task {
            await report(
                "Updated outbound voice media policy",
                metadata: [
                    "previousPolicy": previousPolicy.rawValue,
                    "policy": policy.rawValue,
                    "opusAvailable": String(opusCodec != nil),
                ]
            )
        }
    }

    func updateOutboundOpusEncodingPolicy(_ policy: OpusVoiceEncodingPolicy) {
        mediaEncodingLock.lock()
        let previousPolicy = outboundOpusEncodingPolicy
        let codec = opusCodec
        mediaEncodingLock.unlock()

        guard previousPolicy != policy else { return }
        do {
            try codec?.updateEncodingPolicy(policy)
            mediaEncodingLock.lock()
            outboundOpusEncodingPolicy = policy
            mediaEncodingLock.unlock()
            Task {
                await report(
                    "Updated outbound Opus encoding policy",
                    metadata: policy.diagnosticsMetadata
                )
            }
        } catch {
            Task {
                await report(
                    "Failed to update outbound Opus encoding policy",
                    metadata: policy.diagnosticsMetadata.merging(
                        ["error": error.localizedDescription],
                        uniquingKeysWith: { current, _ in current }
                    )
                )
            }
        }
    }

    func start(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode
    ) async throws {
        if let existingStartTask = startTask {
            try await existingStartTask.value
        }

        let requiresCapture = startupMode == .interactive
        let playbackAlreadyReady = isPlaybackReady
        let captureAlreadyReady = isCaptureReady
        guard !playbackAlreadyReady || (requiresCapture && !captureAlreadyReady) else { return }

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.performStart(
                activationMode: activationMode,
                startupMode: startupMode,
                playbackAlreadyReady: playbackAlreadyReady,
                captureAlreadyReady: captureAlreadyReady
            )
        }
        startTask = task

        defer {
            startTask = nil
        }

        try await task.value
    }

    private func performStart(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode,
        playbackAlreadyReady: Bool,
        captureAlreadyReady: Bool
    ) async throws {
        await report(
            "Media session start requested",
            metadata: [
                "activationMode": String(describing: activationMode),
                "startupMode": String(describing: startupMode),
                "playbackReady": String(playbackAlreadyReady),
                "captureReady": String(captureAlreadyReady)
            ]
        )
        setState(.preparing)
        try configureAudioSession(
            activationMode: activationMode,
            startupMode: startupMode
        )
        try preparePlaybackPathIfNeeded()
        try startPlaybackEngineIfNeeded()
        primeSystemActivatedPlaybackNodeIfNeeded(
            activationMode: activationMode,
            startupMode: startupMode,
            playbackAlreadyReady: playbackAlreadyReady
        )
        try withReceivePlaybackLock {
            isPlaybackReady = true
            try drainPendingRemoteAudioIfReady()
        }

        let requiresCapture = startupMode == .interactive
        if requiresCapture {
            try prepareCapturePathIfNeeded()
            try installInputTapIfNeeded()
            try startCaptureEngineIfNeeded()
            isCaptureReady = true
        }

        setState(.connected)
        await report(
            "Media session start completed",
            metadata: [
                "activationMode": String(describing: activationMode),
                "startupMode": String(describing: startupMode),
                "captureReady": String(isCaptureReady),
                "playbackReady": String(isPlaybackReady)
            ]
        )
    }

    private nonisolated func withReceivePlaybackLock<T>(_ body: () throws -> T) rethrows -> T {
        receivePlaybackLock.lock()
        defer { receivePlaybackLock.unlock() }
        return try body()
    }

    private nonisolated func tryWithReceivePlaybackLock<T>(_ body: () throws -> T) rethrows -> T? {
        guard receivePlaybackLock.try() else { return nil }
        defer { receivePlaybackLock.unlock() }
        return try body()
    }

#if DEBUG
    func lockReceivePlaybackForTesting() {
        receivePlaybackLock.lock()
    }

    func unlockReceivePlaybackForTesting() {
        receivePlaybackLock.unlock()
    }

    func markAudioCaptureReadyAndSendingForTesting() {
        withReceivePlaybackLock {
            isPlaybackReady = true
        }
        isCaptureReady = true
        setSendingAudio(true)
    }
#endif

    private nonisolated func senderConfigurationSnapshot() -> MediaTransportSenderConfiguration {
        senderConfigurationLock.lock()
        defer { senderConfigurationLock.unlock() }
        return senderConfiguration
    }

    private nonisolated func setSenderConfiguration(
        _ configuration: MediaTransportSenderConfiguration
    ) {
        senderConfigurationLock.lock()
        senderConfiguration = configuration
        senderConfigurationLock.unlock()
    }

    func startSendingAudio() async throws {
        let cancellationGeneration = currentCaptureSendCancellationGeneration()
        if !isPlaybackReady || !isCaptureReady {
            try await start(activationMode: .appManaged, startupMode: .interactive)
        }
        resetCaptureReportingBudgets()
        await audioChunkSender.updateConfiguration(senderConfigurationSnapshot())
        await audioChunkSender.updateSendChunk(currentSendAudioChunk)
        if isSendingAudio() {
            await report(
                "Joined existing audio capture media epoch",
                metadata: ["reason": "already-sending"]
            )
            return
        }
        let captureStartPlan = CaptureTransmitStartPlan.forCurrentCapturePath(
            isCaptureReady: isCaptureReady,
            engineIsRunning: captureEngine.isRunning,
            inputTapInstalled: inputTapInstalled,
            hasCaptureConverter: captureConverter != nil
        )
        if captureStartPlan.shouldRefreshRoute {
            try refreshCapturePathForCurrentRoute()
        }
        await report(
            "Starting audio capture with transport state",
            metadata: ["configured": String(currentSendAudioChunk != nil)]
        )
        guard shouldEnableSendingAudio(
            expectedCancellationGeneration: cancellationGeneration
        ) else {
            await audioChunkSender.reset()
            await report(
                "Skipped enabling audio capture because transmit start was cancelled",
                metadata: ["reason": "stale-transmit-startup"]
            )
            return
        }
        await audioChunkSender.resetReportingBudgets()
        resetPlaybackForTransmit()
        resetOutboundFrameAccumulator()
        setSendingAudio(true)
    }

    func stopSendingAudio() async throws {
        let stopGraceDeadline = beginCaptureStopGraceIfNeeded()
        if let stopGraceDeadline {
            try? await Task.sleep(nanoseconds: captureStopGraceNanoseconds)
            finishCaptureStopGraceIfNeeded(expectedDeadlineNanoseconds: stopGraceDeadline)
        }
        await audioChunkSender.finishDraining(
            timeoutNanoseconds: senderConfigurationSnapshot().stopDrainTimeoutNanoseconds
        )
    }

    func abortSendingAudio() async {
        cancelCaptureSendState()
        await audioChunkSender.reset()
        await report(
            "Aborted audio capture without draining",
            metadata: ["reason": "stale-transmit-startup"]
        )
    }

    func beginRemoteAudioReceiveEpoch() {
        withReceivePlaybackLock {
            remoteAudioReceiveEpoch &+= 1
            playbackStartTask?.cancel()
            playbackStartTask = nil
            playbackCushionTask?.cancel()
            playbackCushionTask = nil
            playbackNodeStartupReassertionTask?.cancel()
            playbackNodeStartupReassertionTask = nil
            pendingPlaybackBuffers.removeAll(keepingCapacity: false)
            pendingRemoteAudioPayloads.removeAll(keepingCapacity: false)
            pendingRemoteAudioChunks.removeAll(keepingCapacity: false)
            resetScheduledPlaybackBufferCount()
            playoutEngine.reset(
                epoch: VoiceReceiveEpochID(rawValue: remoteAudioReceiveEpoch),
                nowNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            resetOpusPlayoutReportBudgets()
            resetPlaybackBufferReportBudget()
            resetPlaybackLockBusyReportBudget()
            playerNode.stop()
            playerNode.reset()
        }
        Task {
            await report("Reset receive playout for remote audio epoch", metadata: [:])
        }
    }

    nonisolated func currentRemoteAudioReceiveEpoch() -> UInt64 {
        withReceivePlaybackLock { remoteAudioReceiveEpoch }
    }

    @discardableResult
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile: MediaSessionPlaybackProfile
    ) async -> Bool {
        await receiveRemoteAudioChunk(
            payload,
            playbackProfile: playbackProfile,
            expectedReceiveEpoch: nil
        )
    }

    @discardableResult
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile: MediaSessionPlaybackProfile,
        expectedReceiveEpoch: UInt64?
    ) async -> Bool {
        await receiveRemoteAudioChunk(
            payload,
            playbackProfile: playbackProfile,
            expectedReceiveEpoch: expectedReceiveEpoch,
            playbackDeadlineNanoseconds: nil
        )
    }

    @discardableResult
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile: MediaSessionPlaybackProfile,
        expectedReceiveEpoch: UInt64?,
        playbackDeadlineNanoseconds: UInt64?
    ) async -> Bool {
        var decodedPayload = true
        var queuedPendingPayloadCount: Int?
        var queuedPendingChunkCount: Int?
        var playbackFailure: String?
        var recoveryQueuedChunkCount: Int?
        var shouldAttemptPlaybackRecovery = false
        var acceptedForPlayback = false
        do {
            try withReceivePlaybackLock {
                if let expectedReceiveEpoch,
                   expectedReceiveEpoch != remoteAudioReceiveEpoch {
                    return
                }
                if let playbackDeadlineNanoseconds,
                   DispatchTime.now().uptimeNanoseconds >= playbackDeadlineNanoseconds {
                    return
                }
                if !isPlaybackReady {
                    switch validateRemoteAudioPayloadForDeferredDecode(
                        payload,
                        playbackProfile: playbackProfile
                    ) {
                    case .invalid:
                        decodedPayload = false
                    case .empty:
                        acceptedForPlayback = false
                    case .playable:
                        enqueuePendingRemoteAudioPayload(
                            PendingRemoteAudioPayload(
                                payload: payload,
                                playbackProfile: playbackProfile,
                                playbackDeadlineNanoseconds: playbackDeadlineNanoseconds
                            )
                        )
                        queuedPendingPayloadCount = pendingRemoteAudioPayloadCount()
                        acceptedForPlayback = true
                    }
                    return
                }
                guard let decodedResult = decodedCanonicalPCMChunks(
                    from: payload,
                    playbackProfile: playbackProfile
                ) else {
                    decodedPayload = false
                    return
                }

                let decodedChunks = decodedResult.chunks
                guard !decodedChunks.isEmpty else {
                    acceptedForPlayback = decodedResult.acceptedForPlayback
                    return
                }
                if !isPlaybackReady {
                    for chunk in decodedChunks {
                        enqueuePendingRemoteAudioChunk(chunk)
                    }
                    queuedPendingChunkCount = pendingRemoteAudioChunkCount()
                    acceptedForPlayback = true
                } else {
                    for (index, chunk) in decodedChunks.enumerated() {
                        do {
                            try schedulePlayback(
                                for: chunk.data,
                                playbackProfile: chunk.playbackProfile,
                                cushionPolicy: chunk.cushionPolicy
                            )
                        } catch {
                            if let recoveryPlan = ReceivePlaybackFailureRecoveryPlan.make(
                                decodedChunkCount: decodedChunks.count,
                                failedChunkIndex: index
                            ) {
                                for recoveryChunk in decodedChunks[recoveryPlan.recoveryRange] {
                                    enqueuePendingRemoteAudioChunk(
                                        recoveryChunk
                                    )
                                }
                                queuedPendingChunkCount = pendingRemoteAudioChunkCount()
                                recoveryQueuedChunkCount = recoveryPlan.recoveryRange.count
                            }
                            resetPlaybackPathForReceiveRecovery()
                            shouldAttemptPlaybackRecovery = true
                            throw error
                        }
                    }
                    acceptedForPlayback = true
                }
            }
        } catch {
            playbackFailure = error.localizedDescription
            acceptedForPlayback = false
        }

        guard decodedPayload else {
            setState(.failed("received invalid audio chunk"))
            return false
        }

        if let recoveryQueuedChunkCount,
           let queuedPendingChunkCount {
            await report(
                "Queued remote audio chunk for playback recovery",
                metadata: [
                    "recoveryChunkCount": String(recoveryQueuedChunkCount),
                    "pendingChunkCount": String(queuedPendingChunkCount),
                ]
            )
        } else if let queuedPendingPayloadCount {
            await report(
                "Queued remote audio payload until playback ready",
                metadata: ["pendingPayloadCount": String(queuedPendingPayloadCount)]
            )
        } else if let queuedPendingChunkCount {
            await report(
                "Queued remote audio chunk until playback ready",
                metadata: ["pendingChunkCount": String(queuedPendingChunkCount)]
            )
        }
        if let playbackFailure {
            if shouldAttemptPlaybackRecovery {
                await report(
                    "Recovering receive playback after failure",
                    metadata: ["error": playbackFailure]
                )
                await MainActor.run {
                    startReceivePlaybackRecoveryIfNeeded()
                }
            } else {
                setState(.failed("playback failed: \(playbackFailure)"))
                await report(
                    "Receive playback failed",
                    metadata: ["error": playbackFailure]
                )
            }
        }
        return acceptedForPlayback
    }

    private nonisolated func validateRemoteAudioPayloadForDeferredDecode(
        _ payload: String,
        playbackProfile _: MediaSessionPlaybackProfile
    ) -> DeferredRemoteAudioPayloadValidation {
        guard let frames = VoiceAudioFramePayloadCodec.decodeTransportFrames(payload) else {
            return .invalid
        }
        var hasPlayableFrame = false
        for frame in frames {
            switch frame {
            case .legacyPCM(let data):
                if !data.isEmpty {
                    hasPlayableFrame = true
                }
            case .opus(let opusFrame):
                guard opusCodec != nil else {
                    reportCodecNegotiationMismatch(
                        frame: opusFrame,
                        reason: "opus-codec-unavailable"
                    )
                    return .invalid
                }
                hasPlayableFrame = true
            case .binaryOpusV1(let packet):
                guard opusCodec != nil else {
                    reportCodecNegotiationMismatch(
                        frame: packet.opusFramePayload,
                        reason: "opus-codec-unavailable"
                    )
                    return .invalid
                }
                hasPlayableFrame = true
            }
        }
        return hasPlayableFrame ? .playable : .empty
    }

    private nonisolated func voicePacket(from opusFrame: VoiceOpusFramePayload) throws -> VoicePacketV1 {
        var flags: UInt16 = 0
        if opusFrame.features.contains(VoiceMediaCapabilities.fecFeature) {
            flags |= VoicePacketV1Codec.Flag.inBandFEC.rawValue
        }
        return try VoicePacketV1(
            frameIndex: opusFrame.frameIndex,
            flags: flags,
            opusPayload: opusFrame.packet
        )
    }

    private nonisolated func decodedCanonicalPCMChunks(
        from payload: String,
        playbackProfile: MediaSessionPlaybackProfile
    ) -> DecodedRemoteAudioPayload? {
        guard let frames = VoiceAudioFramePayloadCodec.decodeTransportFrames(payload) else {
            return nil
        }

        var chunks: [DecodedCanonicalPCMChunk] = []
        var acceptedForPlayback = false
        chunks.reserveCapacity(frames.count)
        for frame in frames {
            switch frame {
            case .legacyPCM(let data):
                guard !data.isEmpty else { continue }
                acceptedForPlayback = true
                chunks.append(
                    DecodedCanonicalPCMChunk(
                        data: PCMInt16SampleRateConverter.convert(
                            data,
                            fromSampleRate: Int(PCMOutgoingPayloadSplitter.targetSampleRate),
                            toSampleRate: VoiceFrameAccumulator.sampleRate
                        ),
                        playbackProfile: playbackProfile,
                        cushionPolicy: .applyTransportCushion
                    )
                )
            case .opus(let opusFrame):
                guard let opusCodec else {
                    reportCodecNegotiationMismatch(
                        frame: opusFrame,
                        reason: "opus-codec-unavailable"
                    )
                    return nil
                }
                do {
                    let packet = try voicePacket(from: opusFrame)
                    let result = try playoutEngine.insert(
                        packet: packet,
                        epoch: VoiceReceiveEpochID(rawValue: remoteAudioReceiveEpoch),
                        playbackProfile: playbackProfile,
                        decode: { frame in try opusCodec.decode(frame.packet) },
                        decodeFEC: { frame in try opusCodec.decodeFEC(from: frame.packet) },
                        plc: { opusCodec.decodePLC() },
                        nowNanoseconds: DispatchTime.now().uptimeNanoseconds
                    )
                    reportOpusPlayoutResultIfNeeded(
                        result,
                        frame: opusFrame,
                        playbackProfile: playbackProfile
                    )
                    if result.duplicateDropCount == 0 && result.lateDropCount == 0 {
                        acceptedForPlayback = true
                    }
                    chunks.append(
                        contentsOf: result.framesToPlay.map {
                            DecodedCanonicalPCMChunk(
                                data: $0.pcmData,
                                playbackProfile: playbackProfile,
                                cushionPolicy: .alreadyCushioned
                            )
                        }
                    )
                } catch {
                    Task {
                        await report(
                            "Opus decode failed",
                            metadata: [
                                "codec": "opus",
                                "frameIndex": String(opusFrame.frameIndex),
                                "packetSizeBytes": String(opusFrame.packet.count),
                                "error": error.localizedDescription,
                            ]
                        )
                    }
                    return nil
                }
            case .binaryOpusV1(let packet):
                let opusFrame = packet.opusFramePayload
                guard let opusCodec else {
                    reportCodecNegotiationMismatch(
                        frame: opusFrame,
                        reason: "opus-codec-unavailable"
                    )
                    continue
                }
                do {
                    let result = try playoutEngine.insert(
                        packet: packet,
                        epoch: VoiceReceiveEpochID(rawValue: remoteAudioReceiveEpoch),
                        playbackProfile: playbackProfile,
                        decode: { frame in try opusCodec.decode(frame.packet) },
                        decodeFEC: { frame in try opusCodec.decodeFEC(from: frame.packet) },
                        plc: { opusCodec.decodePLC() },
                        nowNanoseconds: DispatchTime.now().uptimeNanoseconds
                    )
                    reportOpusPlayoutResultIfNeeded(
                        result,
                        frame: opusFrame,
                        playbackProfile: playbackProfile
                    )
                    if result.duplicateDropCount == 0 && result.lateDropCount == 0 {
                        acceptedForPlayback = true
                    }
                    chunks.append(
                        contentsOf: result.framesToPlay.map { frame in
                            DecodedCanonicalPCMChunk(
                                data: frame.pcmData,
                                playbackProfile: playbackProfile,
                                cushionPolicy: .alreadyCushioned
                            )
                        }
                    )
                } catch {
                    reportCodecNegotiationMismatch(
                        frame: opusFrame,
                        reason: "binary-opus-v1-decode-failed"
                    )
                }
            }
        }
        return DecodedRemoteAudioPayload(
            chunks: chunks,
            acceptedForPlayback: acceptedForPlayback || !chunks.isEmpty
        )
    }

    private func reportCodecNegotiationMismatch(
        frame: VoiceOpusFramePayload,
        reason: String
    ) {
        Task {
            await report(
                "Codec negotiation mismatch for incoming audio",
                metadata: [
                    "contractKind": DiagnosticsContractKind.precondition.rawValue,
                    "invariantID": "media.codec_negotiation_mismatch",
                    "scope": DiagnosticsInvariantScope.local.rawValue,
                    "reason": reason,
                    "codec": "opus",
                    "frameIndex": String(frame.frameIndex),
                    "sampleRate": String(frame.sampleRate),
                    "frameDurationMs": String(frame.frameDurationMilliseconds),
                ]
            )
        }
    }

    private func reportOpusPlayoutResultIfNeeded(
        _ result: VoicePlayoutInsertResult,
        frame: VoiceOpusFramePayload,
        playbackProfile: MediaSessionPlaybackProfile
    ) {
        let shouldReport =
            result.missingFrameCount > 0
            || result.duplicateDropCount > 0
            || result.lateDropCount > 0
            || result.adaptiveCushionIncreased
            || TurboAudioDiagnosticsDebugOverride.isPacketMetadataEnabled()
        guard shouldReport else { return }
        guard opusPlayoutReportBudget > 0 else { return }
        opusPlayoutReportBudget -= 1

        var metadata = [
            "codec": "opus",
            "voiceMediaCoreMode": voiceMediaCoreMode.rawValue,
            "frameIndex": String(frame.frameIndex),
            "packetSizeBytes": String(frame.packet.count),
            "playbackProfile": String(describing: playbackProfile),
            "bufferDepthFrames": String(result.bufferDepthFrames),
            "targetCushionFrames": String(result.targetCushionFrames),
            "scheduledFrameCount": String(result.framesToPlay.count),
            "missingFrameCount": String(result.missingFrameCount),
            "plcRecoveryCount": String(result.plcRecoveryCount),
            "fecRecoveryCount": String(result.fecRecoveryCount),
            "resynchronizedGapFrameCount": String(result.resynchronizedGapFrameCount),
            "duplicateDropCount": String(result.duplicateDropCount),
            "lateDropCount": String(result.lateDropCount),
            "largestScheduledGapFrames": String(result.largestScheduledGapFrames),
            "adaptiveCushionIncreased": String(result.adaptiveCushionIncreased),
        ]
        let metrics = playoutEngine.metrics()
        metadata["playoutPhase"] = String(describing: metrics.phase)
        metadata["playoutAcceptedPacketCount"] = String(metrics.acceptedPacketCount)
        metadata["playoutDuplicatePacketCount"] = String(metrics.duplicatePacketCount)
        metadata["playoutLatePacketCount"] = String(metrics.latePacketCount)
        metadata["playoutShadowDivergenceCount"] = String(metrics.shadowDivergenceCount)
        var invariantID: String?
        if let interArrivalGapNanoseconds = result.interArrivalGapNanoseconds {
            metadata["interArrivalGapMs"] = String(interArrivalGapNanoseconds / 1_000_000)
            if interArrivalGapNanoseconds > excessiveJitterThresholdNanoseconds(for: playbackProfile) {
                invariantID = "media.playout_excessive_jitter"
            }
        }
        if result.missingFrameCount >= 2 || result.adaptiveCushionIncreased {
            invariantID = "media.playout_repeated_underrun"
        }
        if result.resynchronizedGapFrameCount > 0 {
            invariantID = "media.playout_large_gap_resync"
        }
        if let invariantID,
           opusPlayoutInvariantBudget > 0 {
            metadata["contractKind"] = DiagnosticsContractKind.liveness.rawValue
            metadata["invariantID"] = invariantID
            metadata["scope"] = DiagnosticsInvariantScope.local.rawValue
            opusPlayoutInvariantBudget -= 1
        }
        Task {
            await report(
                "Opus playout buffer updated",
                metadata: metadata
            )
        }
    }

    private func excessiveJitterThresholdNanoseconds(
        for playbackProfile: MediaSessionPlaybackProfile
    ) -> UInt64 {
        switch playbackProfile {
        case .lowLatency:
            return 120_000_000
        case .fastRelayBalanced:
            return 160_000_000
        case .relayJitterBuffered:
            return 240_000_000
        case .wakeBackgroundContinuity:
            return 360_000_000
        }
    }

    func audioRouteDidChange(allowCaptureRefresh: Bool) async {
        guard isPlaybackReady || isCaptureReady else { return }
        do {
            playbackConverter = nil
            if isPlaybackReady {
                try preparePlaybackPathIfNeeded()
                try startPlaybackEngineIfNeeded()
                reassertPlaybackNodeAfterRouteChangeIfNeeded()
            }
            if allowCaptureRefresh, isCaptureReady {
                try refreshCapturePathForCurrentRoute()
            }
            await report(
                "Media session refreshed for audio route change",
                metadata: audioSessionMetadata(AVAudioSession.sharedInstance()).merging(
                    [
                        "allowCaptureRefresh": String(allowCaptureRefresh),
                        "captureReady": String(isCaptureReady),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
        } catch {
            await report(
                "Media session audio route refresh failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func hasPendingPlayback() -> Bool {
        if let pendingPlayback = tryWithReceivePlaybackLock({
            !pendingRemoteAudioPayloads.isEmpty
                || !pendingRemoteAudioChunks.isEmpty
                || !pendingPlaybackBuffers.isEmpty
                || scheduledPlaybackBufferCountSnapshot() > 0
        }) {
            return pendingPlayback
        }
        if consumePlaybackLockBusyReportBudget() {
            Task {
                await report(
                    "Receive playback lock busy while checking pending playback",
                    metadata: ["action": "assume-pending"]
                )
            }
        }
        return true
    }

    func close(deactivateAudioSession: Bool) {
        stateLock.lock()
        noteCaptureSendCancellationLocked()
        captureSendState = .idle
        stateLock.unlock()
        Task {
            await audioChunkSender.reset()
        }
        startTask?.cancel()
        startTask = nil
        playbackStartTask?.cancel()
        playbackStartTask = nil
        playbackCushionTask?.cancel()
        playbackCushionTask = nil
        playbackNodeStartupReassertionTask?.cancel()
        playbackNodeStartupReassertionTask = nil
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        pendingPlaybackBuffers.removeAll(keepingCapacity: false)
        pendingRemoteAudioChunks.removeAll(keepingCapacity: false)
        resetOutboundFrameAccumulator()
        playoutEngine = VoicePlayoutEngineFactory.make(mode: voiceMediaCoreMode)
        resetOpusPlayoutReportBudgets()
        resetPlaybackBufferReportBudget()
        resetPlaybackLockBusyReportBudget()
        resetScheduledPlaybackBufferCount()

        if inputTapInstalled {
            captureEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        playerNode.stop()
        playerNode.reset()
        captureEngine.stop()
        playbackEngine.stop()
        captureConverter = nil
        playbackConverter = nil
        isPlaybackReady = false
        isCaptureReady = false
        deactivateAudioSessionIfNeeded(deactivateAudioSession: deactivateAudioSession)
        setState(.closed)
    }

    private func deactivateAudioSessionIfNeeded(deactivateAudioSession: Bool) {
        guard activeAudioSessionOwnership == .appManaged else {
            activeAudioSessionOwnership = nil
            return
        }
        activeAudioSessionOwnership = nil
        guard deactivateAudioSession else {
            Task {
                await report(
                    "Preserved active audio session during media close",
                    metadata: [:]
                )
            }
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            Task {
                await report(
                    "Audio session deactivated for media close",
                    metadata: audioSessionMetadata(session)
                )
            }
        } catch {
            Task {
                await report(
                    "Failed to deactivate audio session for media close",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func configureAudioSession(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode
    ) throws {
        let session = AVAudioSession.sharedInstance()
        let policy = MediaSessionAudioPolicy.configuration(
            activationMode: activationMode,
            startupMode: startupMode
        )
        guard policy.shouldConfigureSession else {
            activeAudioSessionOwnership = nil
            Task {
                await report(
                    "Preserved system-managed audio session policy",
                    metadata: audioSessionMetadata(session).merging(
                        [
                            "activationMode": String(describing: activationMode),
                            "startupMode": String(describing: startupMode),
                        ],
                        uniquingKeysWith: { _, new in new }
                    )
                )
            }
            return
        }
        try session.setCategory(
            policy.category,
            mode: policy.mode,
            options: policy.options
        )
        try session.setPreferredSampleRate(targetFormat.sampleRate)
        try session.setPreferredIOBufferDuration(0.02)
        if policy.shouldActivateSession {
            try session.setActive(true)
        }
        activeAudioSessionOwnership = policy.shouldActivateSession ? activationMode : nil
        Task {
            await report(
                "Audio session configured",
                metadata: audioSessionMetadata(session).merging(
                    ["activationMode": String(describing: activationMode)],
                    uniquingKeysWith: { _, new in new }
                )
            )
        }
    }

    private func setSendingAudio(_ newValue: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        captureSendState = newValue ? .sending : .idle
    }

    private func cancelCaptureSendState() {
        stateLock.lock()
        defer { stateLock.unlock() }
        noteCaptureSendCancellationLocked()
        captureSendState = .idle
    }

    private func currentCaptureSendCancellationGeneration() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captureSendCancellationGeneration
    }

    private func shouldEnableSendingAudio(expectedCancellationGeneration: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captureSendCancellationGeneration == expectedCancellationGeneration
    }

    private func isSendingAudio() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case .sending = captureSendState else { return false }
        return true
    }

    private func noteCaptureSendCancellationLocked() {
        captureSendCancellationGeneration &+= 1
    }

    private func beginCaptureStopGraceIfNeeded() -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        noteCaptureSendCancellationLocked()
        guard case .sending = captureSendState else {
            captureSendState = .idle
            return nil
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + captureStopGraceNanoseconds
        captureSendState = .stopping(graceDeadlineNanoseconds: deadline)
        return deadline
    }

    private func finishCaptureStopGraceIfNeeded(expectedDeadlineNanoseconds: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case .stopping(let currentDeadlineNanoseconds) = captureSendState,
              currentDeadlineNanoseconds == expectedDeadlineNanoseconds else {
            return
        }
        captureSendState = .idle
    }

    private func shouldSendCapturedBuffer(nowNanoseconds: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        let shouldAccept = CaptureSendState.shouldAcceptCapturedBuffer(
            captureSendState,
            nowNanoseconds: nowNanoseconds
        )
        if !shouldAccept,
           case .stopping = captureSendState {
            captureSendState = .idle
        }
        return shouldAccept
    }

    private func prepareCapturePathIfNeeded() throws {
        let inputFormat = captureEngine.inputNode.inputFormat(forBus: 0)
        if captureConverter == nil {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw NSError(domain: "PCMWebSocketMediaSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "unable to create capture converter"])
            }
            captureConverter = converter
        }
    }

    private func refreshCapturePathForCurrentRoute() throws {
        let inputNode = captureEngine.inputNode
        let plan = CaptureRouteRefreshPlan.forLiveTransmitRoute(
            engineIsRunning: captureEngine.isRunning,
            inputTapInstalled: inputTapInstalled
        )
        if plan.shouldStopEngine {
            captureEngine.stop()
        }
        if plan.shouldResetEngine {
            captureEngine.reset()
        }
        if plan.shouldRemoveInputTap {
            inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        captureConverter = nil
        try prepareCapturePathIfNeeded()
        try installInputTapIfNeeded()
        if plan.shouldRestartEngine {
            try startCaptureEngineIfNeeded()
        }
        awaitReportCaptureRouteRefresh()
    }

    private func preparePlaybackPathIfNeeded() throws {
        let outputFormat = playerNode.outputFormat(forBus: 0)
        if outputFormat != targetFormat && playbackConverter == nil {
            playbackConverter = AVAudioConverter(from: targetFormat, to: outputFormat)
        }
    }

    private func installInputTapIfNeeded() throws {
        guard !inputTapInstalled else { return }

        let inputNode = captureEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(VoiceFrameAccumulator.samplesPerFrame), format: inputFormat) { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer)
        }
        inputTapInstalled = true
    }

    private func awaitReportCaptureRouteRefresh() {
        let inputFormat = captureEngine.inputNode.inputFormat(forBus: 0)
        Task {
            await report(
                "Refreshed capture path for current audio route",
                metadata: [
                    "sampleRate": String(inputFormat.sampleRate),
                    "channelCount": String(inputFormat.channelCount)
                ]
            )
        }
    }

    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
        reportLocalAudioLevelIfNeeded(buffer, nowNanoseconds: nowNanoseconds)
        guard shouldSendCapturedBuffer(nowNanoseconds: nowNanoseconds), state == .connected else { return }
        guard let copiedBuffer = Self.copyAudioPCMBuffer(buffer) else { return }
        captureProcessingQueue.async { [weak self] in
            self?.processCapturedBuffer(copiedBuffer)
        }
    }

    private func processCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard state == .connected else { return }
        reportCapturedBufferIfNeeded(buffer)
        guard let convertedBuffer = convertCapturedBuffer(buffer) else { return }
        reportConvertedBufferIfNeeded(convertedBuffer)
        let payloads = payloadsFromPCMBuffer(convertedBuffer)
        guard !payloads.isEmpty else { return }
        for payload in payloads {
            reportEnqueuedPayloadIfNeeded(payload)
        }

        Task {
            await audioChunkSender.enqueue(payloads)
        }
    }

    nonisolated static func copyAudioPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData else {
                continue
            }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destination, source, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return copy
    }

    private func reportLocalAudioLevelIfNeeded(
        _ buffer: AVAudioPCMBuffer,
        nowNanoseconds: UInt64
    ) {
        guard nowNanoseconds - lastLocalAudioLevelReportNanoseconds >= localAudioLevelReportIntervalNanoseconds else {
            return
        }
        guard let levelMetrics = PCMLevelMetrics.forBuffer(buffer) else { return }
        lastLocalAudioLevelReportNanoseconds = nowNanoseconds
        let level = Self.normalizedLocalSpeechLevel(from: levelMetrics)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.mediaSession(self, didMeasureLocalAudioLevel: level)
        }
    }

    private static func normalizedLocalSpeechLevel(from metrics: PCMLevelMetrics) -> Double {
        guard !metrics.isSilent else { return 0 }
        let rmsFloor = 0.006
        let rmsCeiling = 0.085
        let peakFloor = 0.035
        let peakCeiling = 0.42
        let rmsEnergy = normalized(metrics.rms, floor: rmsFloor, ceiling: rmsCeiling)
        let peakEnergy = normalized(metrics.peak, floor: peakFloor, ceiling: peakCeiling)
        return min(1, max(rmsEnergy, peakEnergy * 0.42))
    }

    private static func normalized(_ value: Double, floor: Double, ceiling: Double) -> Double {
        guard ceiling > floor else { return 0 }
        return max(0, min(1, (value - floor) / (ceiling - floor)))
    }

    private func reportCapturedBufferIfNeeded(_ buffer: AVAudioPCMBuffer) {
        guard capturedBufferReportBudget > 0 else { return }
        capturedBufferReportBudget -= 1
        var metadata = [
            "frameLength": String(buffer.frameLength),
            "sampleRate": String(buffer.format.sampleRate),
            "channelCount": String(buffer.format.channelCount),
            "pcmFormat": String(describing: buffer.format.commonFormat),
            "interleaved": String(buffer.format.isInterleaved),
        ]
        if let levelMetrics = PCMLevelMetrics.forBuffer(buffer) {
            metadata.merge(levelMetrics.diagnosticMetadata) { _, new in new }
        }
        Task {
            await report(
                "Captured local audio buffer",
                metadata: metadata
            )
        }
    }

    private func reportConvertedBufferIfNeeded(_ buffer: AVAudioPCMBuffer) {
        guard convertedBufferReportBudget > 0 else { return }
        convertedBufferReportBudget -= 1
        var metadata = [
            "frameLength": String(buffer.frameLength),
            "sampleRate": String(buffer.format.sampleRate),
            "channelCount": String(buffer.format.channelCount),
            "pcmFormat": String(describing: buffer.format.commonFormat),
            "interleaved": String(buffer.format.isInterleaved),
        ]
        if let levelMetrics = PCMLevelMetrics.forBuffer(buffer) {
            metadata.merge(levelMetrics.diagnosticMetadata) { _, new in new }
        }
        Task {
            await report(
                "Converted local audio buffer",
                metadata: metadata
            )
        }
    }

    private func reportEnqueuedPayloadIfNeeded(_ payload: String) {
        guard enqueuedPayloadReportBudget > 0 else { return }
        enqueuedPayloadReportBudget -= 1
        var metadata = [
            "payloadLength": String(payload.count),
            "payloadDigest": AudioChunkPayloadCodec.transportDigest(payload),
        ]
        if let opusFrame = VoiceAudioFramePayloadCodec.decode(payload) {
            metadata["codec"] = "opus"
            metadata["frameIndex"] = String(opusFrame.frameIndex)
            metadata["packetSizeBytes"] = String(opusFrame.packet.count)
            metadata["sampleRate"] = String(opusFrame.sampleRate)
            metadata["frameDurationMs"] = String(opusFrame.frameDurationMilliseconds)
        } else if let data = Data(base64Encoded: payload),
                  let packet = try? VoicePacketV1Codec.decode(data) {
            metadata["codec"] = "binary-opus-v1"
            metadata["frameIndex"] = String(packet.frameIndex)
            metadata["packetSizeBytes"] = String(packet.opusPayload.count)
            metadata["sampleRate"] = String(VoiceFrameAccumulator.sampleRate)
            metadata["frameDurationMs"] = String(VoiceFrameAccumulator.frameDurationMilliseconds)
        } else if let data = Data(base64Encoded: payload),
           let levelMetrics = PCMLevelMetrics.forInt16PCMData(data) {
            metadata["codec"] = "legacy-pcm"
            metadata["base64Length"] = String(payload.count)
            metadata.merge(levelMetrics.diagnosticMetadata) { _, new in new }
        }
        Task {
            await report(
                "Enqueued outbound audio chunk",
                metadata: metadata
            )
        }
    }

    private func resetCaptureReportingBudgets() {
        capturedBufferReportBudget = 3
        convertedBufferReportBudget = 3
        enqueuedPayloadReportBudget = 3
    }


    private func convertCapturedBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = captureConverter else { return nil }
        let outputFrameCapacity =
            AVAudioFrameCount(
                (Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate).rounded(.up)
            ) + 1
        guard let converted =
            AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }

        var localBuffer: AVAudioPCMBuffer? = buffer
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if let current = localBuffer {
                outStatus.pointee = .haveData
                localBuffer = nil
                return current
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        guard error == nil else { return nil }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return converted.frameLength > 0 ? converted : nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }

    private func payloadsFromPCMBuffer(_ buffer: AVAudioPCMBuffer) -> [String] {
        guard let channelData = buffer.int16ChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let bytes = Data(
            bytes: channelData.pointee,
            count: frameCount * MemoryLayout<Int16>.size
        )
        mediaEncodingLock.lock()
        defer { mediaEncodingLock.unlock() }

        switch outboundVoiceMediaPolicy {
        case .opusV2, .binaryOpusV1:
            guard let opusCodec else {
                return legacyPCMPayloads(fromCanonicalPCMData: bytes)
            }
            let frames = outboundFrameAccumulator.append(bytes)
            var payloads: [String] = []
            payloads.reserveCapacity(frames.count)
            for frame in frames {
                do {
                    let packet = try opusCodec.encode(frame.pcmData)
                    switch outboundVoiceMediaPolicy {
                    case .binaryOpusV1:
                        var flags: UInt16 = 0
                        if outboundOpusEncodingPolicy.payloadFeatures.contains(VoiceMediaCapabilities.fecFeature) {
                            flags |= VoicePacketV1Codec.Flag.inBandFEC.rawValue
                        }
                        let voicePacket = try VoicePacketV1(
                            frameIndex: frame.frameIndex,
                            flags: flags,
                            opusPayload: packet
                        )
                        payloads.append(VoiceAudioFramePayloadCodec.encodeBinaryOpus(voicePacket))
                    case .opusV2:
                        if let payload = VoiceAudioFramePayloadCodec.encodeOpus(
                            packet: packet,
                            frameIndex: frame.frameIndex,
                            features: outboundOpusEncodingPolicy.payloadFeatures
                        ) {
                            payloads.append(payload)
                        }
                    case .legacyPCM:
                        payloads.append(contentsOf: legacyPCMPayloads(fromCanonicalPCMData: frame.pcmData))
                    }
                } catch {
                    Task {
                        await report(
                            "Opus encode failed; falling back to legacy PCM for frame",
                            metadata: [
                                "frameIndex": String(frame.frameIndex),
                                "error": error.localizedDescription,
                            ]
                        )
                    }
                    payloads.append(contentsOf: legacyPCMPayloads(fromCanonicalPCMData: frame.pcmData))
                }
            }
            return payloads
        case .legacyPCM:
            outboundFrameAccumulator.reset()
            return legacyPCMPayloads(fromCanonicalPCMData: bytes)
        }
    }

    private func legacyPCMPayloads(fromCanonicalPCMData data: Data) -> [String] {
        let legacyData = PCMInt16SampleRateConverter.convert(
            data,
            fromSampleRate: VoiceFrameAccumulator.sampleRate,
            toSampleRate: Int(PCMOutgoingPayloadSplitter.targetSampleRate)
        )
        return PCMOutgoingPayloadSplitter.encodePayloads(fromInt16PCMData: legacyData)
    }

    private func resetOutboundFrameAccumulator() {
        mediaEncodingLock.lock()
        outboundFrameAccumulator.reset()
        mediaEncodingLock.unlock()
    }

    private nonisolated func schedulePlayback(
        for data: Data,
        playbackProfile: MediaSessionPlaybackProfile,
        cushionPolicy: PlaybackCushionPolicy
    ) throws {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else { return }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return
        }
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channelData = sourceBuffer.int16ChannelData else { return }
        data.copyBytes(
            to: UnsafeMutableRawBufferPointer(
                start: channelData.pointee,
                count: data.count
            )
        )

        let playbackBuffer = try makePlaybackBuffer(from: sourceBuffer)
        try startPlaybackEngineIfNeeded()
        let receivePlan = Self.playbackBufferReceivePlan(
            isPlayerNodePlaying: playerNode.isPlaying,
            playbackIOCycleAvailable: playbackIOCycleAvailable
        )
        switch receivePlan {
        case .deferUntilIOCycle:
            enqueuePendingPlaybackBuffer(playbackBuffer)
            requestPlaybackStartWhenReady()
            Task {
                await report(
                    "Deferred playback node start until IO cycle",
                    metadata: ["pendingBufferCount": String(pendingPlaybackBufferCount())]
                )
            }
            return
        case .scheduleAndStartNode:
            if shouldBufferForPlaybackCushion(
                playbackProfile: playbackProfile,
                cushionPolicy: cushionPolicy,
                receivePlan: receivePlan
            ) {
                bufferPlaybackForCushion(
                    playbackBuffer,
                    playbackProfile: playbackProfile,
                    receivePlan: receivePlan
                )
                return
            }
            schedulePlaybackBuffer(playbackBuffer)
            startPlaybackNode()
            drainPendingPlaybackBuffers()
        case .scheduleOnly:
            if shouldBufferForPlaybackCushion(
                playbackProfile: playbackProfile,
                cushionPolicy: cushionPolicy,
                receivePlan: receivePlan
            ) {
                bufferPlaybackForCushion(
                    playbackBuffer,
                    playbackProfile: playbackProfile,
                    receivePlan: receivePlan
                )
                return
            }
            schedulePlaybackBuffer(playbackBuffer)
        }
    }

    private func schedulePlaybackBuffer(_ playbackBuffer: AVAudioPCMBuffer) {
        stateLock.lock()
        scheduledPlaybackBufferCount += 1
        stateLock.unlock()
        playerNode.scheduleBuffer(playbackBuffer, completionCallbackType: Self.playbackCompletionCallbackType) { [weak self] _ in
            self?.markScheduledPlaybackBufferCompleted()
        }
        playerNode.prepare(withFrameCount: max(playbackBuffer.frameLength, 512))
        schedulePlaybackNodeStartupReassertion(reason: "playback-buffer-scheduled")
        guard consumePlaybackBufferReportBudget() else { return }
        var metadata = [
            "frameLength": String(playbackBuffer.frameLength),
            "sampleRate": String(playbackBuffer.format.sampleRate),
            "channelCount": String(playbackBuffer.format.channelCount),
            "pcmFormat": String(describing: playbackBuffer.format.commonFormat),
            "interleaved": String(playbackBuffer.format.isInterleaved),
        ]
        if let levelMetrics = PCMLevelMetrics.forBuffer(playbackBuffer) {
            metadata.merge(levelMetrics.diagnosticMetadata) { _, new in new }
        }
        Task {
            await report(
                "Playback buffer scheduled",
                metadata: metadata
            )
        }
    }

    private func consumePlaybackBufferReportBudget() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard playbackBufferReportBudget > 0 else { return false }
        playbackBufferReportBudget -= 1
        return true
    }

    private func resetPlaybackBufferReportBudget() {
        stateLock.lock()
        playbackBufferReportBudget = 8
        stateLock.unlock()
    }

    private func consumePlaybackLockBusyReportBudget() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard playbackLockBusyReportBudget > 0 else { return false }
        playbackLockBusyReportBudget -= 1
        return true
    }

    private func resetPlaybackLockBusyReportBudget() {
        stateLock.lock()
        playbackLockBusyReportBudget = 3
        stateLock.unlock()
    }

    private func markScheduledPlaybackBufferCompleted() {
        stateLock.lock()
        scheduledPlaybackBufferCount = max(0, scheduledPlaybackBufferCount - 1)
        let didDrainPendingPlayback = scheduledPlaybackBufferCount == 0
            && pendingPlaybackBuffers.isEmpty
            && pendingRemoteAudioPayloads.isEmpty
            && pendingRemoteAudioChunks.isEmpty
        stateLock.unlock()
        guard didDrainPendingPlayback else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.mediaSessionDidDrainPendingPlayback(self)
        }
    }

    static func playbackBufferReceivePlan(
        isPlayerNodePlaying: Bool,
        playbackIOCycleAvailable: Bool
    ) -> PlaybackBufferReceivePlan {
        if isPlayerNodePlaying {
            return .scheduleOnly
        }
        guard playbackIOCycleAvailable else { return .deferUntilIOCycle }
        return .scheduleAndStartNode
    }

    static func playbackStartWaitPlan(
        isPlayerNodePlaying: Bool,
        playbackIOCycleAvailable: Bool,
        pendingPlaybackBufferCount: Int
    ) -> PlaybackStartWaitPlan {
        guard pendingPlaybackBufferCount > 0 else { return .stopWaiting }
        if isPlayerNodePlaying { return .drainPendingBuffers }
        if playbackIOCycleAvailable { return .schedulePendingBuffersAndStartNode }
        return .waitForIOCycle
    }

    static func shouldPrimeSystemActivatedPlaybackNode(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode,
        playbackAlreadyReady: Bool
    ) -> Bool {
        activationMode == .systemActivated
            && startupMode == .playbackOnly
            && !playbackAlreadyReady
    }

    private func primeSystemActivatedPlaybackNodeIfNeeded(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode,
        playbackAlreadyReady: Bool
    ) {
        guard Self.shouldPrimeSystemActivatedPlaybackNode(
            activationMode: activationMode,
            startupMode: startupMode,
            playbackAlreadyReady: playbackAlreadyReady
        ) else { return }
        startPlaybackNode(reason: "system-activated-playback-prime")
        schedulePlaybackNodeStartupReassertion(reason: "system-activated-playback-prime")
    }

    private func startPlaybackNode(reason: String = "playback-buffer-scheduled") {
        playerNode.play()
        Task {
            await report("Playback node started", metadata: ["reason": reason])
        }
    }

    private func makePlaybackBuffer(from sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter = playbackConverter else { return sourceBuffer }

        let outputFormat = playerNode.outputFormat(forBus: 0)
        let outputFrameCapacity =
            AVAudioFrameCount(
                (Double(sourceBuffer.frameLength) * outputFormat.sampleRate / sourceBuffer.format.sampleRate).rounded(.up)
            ) + 1
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            throw NSError(domain: "PCMWebSocketMediaSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "unable to allocate playback buffer"])
        }

        var localBuffer: AVAudioPCMBuffer? = sourceBuffer
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if let current = localBuffer {
                outStatus.pointee = .haveData
                localBuffer = nil
                return current
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if let error {
            throw error
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return converted
        case .error:
            throw NSError(domain: "PCMWebSocketMediaSession", code: 3, userInfo: [NSLocalizedDescriptionKey: "playback conversion failed"])
        @unknown default:
            throw NSError(domain: "PCMWebSocketMediaSession", code: 4, userInfo: [NSLocalizedDescriptionKey: "unknown playback conversion status"])
        }
    }

    private func resetPlaybackForTransmit() {
        playbackStartTask?.cancel()
        playbackStartTask = nil
        playbackCushionTask?.cancel()
        playbackCushionTask = nil
        playbackNodeStartupReassertionTask?.cancel()
        playbackNodeStartupReassertionTask = nil
        pendingPlaybackBuffers.removeAll(keepingCapacity: false)
        pendingRemoteAudioPayloads.removeAll(keepingCapacity: false)
        pendingRemoteAudioChunks.removeAll(keepingCapacity: false)
        resetScheduledPlaybackBufferCount()
        resetPlayoutEngineForCurrentReceiveEpoch()
        resetOpusPlayoutReportBudgets()
        resetPlaybackBufferReportBudget()
        playerNode.stop()
        playerNode.reset()
    }

    private nonisolated func resetPlaybackPathForReceiveRecovery() {
        playbackStartTask?.cancel()
        playbackStartTask = nil
        playbackCushionTask?.cancel()
        playbackCushionTask = nil
        playbackNodeStartupReassertionTask?.cancel()
        playbackNodeStartupReassertionTask = nil
        pendingPlaybackBuffers.removeAll(keepingCapacity: false)
        pendingRemoteAudioPayloads.removeAll(keepingCapacity: false)
        resetScheduledPlaybackBufferCount()
        playerNode.stop()
        playerNode.reset()
        playbackEngine.stop()
        playbackEngine.reset()
        playbackConverter = nil
        isPlaybackReady = false
        resetPlayoutEngineForCurrentReceiveEpoch()
        resetOpusPlayoutReportBudgets()
        resetPlaybackBufferReportBudget()
    }

    private func resetPlayoutEngineForCurrentReceiveEpoch() {
        playoutEngine.reset(
            epoch: VoiceReceiveEpochID(rawValue: remoteAudioReceiveEpoch),
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    private func resetOpusPlayoutReportBudgets() {
        opusPlayoutReportBudget = 8
        opusPlayoutInvariantBudget = 4
    }

    private func startCaptureEngineIfNeeded() throws {
        if !captureEngine.isRunning {
            try captureEngine.start()
            Task {
                await report("Capture engine started", metadata: [:])
            }
        }
    }

    private func startPlaybackEngineIfNeeded() throws {
        if !playbackEngine.isRunning {
            playbackEngine.prepare()
            try playbackEngine.start()
            Task {
                await report("Playback engine started", metadata: [:])
            }
        }
    }

    private func startReceivePlaybackRecoveryIfNeeded() {
        guard playbackRecoveryTask == nil else { return }
        let activationMode: MediaSessionActivationMode =
            activeAudioSessionOwnership == .appManaged ? .appManaged : .systemActivated
        let pendingChunkCount = pendingRemoteAudioChunkCount()
        setState(.preparing)
        playbackRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.playbackRecoveryTask = nil }
            do {
                await self.report(
                    "Receive playback recovery started",
                    metadata: [
                        "activationMode": String(describing: activationMode),
                        "pendingChunkCount": String(pendingChunkCount),
                    ]
                )
                try await self.performReceivePlaybackRecovery(activationMode: activationMode)
                await self.report(
                    "Receive playback recovery completed",
                    metadata: ["pendingChunkCount": String(self.pendingRemoteAudioChunkCount())]
                )
            } catch {
                let errorDescription = error.localizedDescription
                self.setState(.failed("playback failed: \(errorDescription)"))
                await self.report(
                    "Receive playback recovery failed",
                    metadata: ["error": errorDescription]
                )
            }
        }
    }

    private func performReceivePlaybackRecovery(
        activationMode: MediaSessionActivationMode
    ) async throws {
        try configureAudioSession(
            activationMode: activationMode,
            startupMode: .playbackOnly
        )
        try preparePlaybackPathIfNeeded()
        try startPlaybackEngineIfNeeded()
        try withReceivePlaybackLock {
            isPlaybackReady = true
            try drainPendingRemoteAudioIfReady()
        }
        setState(.connected)
    }

    private var playbackIOCycleAvailable: Bool {
        playbackEngine.outputNode.lastRenderTime != nil
            || playbackEngine.mainMixerNode.lastRenderTime != nil
    }

    private func enqueuePendingPlaybackBuffer(_ playbackBuffer: AVAudioPCMBuffer) {
        pendingPlaybackBuffers.append(playbackBuffer)
        if pendingPlaybackBuffers.count > maximumPendingPlaybackBuffers {
            pendingPlaybackBuffers.removeFirst(pendingPlaybackBuffers.count - maximumPendingPlaybackBuffers)
        }
    }

    private func pendingPlaybackBufferCount() -> Int {
        pendingPlaybackBuffers.count
    }

    private nonisolated func enqueuePendingRemoteAudioPayload(
        _ payload: PendingRemoteAudioPayload
    ) {
        pendingRemoteAudioPayloads.append(payload)
        if pendingRemoteAudioPayloads.count > maximumPendingRemoteAudioChunks {
            pendingRemoteAudioPayloads.removeFirst(
                pendingRemoteAudioPayloads.count - maximumPendingRemoteAudioChunks
            )
        }
    }

    private nonisolated func pendingRemoteAudioPayloadCount() -> Int {
        pendingRemoteAudioPayloads.count
    }

    private nonisolated func enqueuePendingRemoteAudioChunk(
        _ chunk: DecodedCanonicalPCMChunk
    ) {
        pendingRemoteAudioChunks.append(
            PendingRemoteAudioChunk(
                data: chunk.data,
                playbackProfile: chunk.playbackProfile,
                cushionPolicy: chunk.cushionPolicy
            )
        )
        if pendingRemoteAudioChunks.count > maximumPendingRemoteAudioChunks {
            pendingRemoteAudioChunks.removeFirst(
                pendingRemoteAudioChunks.count - maximumPendingRemoteAudioChunks
            )
        }
    }

    private nonisolated func pendingRemoteAudioChunkCount() -> Int {
        pendingRemoteAudioChunks.count
    }

    private func drainPendingRemoteAudioIfReady() throws {
        try drainPendingRemoteAudioPayloadsIfReady()
        try drainPendingRemoteAudioChunksIfReady()
    }

    private func drainPendingRemoteAudioPayloadsIfReady() throws {
        guard isPlaybackReady else { return }
        guard !pendingRemoteAudioPayloads.isEmpty else { return }
        let payloads = pendingRemoteAudioPayloads
        pendingRemoteAudioPayloads.removeAll(keepingCapacity: false)
        for payload in payloads {
            if let playbackDeadlineNanoseconds = payload.playbackDeadlineNanoseconds,
               DispatchTime.now().uptimeNanoseconds >= playbackDeadlineNanoseconds {
                Task {
                    await report(
                        "Dropped pending remote audio payload after playback deadline",
                        metadata: [
                            "playbackProfile": String(describing: payload.playbackProfile),
                            "reason": "playback-deadline-elapsed",
                        ]
                    )
                }
                continue
            }
            guard let decodedResult = decodedCanonicalPCMChunks(
                from: payload.payload,
                playbackProfile: payload.playbackProfile
            ) else {
                Task {
                    await report(
                        "Dropped pending remote audio payload after decode failed",
                        metadata: [
                            "playbackProfile": String(describing: payload.playbackProfile),
                            "reason": "decode-failed",
                        ]
                    )
                }
                continue
            }
            for chunk in decodedResult.chunks {
                try schedulePlayback(
                    for: chunk.data,
                    playbackProfile: chunk.playbackProfile,
                    cushionPolicy: chunk.cushionPolicy
                )
            }
        }
    }

    private func drainPendingRemoteAudioChunksIfReady() throws {
        guard isPlaybackReady else { return }
        guard !pendingRemoteAudioChunks.isEmpty else { return }
        let chunks = pendingRemoteAudioChunks
        pendingRemoteAudioChunks.removeAll(keepingCapacity: false)
        for chunk in chunks {
            try schedulePlayback(
                for: chunk.data,
                playbackProfile: chunk.playbackProfile,
                cushionPolicy: chunk.cushionPolicy
            )
        }
    }

    private func drainPendingPlaybackBuffers() {
        guard playerNode.isPlaying else { return }
        guard !pendingPlaybackBuffers.isEmpty else { return }
        let buffers = pendingPlaybackBuffers
        pendingPlaybackBuffers.removeAll(keepingCapacity: false)
        for buffer in buffers {
            schedulePlaybackBuffer(buffer)
        }
    }

    private func reassertPlaybackNodeAfterRouteChangeIfNeeded() {
        reassertPlaybackNodeIfNeeded(
            reason: "audio-route-change",
            message: "Playback node reasserted after audio route change"
        )
    }

    private func reassertPlaybackNodeIfNeeded(reason: String, message: String) {
        guard shouldReassertPlaybackNode() else { return }
        playerNode.play()
        drainPendingPlaybackBuffers()
        Task {
            await report(
                message,
                metadata: [
                    "reason": reason,
                    "pendingBufferCount": String(pendingPlaybackBufferCount()),
                    "scheduledBufferCount": String(scheduledPlaybackBufferCountSnapshot()),
                ]
            )
        }
    }

    private func shouldReassertPlaybackNode() -> Bool {
        Self.shouldReassertPlaybackNode(
            isPlayerNodePlaying: playerNode.isPlaying,
            pendingPlaybackBufferCount: pendingPlaybackBufferCount(),
            scheduledPlaybackBufferCount: scheduledPlaybackBufferCountSnapshot()
        )
    }

    static func shouldReassertPlaybackNode(
        isPlayerNodePlaying: Bool,
        pendingPlaybackBufferCount: Int,
        scheduledPlaybackBufferCount: Int
    ) -> Bool {
        guard !isPlayerNodePlaying else { return false }
        return pendingPlaybackBufferCount > 0 || scheduledPlaybackBufferCount > 0
    }

    static func shouldBufferForPlaybackCushion(
        playbackProfile: MediaSessionPlaybackProfile,
        cushionPolicy: PlaybackCushionPolicy,
        receivePlan: PlaybackBufferReceivePlan,
        isPlayerNodePlaying: Bool,
        pendingPlaybackBufferCount: Int,
        scheduledPlaybackBufferCount: Int,
        minimumCushionBufferCount: Int
    ) -> Bool {
        guard cushionPolicy == .applyTransportCushion else { return false }
        guard scheduledPlaybackBufferCount == 0,
              pendingPlaybackBufferCount < minimumCushionBufferCount else {
            return false
        }
        switch playbackProfile {
        case .lowLatency, .fastRelayBalanced, .relayJitterBuffered, .wakeBackgroundContinuity:
            return receivePlan == .scheduleAndStartNode
                || (isPlayerNodePlaying && receivePlan == .scheduleOnly)
        }
    }

    static func playbackCushionConfiguration(
        for playbackProfile: MediaSessionPlaybackProfile
    ) -> MediaTransportPlaybackCushionConfiguration {
        switch playbackProfile {
        case .lowLatency:
            return MediaTransportPolicy.directLowLatency.playbackCushion
        case .fastRelayBalanced:
            return MediaTransportPolicy.fastRelayBalanced.playbackCushion
        case .relayJitterBuffered:
            return MediaTransportPolicy.websocketContinuity.playbackCushion
        case .wakeBackgroundContinuity:
            return MediaTransportPolicy.wakeBackgroundContinuity.playbackCushion
        }
    }

    private func shouldBufferForPlaybackCushion(
        playbackProfile: MediaSessionPlaybackProfile,
        cushionPolicy: PlaybackCushionPolicy,
        receivePlan: PlaybackBufferReceivePlan
    ) -> Bool {
        let policy = Self.playbackCushionConfiguration(for: playbackProfile)
        return Self.shouldBufferForPlaybackCushion(
            playbackProfile: playbackProfile,
            cushionPolicy: cushionPolicy,
            receivePlan: receivePlan,
            isPlayerNodePlaying: playerNode.isPlaying,
            pendingPlaybackBufferCount: pendingPlaybackBufferCount(),
            scheduledPlaybackBufferCount: scheduledPlaybackBufferCountSnapshot(),
            minimumCushionBufferCount: policy.minimumBufferCount
        )
    }

    private func bufferPlaybackForCushion(
        _ playbackBuffer: AVAudioPCMBuffer,
        playbackProfile: MediaSessionPlaybackProfile,
        receivePlan: PlaybackBufferReceivePlan
    ) {
        enqueuePendingPlaybackBuffer(playbackBuffer)
        let pendingBufferCount = pendingPlaybackBufferCount()
        let policy = Self.playbackCushionConfiguration(for: playbackProfile)
        if pendingBufferCount >= policy.minimumBufferCount {
            playbackCushionTask?.cancel()
            playbackCushionTask = nil
            startBufferedPlaybackAfterCushion(reason: "buffer-count")
            Task {
                await report(
                    "Started playback after playout cushion",
                    metadata: [
                        "pendingBufferCount": String(pendingBufferCount),
                        "reason": "buffer-count",
                        "playbackProfile": String(describing: playbackProfile),
                        "receivePlan": String(describing: receivePlan),
                    ]
                )
            }
        } else {
            requestPlaybackCushionDrainWhenReady(playbackProfile: playbackProfile)
            Task {
                await report(
                    "Buffered playback buffer for playout cushion",
                    metadata: [
                        "pendingBufferCount": String(pendingBufferCount),
                        "scheduledBufferCount": String(scheduledPlaybackBufferCountSnapshot()),
                        "playbackProfile": String(describing: playbackProfile),
                        "receivePlan": String(describing: receivePlan),
                        "minimumCushionBufferCount": String(policy.minimumBufferCount),
                        "timeoutMilliseconds": String(policy.timeoutNanoseconds / 1_000_000),
                    ]
                )
            }
        }
    }

    private func startBufferedPlaybackAfterCushion(reason: String) {
        if playerNode.isPlaying {
            drainPendingPlaybackBuffers()
            return
        }
        let buffers = pendingPlaybackBuffers
        pendingPlaybackBuffers.removeAll(keepingCapacity: false)
        for buffer in buffers {
            schedulePlaybackBuffer(buffer)
        }
        startPlaybackNode(reason: "playout-cushion-\(reason)")
    }

    private func scheduledPlaybackBufferCountSnapshot() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return scheduledPlaybackBufferCount
    }

    private func resetScheduledPlaybackBufferCount() {
        stateLock.lock()
        scheduledPlaybackBufferCount = 0
        stateLock.unlock()
    }

    private func schedulePlaybackNodeStartupReassertion(reason: String) {
        guard playbackNodeStartupReassertionTask == nil else { return }
        playbackNodeStartupReassertionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.playbackNodeStartupReassertionTask = nil }
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self.reassertPlaybackNodeIfNeeded(
                reason: reason,
                message: "Playback node startup reasserted"
            )
        }
    }

    private func requestPlaybackCushionDrainWhenReady(
        playbackProfile: MediaSessionPlaybackProfile
    ) {
        guard playbackCushionTask == nil else { return }
        let timeoutNanoseconds = Self.playbackCushionConfiguration(for: playbackProfile).timeoutNanoseconds
        playbackCushionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.playbackCushionTask = nil }
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            let drainedBufferCount = self.withReceivePlaybackLock { () -> Int in
                let pendingBufferCount = self.pendingPlaybackBufferCount()
                self.startBufferedPlaybackAfterCushion(reason: "timeout")
                return pendingBufferCount
            }
            await self.report(
                "Started playback after playout cushion",
                metadata: [
                    "pendingBufferCount": String(drainedBufferCount),
                    "reason": "timeout",
                    "playbackProfile": String(describing: playbackProfile),
                    "timeoutMilliseconds": String(timeoutNanoseconds / 1_000_000),
                ]
            )
        }
    }

    private func requestPlaybackStartWhenReady() {
        guard playbackStartTask == nil else { return }
        playbackStartTask = Task { [weak self] in
            guard let self else { return }
            defer { self.playbackStartTask = nil }
            var attempt = 1
            while !Task.isCancelled {
                switch Self.playbackStartWaitPlan(
                    isPlayerNodePlaying: self.playerNode.isPlaying,
                    playbackIOCycleAvailable: self.playbackIOCycleAvailable,
                    pendingPlaybackBufferCount: self.pendingPlaybackBufferCount()
                ) {
                case .drainPendingBuffers:
                    self.drainPendingPlaybackBuffers()
                    return

                case .schedulePendingBuffersAndStartNode:
                    let buffers = self.pendingPlaybackBuffers
                    self.pendingPlaybackBuffers.removeAll(keepingCapacity: false)
                    for buffer in buffers {
                        self.schedulePlaybackBuffer(buffer)
                    }
                    self.playerNode.play()
                    await self.report(
                        "Playback node started after IO cycle wait",
                        metadata: ["attempt": String(attempt)]
                    )
                    return

                case .waitForIOCycle:
                    if attempt.isMultiple(of: 25) {
                        await self.report(
                            "Playback node still waiting for IO cycle",
                            metadata: [
                                "attempt": String(attempt),
                                "pendingBufferCount": String(self.pendingPlaybackBufferCount()),
                            ]
                        )
                    }
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 20_000_000)

                case .stopWaiting:
                    return
                }
            }
        }
    }

    private func report(_ message: String, metadata: [String: String]) async {
        guard let reportEvent else { return }
        Task {
            await reportEvent(message, metadata)
        }
    }

    private func audioSessionMetadata(_ session: AVAudioSession) -> [String: String] {
        let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        let inputs = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        let outputNames = session.currentRoute.outputs.map(\.portName).joined(separator: ",")
        let inputNames = session.currentRoute.inputs.map(\.portName).joined(separator: ",")
        let availableInputs =
            session.availableInputs?
                .map { "\($0.portName):\($0.portType.rawValue)" }
                .joined(separator: ",")
            ?? ""
        return [
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "categoryOptions": String(session.categoryOptions.rawValue),
            "sampleRate": String(session.sampleRate),
            "outputs": outputs.isEmpty ? "none" : outputs,
            "outputNames": outputNames.isEmpty ? "none" : outputNames,
            "inputs": inputs.isEmpty ? "none" : inputs,
            "inputNames": inputNames.isEmpty ? "none" : inputNames,
            "availableInputs": availableInputs.isEmpty ? "none" : availableInputs
        ]
    }
}
