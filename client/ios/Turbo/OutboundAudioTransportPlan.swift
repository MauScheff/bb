import Foundation

nonisolated enum OutboundAudioTransportLane: String, Equatable, Sendable {
    case directQuic = "direct-quic"
    case mediaRelayPacket = "media-relay-packet"
    case mediaRelayTcp = "media-relay-tcp"
    case relayWebSocket = "relay-websocket"
}

nonisolated enum OutboundAudioDirectQuicRole: String, Equatable, Sendable {
    case verifiedPrimary
    case unverifiedPrimary
}

nonisolated enum OutboundAudioMediaRelayRole: String, Equatable, Sendable {
    case primary
    case standbyAfterUnverifiedDirect
    case tcpContinuity
}

nonisolated enum OutboundAudioTransportAttempt: Equatable, Sendable {
    case directQuic(OutboundAudioDirectQuicRole)
    case mediaRelay(OutboundAudioMediaRelayRole)
    case relayWebSocketFallback

    var lane: OutboundAudioTransportLane {
        switch self {
        case .directQuic:
            return .directQuic
        case .mediaRelay(let role):
            switch role {
            case .primary, .standbyAfterUnverifiedDirect:
                return .mediaRelayPacket
            case .tcpContinuity:
                return .mediaRelayTcp
            }
        case .relayWebSocketFallback:
            return .relayWebSocket
        }
    }
}

nonisolated struct OutboundAudioTransportPlan: Equatable, Sendable {
    let attempts: [OutboundAudioTransportAttempt]

    var attemptsDirectQuic: Bool {
        attempts.contains {
            if case .directQuic = $0 {
                return true
            }
            return false
        }
    }

    var attemptsStandbyRelayAfterUnverifiedDirect: Bool {
        attempts.contains(.mediaRelay(.standbyAfterUnverifiedDirect))
    }

    var usesTcpContinuityRelay: Bool {
        attempts.contains(.mediaRelay(.tcpContinuity))
    }

    static func dynamic(
        directAvailable: Bool,
        directVerified: Bool,
        standbyRelayAvailable: Bool,
        standbyRelayIsTCPContinuity: Bool,
        legacyPCMRequiresWebSocketRelay: Bool
    ) -> OutboundAudioTransportPlan {
        if directAvailable && directVerified {
            return OutboundAudioTransportPlan(attempts: [
                .directQuic(.verifiedPrimary),
            ])
        }

        if directAvailable,
           standbyRelayAvailable,
           !standbyRelayIsTCPContinuity,
           !legacyPCMRequiresWebSocketRelay {
            return OutboundAudioTransportPlan(attempts: [
                .directQuic(.unverifiedPrimary),
                .mediaRelay(.standbyAfterUnverifiedDirect),
                .relayWebSocketFallback,
            ])
        }

        var attempts: [OutboundAudioTransportAttempt] = []
        if directAvailable {
            attempts.append(.directQuic(.unverifiedPrimary))
        }
        if standbyRelayAvailable, !legacyPCMRequiresWebSocketRelay {
            attempts.append(
                standbyRelayIsTCPContinuity
                ? .mediaRelay(.tcpContinuity)
                : directAvailable
                    ? .mediaRelay(.standbyAfterUnverifiedDirect)
                    : .mediaRelay(.primary)
            )
        }
        attempts.append(.relayWebSocketFallback)
        return OutboundAudioTransportPlan(attempts: attempts)
    }
}
