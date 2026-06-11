import Testing

@testable import BeepBeep

struct OutboundAudioTransportPlanTests {
    @Test func verifiedDirectQuicKeepsPacketRelayRescueWhenStandbyIsReady() throws {
        let plan = try #require(OutboundAudioTransportPlan.dynamic(
            directAvailable: true,
            directVerified: true,
            standbyRelayAvailable: true,
            standbyRelayIsTCPContinuity: false,
            legacyPCMBypassesPacketRelay: false
        ))

        #expect(plan.attempts == [
            .directQuic(.verifiedPrimary),
            .mediaRelay(.rescueAfterPrimaryFailure),
        ])
        #expect(plan.hasSequentialMediaRelayRescue)
    }

    @Test func verifiedDirectQuicIsExclusivePrimaryLaneWithoutPacketRelayStandby() throws {
        let plan = try #require(OutboundAudioTransportPlan.dynamic(
            directAvailable: true,
            directVerified: true,
            standbyRelayAvailable: false,
            standbyRelayIsTCPContinuity: false,
            legacyPCMBypassesPacketRelay: false
        ))

        #expect(plan.attempts == [
            .directQuic(.verifiedPrimary),
        ])
        #expect(!plan.hasSequentialMediaRelayRescue)
    }

    @Test func unverifiedDirectQuicUsesPacketRelayPrimaryUntilPlaybackProof() throws {
        let plan = try #require(OutboundAudioTransportPlan.dynamic(
            directAvailable: true,
            directVerified: false,
            standbyRelayAvailable: true,
            standbyRelayIsTCPContinuity: false,
            legacyPCMBypassesPacketRelay: false
        ))

        #expect(plan.attempts == [
            .mediaRelay(.primary),
        ])
        #expect(!plan.hasSequentialMediaRelayRescue)
        #expect(!plan.attemptsDirectQuic)
    }

    @Test func lanePromotedDirectQuicKeepsPacketRelayContinuityUntilPlaybackProof() throws {
        let plan = try #require(OutboundAudioTransportPlan.dynamic(
            directAvailable: true,
            directVerified: false,
            directPromotionVerified: true,
            standbyRelayAvailable: true,
            standbyRelayIsTCPContinuity: false,
            legacyPCMBypassesPacketRelay: false,
            allowUnverifiedDirectPrimary: false
        ))

        #expect(plan.attempts == [
            .directQuic(.unverifiedPrimary),
            .mediaRelay(.continuityWhileDirectUnverified),
        ])
        #expect(plan.attemptsDirectQuic)
        #expect(plan.hasContinuityRelayForUnverifiedDirect)
    }

    @Test func unverifiedDirectQuicWithoutRequiredRelayCanBeDirectOnlyPrimary() throws {
        let plan = try #require(OutboundAudioTransportPlan.dynamic(
            directAvailable: true,
            directVerified: false,
            standbyRelayAvailable: false,
            standbyRelayIsTCPContinuity: false,
            legacyPCMBypassesPacketRelay: false,
            allowUnverifiedDirectPrimary: true
        ))

        #expect(plan.attempts == [
            .directQuic(.unverifiedPrimary),
        ])
    }

    @Test func unverifiedDirectQuicWithRequiredRelayHasNoPrimaryWhenRelayUnavailable() {
        let plan = OutboundAudioTransportPlan.dynamic(
            directAvailable: true,
            directVerified: false,
            standbyRelayAvailable: false,
            standbyRelayIsTCPContinuity: false,
            legacyPCMBypassesPacketRelay: false,
            allowUnverifiedDirectPrimary: false
        )

        #expect(plan == nil)
    }

    @Test func tcpContinuityRelayIsPrimaryUntilDirectPlaybackProof() throws {
        let plan = try #require(OutboundAudioTransportPlan.dynamic(
            directAvailable: true,
            directVerified: false,
            standbyRelayAvailable: true,
            standbyRelayIsTCPContinuity: true,
            legacyPCMBypassesPacketRelay: false
        ))

        #expect(plan.attempts == [
            .mediaRelay(.tcpContinuity),
        ])
        #expect(plan.usesTcpContinuityRelay)
    }

    @Test func dynamicPlanNeverExceedsPrimaryPlusOneSequentialRescue() {
        let combinations: [(Bool, Bool, Bool, Bool, Bool)] = [
            (false, false, false, false, false),
            (false, false, true, false, false),
            (false, false, true, true, false),
            (true, false, false, false, false),
            (true, false, true, false, false),
            (true, false, true, true, false),
            (true, true, true, false, false),
            (true, true, true, true, false),
            (true, false, true, false, true),
        ]

        for combination in combinations {
            let plan = OutboundAudioTransportPlan.dynamic(
                directAvailable: combination.0,
                directVerified: combination.1,
                standbyRelayAvailable: combination.2,
                standbyRelayIsTCPContinuity: combination.3,
                legacyPCMBypassesPacketRelay: combination.4
            )
            #expect((plan?.attempts.count ?? 0) <= 2)
        }
    }

    @Test func legacyPCMHasNoLivePacketFallback() {
        let plan = OutboundAudioTransportPlan.dynamic(
            directAvailable: false,
            directVerified: false,
            standbyRelayAvailable: true,
            standbyRelayIsTCPContinuity: false,
            legacyPCMBypassesPacketRelay: true
        )

        #expect(plan == nil)
    }

    @Test func mediaRelayWithoutDirectIsPrimaryWithNoRuntimeMediaFallback() throws {
        let plan = try #require(OutboundAudioTransportPlan.dynamic(
            directAvailable: false,
            directVerified: false,
            standbyRelayAvailable: true,
            standbyRelayIsTCPContinuity: false,
            legacyPCMBypassesPacketRelay: false
        ))

        #expect(plan.attempts == [
            .mediaRelay(.primary),
        ])
    }
}
