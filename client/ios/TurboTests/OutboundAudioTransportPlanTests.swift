import Testing

@testable import BeepBeep

struct OutboundAudioTransportPlanTests {
    @Test func verifiedDirectQuicIsExclusivePrimaryLane() {
        let plan = OutboundAudioTransportPlan.dynamic(
            directAvailable: true,
            directVerified: true,
            standbyRelayAvailable: true,
            standbyRelayIsTCPContinuity: false,
            legacyPCMRequiresWebSocketRelay: false
        )

        #expect(plan.attempts == [
            .directQuic(.verifiedPrimary),
        ])
        #expect(!plan.startsWithStandbyRelayBeforeUnverifiedDirect)
        #expect(!plan.attemptsStandbyRelayAfterUnverifiedDirect)
    }

    @Test func unverifiedDirectQuicIsShadowAfterStandbyPacketRelay() {
        let plan = OutboundAudioTransportPlan.dynamic(
            directAvailable: true,
            directVerified: false,
            standbyRelayAvailable: true,
            standbyRelayIsTCPContinuity: false,
            legacyPCMRequiresWebSocketRelay: false
        )

        #expect(plan.attempts == [
            .mediaRelay(.primaryBeforeUnverifiedDirect),
            .directQuic(.shadowAfterStandbyRelay),
            .relayWebSocketFallback,
        ])
        #expect(plan.startsWithStandbyRelayBeforeUnverifiedDirect)
        #expect(plan.attemptsDirectQuic)
    }

    @Test func unverifiedDirectQuicWithoutPacketRelayFallsBackThroughWebSocket() {
        let plan = OutboundAudioTransportPlan.dynamic(
            directAvailable: true,
            directVerified: false,
            standbyRelayAvailable: false,
            standbyRelayIsTCPContinuity: false,
            legacyPCMRequiresWebSocketRelay: false
        )

        #expect(plan.attempts == [
            .directQuic(.unverifiedPrimary),
            .relayWebSocketFallback,
        ])
    }

    @Test func tcpContinuityRelayDoesNotBecomeShadowPacketRelay() {
        let plan = OutboundAudioTransportPlan.dynamic(
            directAvailable: true,
            directVerified: false,
            standbyRelayAvailable: true,
            standbyRelayIsTCPContinuity: true,
            legacyPCMRequiresWebSocketRelay: false
        )

        #expect(plan.attempts == [
            .directQuic(.unverifiedPrimary),
            .mediaRelay(.tcpContinuity),
            .relayWebSocketFallback,
        ])
        #expect(!plan.startsWithStandbyRelayBeforeUnverifiedDirect)
        #expect(plan.usesTcpContinuityRelay)
    }

    @Test func legacyPCMBypassesPacketRelayToOrderedFallback() {
        let plan = OutboundAudioTransportPlan.dynamic(
            directAvailable: false,
            directVerified: false,
            standbyRelayAvailable: true,
            standbyRelayIsTCPContinuity: false,
            legacyPCMRequiresWebSocketRelay: true
        )

        #expect(plan.attempts == [
            .relayWebSocketFallback,
        ])
    }

    @Test func mediaRelayWithoutDirectIsPrimaryFallbackBeforeWebSocket() {
        let plan = OutboundAudioTransportPlan.dynamic(
            directAvailable: false,
            directVerified: false,
            standbyRelayAvailable: true,
            standbyRelayIsTCPContinuity: false,
            legacyPCMRequiresWebSocketRelay: false
        )

        #expect(plan.attempts == [
            .mediaRelay(.primary),
            .relayWebSocketFallback,
        ])
    }
}
