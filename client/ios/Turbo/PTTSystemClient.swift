import Foundation
import PushToTalk
import AVFAudio

enum PTTSystemClientError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "PTT is not ready"
        }
    }
}

enum PTTSystemLeaveReason: Equatable {
    case userInitiated(description: String)
    case system(description: String)
    case simulator
    case other(description: String)

    init(rawDescription: String) {
        if rawDescription == "simulator" {
            self = .simulator
        } else if rawDescription.contains("PTChannelLeaveReason(rawValue: 1)") {
            self = .userInitiated(description: rawDescription)
        } else if rawDescription.contains("PTChannelLeaveReason(rawValue: 2)") {
            self = .system(description: rawDescription)
        } else {
            self = .other(description: rawDescription)
        }
    }

    var description: String {
        switch self {
        case .userInitiated(let description),
             .system(let description),
             .other(let description):
            return description
        case .simulator:
            return "simulator"
        }
    }

    var isUserInitiated: Bool {
        if case .userInitiated = self {
            return true
        }
        return false
    }
}

@MainActor
struct PTTSystemClientCallbacks {
    let receivedEphemeralPushToken: (Data) -> Void
    let receivedIncomingPush: (UUID, TurboPTTPushPayload) -> Void
    let willReturnIncomingPushResult: (UUID, TurboPTTPushPayload, String) -> Void
    let didJoinChannel: (UUID, String) -> Void
    let didLeaveChannel: (UUID, PTTSystemLeaveReason) -> Void
    let failedToJoinChannel: (UUID, Error) -> Void
    let failedToLeaveChannel: (UUID, Error) -> Void
    let didBeginTransmitting: (UUID, String) -> Void
    let didEndTransmitting: (UUID, String) -> Void
    let failedToBeginTransmitting: (UUID, Error) -> Void
    let failedToStopTransmitting: (UUID, Error) -> Void
    let didActivateAudioSession: (AVAudioSession) -> Void
    let didDeactivateAudioSession: (AVAudioSession) -> Void
    let willRequestRestoredChannelDescriptor: (UUID) -> Void
    let descriptorForRestoredChannel: (UUID) -> PTChannelDescriptor
    let restoredChannel: (UUID) -> Void
}

@MainActor
protocol PTTSystemClientProtocol: AnyObject {
    var isReady: Bool { get }
    var modeDescription: String { get }

    func configure(callbacks: PTTSystemClientCallbacks) async throws
    func joinChannel(channelUUID: UUID, name: String) throws
    func leaveChannel(channelUUID: UUID) throws
    func beginTransmitting(channelUUID: UUID) throws
    func stopTransmitting(channelUUID: UUID) throws
    func setTransmissionMode(_ mode: PTTransmissionMode, channelUUID: UUID) async throws
    func setActiveRemoteParticipant(name: String?, channelUUID: UUID) async throws
    func setAccessoryButtonEventsEnabled(_ enabled: Bool, channelUUID: UUID) async throws
    func setServiceStatus(_ status: PTServiceStatus, channelUUID: UUID) async throws
    func updateChannelDescriptor(name: String, channelUUID: UUID) async throws
}

@MainActor
private final class ApplePTTSystemClientAdapter: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate {
    let callbacks: PTTSystemClientCallbacks

    init(callbacks: PTTSystemClientCallbacks) {
        self.callbacks = callbacks
    }

