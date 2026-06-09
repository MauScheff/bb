import Foundation

nonisolated enum OutboundAudioTransportLane: String, Equatable, Sendable {
    case directQuic = "direct-quic"
    case mediaRelayPacket = "media-relay-packet"
    case mediaRelayTcp = "media-relay-tcp"
}

nonisolated enum OutboundAudioDirectQuicRole: String, Equatable, Sendable {
    case verifiedPrimary
    case unverifiedPrimary
}

nonisolated enum OutboundAudioMediaRelayRole: String, Equatable, Sendable {
    case primary
    case rescueAfterPrimaryFailure
    case tcpContinuity
}

nonisolated enum OutboundAudioTransportAttempt: Equatable, Sendable {
    case directQuic(OutboundAudioDirectQuicRole)
    case mediaRelay(OutboundAudioMediaRelayRole)

    var lane: OutboundAudioTransportLane {
        switch self {
        case .directQuic:
            return .directQuic
        case .mediaRelay(let role):
            switch role {
            case .primary, .rescueAfterPrimaryFailure:
                return .mediaRelayPacket
            case .tcpContinuity:
                return .mediaRelayTcp
            }
        }
    }
}

nonisolated struct OutboundAudioTransportPlan: Equatable, Sendable {
    let primary: OutboundAudioTransportAttempt
    let rescue: OutboundAudioTransportAttempt?

    var attempts: [OutboundAudioTransportAttempt] {
        if let rescue {
            return [primary, rescue]
        }
        return [primary]
    }

    var attemptsDirectQuic: Bool {
        attempts.contains {
            if case .directQuic = $0 {
                return true
            }
            return false
        }
    }

    var hasSequentialMediaRelayRescue: Bool {
        rescue == .mediaRelay(.rescueAfterPrimaryFailure)
    }

    var usesPrimaryMediaRelay: Bool {
        primary == .mediaRelay(.primary)
    }

    var usesTcpContinuityRelay: Bool {
        primary == .mediaRelay(.tcpContinuity)
            || rescue == .mediaRelay(.tcpContinuity)
    }

    static func dynamic(
        directAvailable: Bool,
        directVerified: Bool,
        standbyRelayAvailable: Bool,
        standbyRelayIsTCPContinuity: Bool,
        legacyPCMBypassesPacketRelay: Bool
    ) -> OutboundAudioTransportPlan? {
        if directAvailable && directVerified {
            return OutboundAudioTransportPlan(
                primary: .directQuic(.verifiedPrimary),
                rescue: nil
            )
        }

        if directAvailable {
            let rescue: OutboundAudioTransportAttempt?
            if standbyRelayAvailable, !legacyPCMBypassesPacketRelay {
                rescue = standbyRelayIsTCPContinuity
                    ? .mediaRelay(.tcpContinuity)
                    : .mediaRelay(.rescueAfterPrimaryFailure)
            } else {
                rescue = nil
            }
            return OutboundAudioTransportPlan(
                primary: .directQuic(.unverifiedPrimary),
                rescue: rescue
            )
        }

        if standbyRelayAvailable, !legacyPCMBypassesPacketRelay {
            return OutboundAudioTransportPlan(
                primary: standbyRelayIsTCPContinuity
                    ? .mediaRelay(.tcpContinuity)
                    : .mediaRelay(.primary),
                rescue: nil
            )
        }

        return nil
    }
}
