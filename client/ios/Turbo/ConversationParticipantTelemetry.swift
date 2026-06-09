import AVFAudio
import Foundation
import Network

enum ConversationNetworkInterface: String, Codable, Equatable {
    case wifi
    case cellular
    case wired
    case other
    case unavailable
    case unknown

    var displayName: String? {
        switch self {
        case .wifi:
            return "Wi-Fi"
        case .cellular:
            return "Cellular"
        case .wired:
            return "Wired"
        case .other:
            return "Network"
        case .unavailable:
            return "Offline"
        case .unknown:
            return nil
        }
    }

    nonisolated static func from(path: NWPath) -> ConversationNetworkInterface {
        guard path.status == .satisfied else { return .unavailable }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.other) || path.usesInterfaceType(.loopback) { return .other }
        return .unknown
    }
}

struct ConversationParticipantTelemetry: Codable, Equatable {
    struct Audio: Codable, Equatable {
        static let volumeOffMaximumPercent = 1
        static let veryLowVolumeMaximumPercent = 5

        let routeName: String
        let volumePercent: Int

        var isVolumeOff: Bool {
            volumePercent <= Self.volumeOffMaximumPercent
        }

        var isVolumeVeryLow: Bool {
            volumePercent <= Self.veryLowVolumeMaximumPercent
        }

        static func current(audioSession: AVAudioSession = .sharedInstance()) -> Audio {
            let outputs = audioSession.currentRoute.outputs
            let routeName = routeName(from: outputs)
            let volume = min(max(Double(audioSession.outputVolume), 0), 1)
            return Audio(
                routeName: routeName,
                volumePercent: Int((volume * 100).rounded())
            )
        }

        private static func routeName(from outputs: [AVAudioSessionPortDescription]) -> String {
            if let bluetooth = outputs.first(where: { $0.portType.isBluetoothOutput }) {
                return bluetooth.portName.isEmpty ? "Bluetooth" : bluetooth.portName
            }
            if let headphones = outputs.first(where: { $0.portType.isHeadphoneOutput }) {
                return headphones.portName.isEmpty ? "Headphones" : headphones.portName
            }
            if outputs.contains(where: { $0.portType == .builtInSpeaker }) {
                return "Speaker"
            }
            if outputs.contains(where: { $0.portType == .builtInReceiver }) {
                return "Earpiece"
            }
            if let airPlay = outputs.first(where: { $0.portType == .airPlay }) {
                return airPlay.portName.isEmpty ? "AirPlay" : airPlay.portName
            }
            return "Audio"
        }
    }

    struct Connection: Codable, Equatable {
        let interface: ConversationNetworkInterface

        var displayName: String? {
            interface.displayName
        }
    }

    let audio: Audio?
    let connection: Connection?

    var hasVisibleContext: Bool {
        audio != nil || connection?.displayName != nil
    }

    static func current(
        includeAudio: Bool,
        networkInterface: ConversationNetworkInterface
    ) -> ConversationParticipantTelemetry {
        ConversationParticipantTelemetry(
            audio: includeAudio ? Audio.current() : nil,
            connection: networkInterface.displayName.map { _ in Connection(interface: networkInterface) }
        )
    }
}

struct ReceiverAudioReadinessSignalPayload: Codable, Equatable {
    let version: Int
    let reason: ReceiverAudioReadinessReason
    let telemetry: ConversationParticipantTelemetry?
    let mediaCapabilities: VoiceMediaCapabilities?

    init(
        version: Int = 1,
        reason: ReceiverAudioReadinessReason,
        telemetry: ConversationParticipantTelemetry?,
        mediaCapabilities: VoiceMediaCapabilities? = .local
    ) {
        self.version = version
        self.reason = reason
        self.telemetry = telemetry
        self.mediaCapabilities = mediaCapabilities
    }

    static func decode(from payload: String) -> ReceiverAudioReadinessSignalPayload {
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ReceiverAudioReadinessSignalPayload.self, from: data) else {
            return ReceiverAudioReadinessSignalPayload(
                reason: ReceiverAudioReadinessReason(wireValue: payload),
                telemetry: nil,
                mediaCapabilities: nil
            )
        }
        return decoded
    }

    func wirePayload() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let encoded = String(data: data, encoding: .utf8) else {
            return reason.wireValue
        }
        return encoded
    }
}

private extension AVAudioSession.Port {
    var isBluetoothOutput: Bool {
        self == .bluetoothA2DP || self == .bluetoothHFP || self == .bluetoothLE
    }

    var isHeadphoneOutput: Bool {
        self == .headphones || self == .usbAudio || self == .carAudio
    }
}