    func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken token: Data) {
        Task { @MainActor [callbacks] in
            callbacks.receivedEphemeralPushToken(token)
        }
    }

    func handleIncomingPush(channelUUID: UUID, payload: TurboPTTPushPayload) -> PTPushResult {
        let result: PTPushResult
        let resultDescription: String
        switch payload.event {
        case .transmitStart:
            // TODO: Populate the participant image from a locally cached contact
            // avatar once we persist and restore that metadata on device.
            result = .activeRemoteParticipant(PTParticipant(name: payload.notificationTitle, image: nil))
            resultDescription = "activeRemoteParticipant"
        case .leaveChannel:
            result = .leaveChannel
            resultDescription = "leaveChannel"
        }

        Task { @MainActor [callbacks] in
            callbacks.willReturnIncomingPushResult(channelUUID, payload, resultDescription)
        }

        // Return the system result first and defer app-owned bookkeeping so the
        // PushToTalk wake callback stays on the fast path.
        Task { @MainActor [callbacks] in
            callbacks.receivedIncomingPush(channelUUID, payload)
        }
        return result
    }

    func channelManager(_ channelManager: PTChannelManager, didJoinChannel channelUUID: UUID, reason: PTChannelJoinReason) {
        Task { @MainActor [callbacks] in
            callbacks.didJoinChannel(channelUUID, String(describing: reason))
        }
    }

    func channelManager(_ channelManager: PTChannelManager, didLeaveChannel channelUUID: UUID, reason: PTChannelLeaveReason) {
        Task { @MainActor [callbacks] in
            callbacks.didLeaveChannel(channelUUID, PTTSystemLeaveReason(rawDescription: String(describing: reason)))
        }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToJoinChannel channelUUID: UUID, error: any Error) {
        Task { @MainActor [callbacks] in
            callbacks.failedToJoinChannel(channelUUID, error)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToLeaveChannel channelUUID: UUID, error: any Error) {
        Task { @MainActor [callbacks] in
            callbacks.failedToLeaveChannel(channelUUID, error)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor [callbacks] in
            callbacks.didBeginTransmitting(channelUUID, String(describing: source))
        }
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor [callbacks] in
            callbacks.didEndTransmitting(channelUUID, String(describing: source))
        }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToBeginTransmittingInChannel channelUUID: UUID, error: any Error) {
        Task { @MainActor [callbacks] in
            callbacks.failedToBeginTransmitting(channelUUID, error)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToStopTransmittingInChannel channelUUID: UUID, error: any Error) {
        Task { @MainActor [callbacks] in
            callbacks.failedToStopTransmitting(channelUUID, error)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
        Task { @MainActor [callbacks] in
            callbacks.didActivateAudioSession(audioSession)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor [callbacks] in
            callbacks.didDeactivateAudioSession(audioSession)
        }
    }

    func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String : Any]) -> PTPushResult {
        if let payload = TurboPTTPushPayload(pushPayload: pushPayload) {
            return handleIncomingPush(channelUUID: channelUUID, payload: payload)
        }
        let fallbackPayload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: pushPayload["channelId"] as? String,
            activeSpeaker: pushPayload["activeSpeaker"] as? String ?? "Remote",
            activeSpeakerDisplayName: pushPayload["activeSpeakerDisplayName"] as? String,
            senderUserId: pushPayload["senderUserId"] as? String,
            senderDeviceId: pushPayload["senderDeviceId"] as? String
        )
        return handleIncomingPush(channelUUID: channelUUID, payload: fallbackPayload)
    }

    func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        callbacks.willRequestRestoredChannelDescriptor(channelUUID)
        callbacks.restoredChannel(channelUUID)
        return callbacks.descriptorForRestoredChannel(channelUUID)
    }
}

@MainActor
final class ApplePTTSystemClient: PTTSystemClientProtocol {
    private var manager: PTChannelManager?
    private var adapter: ApplePTTSystemClientAdapter?

    var isReady: Bool {
        manager != nil
    }

    let modeDescription: String = "apple"

    func configure(callbacks: PTTSystemClientCallbacks) async throws {
        guard manager == nil else { return }
        let adapter = ApplePTTSystemClientAdapter(callbacks: callbacks)
        manager = try await PTChannelManager.channelManager(
            delegate: adapter,
            restorationDelegate: adapter
        )
        self.adapter = adapter
    }

    func joinChannel(channelUUID: UUID, name: String) throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        let descriptor = PTChannelDescriptor(name: name, image: nil)
        manager.requestJoinChannel(channelUUID: channelUUID, descriptor: descriptor)
    }

    func leaveChannel(channelUUID: UUID) throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        manager.leaveChannel(channelUUID: channelUUID)
    }

    func beginTransmitting(channelUUID: UUID) throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        manager.requestBeginTransmitting(channelUUID: channelUUID)
    }

    func stopTransmitting(channelUUID: UUID) throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        manager.stopTransmitting(channelUUID: channelUUID)
    }

    func setTransmissionMode(_ mode: PTTransmissionMode, channelUUID: UUID) async throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.setTransmissionMode(mode, channelUUID: channelUUID) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func setActiveRemoteParticipant(name: String?, channelUUID: UUID) async throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // TODO: Populate the participant image from a locally cached contact
            // avatar once we persist and restore that metadata on device.
            let participant = name.map { PTParticipant(name: $0, image: nil) }
            manager.setActiveRemoteParticipant(participant, channelUUID: channelUUID) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func setAccessoryButtonEventsEnabled(_ enabled: Bool, channelUUID: UUID) async throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.setAccessoryButtonEventsEnabled(enabled, channelUUID: channelUUID) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func setServiceStatus(_ status: PTServiceStatus, channelUUID: UUID) async throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.setServiceStatus(status, channelUUID: channelUUID) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func updateChannelDescriptor(name: String, channelUUID: UUID) async throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        // TODO: Persist and restore per-channel images so system UI can show a
        // stable channel icon instead of the current text-only descriptor.
        let descriptor = PTChannelDescriptor(name: name, image: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.setChannelDescriptor(descriptor, channelUUID: channelUUID) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

@MainActor
final class SimulatorPTTSystemClient: PTTSystemClientProtocol {
    private var callbacks: PTTSystemClientCallbacks?
    private var activeChannelUUID: UUID?
    private var isTransmitting: Bool = false
    private var ephemeralTokenVersion: Int = 0
    private let audioSession = AVAudioSession.sharedInstance()

    var isReady: Bool {
        callbacks != nil
    }

    let modeDescription: String = "simulator"

    func configure(callbacks: PTTSystemClientCallbacks) async throws {
        guard self.callbacks == nil else { return }
        self.callbacks = callbacks
    }

    func joinChannel(channelUUID: UUID, name _: String) throws {
        guard let callbacks else { throw PTTSystemClientError.notReady }
        if let activeChannelUUID, activeChannelUUID != channelUUID {
            let error = NSError(domain: PTChannelErrorDomain, code: 2)
            Task { @MainActor in
                callbacks.failedToJoinChannel(channelUUID, error)
            }
            return
        }
        activeChannelUUID = channelUUID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            callbacks.didJoinChannel(channelUUID, "simulator")
            ephemeralTokenVersion += 1
            let tokenSeed = "\(channelUUID.uuidString)-\(ephemeralTokenVersion)"
            if let tokenData = tokenSeed.data(using: .utf8) {
                try? await Task.sleep(nanoseconds: 20_000_000)
                callbacks.receivedEphemeralPushToken(tokenData)
            }
        }
    }

    func leaveChannel(channelUUID: UUID) throws {
        guard let callbacks else { throw PTTSystemClientError.notReady }
        guard activeChannelUUID == channelUUID else {
            let error = NSError(domain: PTChannelErrorDomain, code: 1)
            Task { @MainActor in
                callbacks.failedToLeaveChannel(channelUUID, error)
            }
            return
        }
        activeChannelUUID = nil
        isTransmitting = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            callbacks.didLeaveChannel(channelUUID, .simulator)
        }
    }

    func beginTransmitting(channelUUID: UUID) throws {
        guard let callbacks else { throw PTTSystemClientError.notReady }
        guard activeChannelUUID == channelUUID else {
            let error = NSError(domain: PTChannelErrorDomain, code: 1)
            Task { @MainActor in
                callbacks.failedToBeginTransmitting(channelUUID, error)
            }
            return
        }
        isTransmitting = true
        Task { @MainActor in
            try? audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: MediaSessionAudioPolicy.routeCapableOptions
            )
            callbacks.didBeginTransmitting(channelUUID, "simulator")
            callbacks.didActivateAudioSession(audioSession)
        }
    }

    func stopTransmitting(channelUUID: UUID) throws {
        guard let callbacks else { throw PTTSystemClientError.notReady }
        guard activeChannelUUID == channelUUID, isTransmitting else {
            let error = NSError(domain: PTChannelErrorDomain, code: 5)
            Task { @MainActor in
                callbacks.failedToStopTransmitting(channelUUID, error)
            }
            return
        }
        isTransmitting = false
        Task { @MainActor in
            callbacks.didEndTransmitting(channelUUID, "simulator")
            callbacks.didDeactivateAudioSession(audioSession)
        }
    }

    func setTransmissionMode(_ mode: PTTransmissionMode, channelUUID _: UUID) async throws {}

    func setActiveRemoteParticipant(name _: String?, channelUUID _: UUID) async throws {}

    func setAccessoryButtonEventsEnabled(_ enabled: Bool, channelUUID _: UUID) async throws {}

    func setServiceStatus(_ status: PTServiceStatus, channelUUID _: UUID) async throws {}

    func updateChannelDescriptor(name _: String, channelUUID _: UUID) async throws {}
}

@MainActor
func makeDefaultPTTSystemClient() -> any PTTSystemClientProtocol {
    #if targetEnvironment(simulator)
    return SimulatorPTTSystemClient()
    #else
    return ApplePTTSystemClient()
    #endif
}
