import SwiftUI
import UIKit

enum TurboCallScreenBackgroundAnimationFlag {
    static let storageKey = "TurboCallScreenBackgroundAnimationsEnabled"
    static let launchArgument = "-TurboCallScreenBackgroundAnimationsEnabled"
    static let environmentKey = "TURBO_CALL_SCREEN_BACKGROUND_ANIMATIONS_ENABLED"

    static func isEnabled(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard
    ) -> Bool {
        isEnabled(
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            defaults: defaults
        )
    }

    static func isEnabled(
        arguments: [String],
        environment: [String: String],
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let launchArgumentValue = launchArgumentValue(launchArgument, in: arguments),
           let parsed = parseBoolean(launchArgumentValue) {
            return parsed
        }
        if arguments.contains(launchArgument) {
            return true
        }
        if let environmentValue = environment[environmentKey],
           let parsed = parseBoolean(environmentValue) {
            return parsed
        }
        guard defaults.object(forKey: storageKey) != nil else { return false }
        return defaults.bool(forKey: storageKey)
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: storageKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    private static func launchArgumentValue(_ launchArgument: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func parseBoolean(_ rawValue: String) -> Bool? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

enum TurboCallScreenStatisticsVisibilityFlag {
    static func isEnabled(
        bundle: Bundle = .main,
        appStoreReceiptURL: URL? = nil,
        appStoreReceiptURLProvider: (Bundle) -> URL? = { $0.appStoreReceiptURL }
    ) -> Bool {
        #if DEBUG
        true
        #else
        isEnabledForProductionLikeBuild(
            bundle: bundle,
            appStoreReceiptURL: appStoreReceiptURL,
            appStoreReceiptURLProvider: appStoreReceiptURLProvider
        )
        #endif
    }

    static func isEnabledForProductionLikeBuild(
        bundle: Bundle = .main,
        appStoreReceiptURL: URL? = nil,
        appStoreReceiptURLProvider: (Bundle) -> URL? = { $0.appStoreReceiptURL }
    ) -> Bool {
        isTestFlightReceipt(
            bundle: bundle,
            appStoreReceiptURL: appStoreReceiptURL ?? appStoreReceiptURLProvider(bundle)
        )
    }

    static func isTestFlightReceipt(
        bundle: Bundle = .main,
        appStoreReceiptURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        if bundle.object(forInfoDictionaryKey: "TurboForceCallScreenStatistics") as? Bool == true {
            return true
        }
        if let appStoreReceiptURL {
            return appStoreReceiptURL.lastPathComponent == "sandboxReceipt"
        }
        let sandboxReceiptURL = bundle.bundleURL
            .appendingPathComponent("StoreKit", isDirectory: true)
            .appendingPathComponent("sandboxReceipt", isDirectory: false)
        return fileManager.fileExists(atPath: sandboxReceiptURL.path)
    }
}

private struct HatTextureTuning: Equatable {
    var zoom: CGFloat = 1.81
    var opacity: Double = 0.98
    var lineWidth: CGFloat = 0.55
    var backgroundHue: Double = 0.24
    var backgroundSaturation: Double = 0.12
    var backgroundBrightness: Double = 0.003
}

private struct TurboCallCloudTuning: Equatable {
    var patchCount: Double = 32
    var opacity: Double = 1.52
    var depthContrast: Double = 0.84
    var colorAmount: Double = 1.16
    var hueSpread: Double = 1.10
    var blur: Double = 0.063
    var minWidth: Double = 0.40
    var maxWidth: Double = 1.42
    var minHeight: Double = 0.14
    var maxHeight: Double = 0.30
    var overallDim: Double = 0.28
    var motionAmount: Double = 0.135
    var motionSpeed: Double = 2.62
    var idleMotionAmount: Double = 0.22
    var breathAmount: Double = 0.020
    var talkBreathBoost: Double = 0.20
    var talkBaseline: Double = 0.08
    var talkSensitivity: Double = 1.85
    var animationMode: TurboCallCloudAnimationMode = .reaction
    var buttonAnchorsEnabled: Bool = true
}

private enum TurboCallCloudAnimationMode: String, CaseIterable {
    case drift
    case reaction

    var label: String {
        switch self {
        case .drift:
            return "Drift"
        case .reaction:
            return "Reaction"
        }
    }

    var morphsCellShape: Bool {
        switch self {
        case .drift:
            return false
        case .reaction:
            return true
        }
    }

    var usesFlowColorShift: Bool {
        switch self {
        case .drift:
            return false
        case .reaction:
            return true
        }
    }

    var usesAnchorVoid: Bool {
        switch self {
        case .drift:
            return false
        case .reaction:
            return true
        }
    }
}

nonisolated enum CallAudioEncryptionStatus: Equatable {
    case endToEndEncrypted
    case unavailable

    var symbolName: String {
        switch self {
        case .endToEndEncrypted:
            return "lock.fill"
        case .unavailable:
            return "lock.open.fill"
        }
    }

    var text: String {
        switch self {
        case .endToEndEncrypted:
            return "End-to-end encrypted"
        case .unavailable:
            return "End-to-end encryption unavailable"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .endToEndEncrypted:
            return "Audio is end-to-end encrypted"
        case .unavailable:
            return "Audio is not end-to-end encrypted"
        }
    }
}

private struct TurboCallCloudMotion: Equatable {
    enum Phase: String {
        case connecting
        case idleReady
        case conversationActive
    }

    let phase: Phase
    let talkEnergy: Double

    var label: String {
        switch phase {
        case .connecting:
            return "connecting"
        case .idleReady:
            return "idle"
        case .conversationActive:
            return "active"
        }
    }

    var isTimelineActive: Bool {
        true
    }

    var cloudLayerOpacity: Double {
        switch phase {
        case .connecting:
            return 1.0
        case .idleReady:
            return 1.0
        case .conversationActive:
            return 0.18
        }
    }

    var dimBoost: Double {
        switch phase {
        case .connecting:
            return 0
        case .idleReady:
            return 0.07
        case .conversationActive:
            return 0.50
        }
    }

    func motionAmountMultiplier(tuning: TurboCallCloudTuning) -> Double {
        switch phase {
        case .connecting:
            return 1.0
        case .idleReady:
            return 1.0
        case .conversationActive:
            return 0.22
        }
    }

    func cellMorphMultiplier(tuning: TurboCallCloudTuning) -> Double {
        switch phase {
        case .connecting:
            return 1.0
        case .idleReady:
            return 1.0
        case .conversationActive:
            return 0.10
        }
    }

    func breathAmount(tuning: TurboCallCloudTuning) -> Double {
        switch phase {
        case .connecting:
            return tuning.breathAmount * 0.55
        case .idleReady:
            return tuning.breathAmount * 0.55
        case .conversationActive:
            return tuning.breathAmount * 0.16
        }
    }

    func breathSpeed(tuning: TurboCallCloudTuning) -> Double {
        switch phase {
        case .connecting:
            return tuning.motionSpeed * 0.30
        case .idleReady:
            return tuning.motionSpeed * 0.11
        case .conversationActive:
            return tuning.motionSpeed * 0.12
        }
    }

    func motionSpeedMultiplier(tuning _: TurboCallCloudTuning) -> Double {
        switch phase {
        case .connecting:
            return 1.0
        case .idleReady:
            return 0.36
        case .conversationActive:
            return 0.20
        }
    }

    func colorAmountMultiplier(tuning _: TurboCallCloudTuning) -> Double {
        switch phase {
        case .connecting, .idleReady:
            return 1.0
        case .conversationActive:
            return 0.34
        }
    }

    func hueSpreadMultiplier(tuning _: TurboCallCloudTuning) -> Double {
        switch phase {
        case .connecting, .idleReady:
            return 1.0
        case .conversationActive:
            return 0.42
        }
    }

    var animationMode: TurboCallCloudAnimationMode {
        switch phase {
        case .connecting, .idleReady, .conversationActive:
            return .reaction
        }
    }

    func resolved(tuning: TurboCallCloudTuning) -> TurboCallCloudResolvedMotion {
        TurboCallCloudResolvedMotion(
            phase: phase,
            talkEnergy: talkEnergy,
            animationMode: animationMode,
            animationModeOpacity: 1,
            secondaryAnimationMode: nil,
            secondaryAnimationModeOpacity: 0,
            cloudLayerOpacity: cloudLayerOpacity,
            dimBoost: dimBoost,
            motionAmountMultiplier: motionAmountMultiplier(tuning: tuning),
            cellMorphMultiplier: cellMorphMultiplier(tuning: tuning),
            breathAmount: breathAmount(tuning: tuning),
            breathSpeed: breathSpeed(tuning: tuning),
            motionSpeedMultiplier: motionSpeedMultiplier(tuning: tuning),
            colorAmountMultiplier: colorAmountMultiplier(tuning: tuning),
            hueSpreadMultiplier: hueSpreadMultiplier(tuning: tuning)
        )
    }
}

private struct TurboCallCloudResolvedMotion: Equatable {
    let phase: TurboCallCloudMotion.Phase
    let talkEnergy: Double
    let animationMode: TurboCallCloudAnimationMode
    let animationModeOpacity: Double
    let secondaryAnimationMode: TurboCallCloudAnimationMode?
    let secondaryAnimationModeOpacity: Double
    let cloudLayerOpacity: Double
    let dimBoost: Double
    let motionAmountMultiplier: Double
    let cellMorphMultiplier: Double
    let breathAmount: Double
    let breathSpeed: Double
    let motionSpeedMultiplier: Double
    let colorAmountMultiplier: Double
    let hueSpreadMultiplier: Double

    static func interpolated(
        from start: TurboCallCloudResolvedMotion,
        to end: TurboCallCloudResolvedMotion,
        progress: Double
    ) -> TurboCallCloudResolvedMotion {
        let progress = max(0, min(1, progress))
        let modesDiffer = start.animationMode != end.animationMode
        return TurboCallCloudResolvedMotion(
            phase: progress < 0.5 ? start.phase : end.phase,
            talkEnergy: interpolate(start.talkEnergy, end.talkEnergy, progress),
            animationMode: end.animationMode,
            animationModeOpacity: modesDiffer ? progress : 1,
            secondaryAnimationMode: modesDiffer ? start.animationMode : nil,
            secondaryAnimationModeOpacity: modesDiffer ? 1 - progress : 0,
            cloudLayerOpacity: interpolate(start.cloudLayerOpacity, end.cloudLayerOpacity, progress),
            dimBoost: interpolate(start.dimBoost, end.dimBoost, progress),
            motionAmountMultiplier: interpolate(start.motionAmountMultiplier, end.motionAmountMultiplier, progress),
            cellMorphMultiplier: interpolate(start.cellMorphMultiplier, end.cellMorphMultiplier, progress),
            breathAmount: interpolate(start.breathAmount, end.breathAmount, progress),
            breathSpeed: interpolate(start.breathSpeed, end.breathSpeed, progress),
            motionSpeedMultiplier: interpolate(start.motionSpeedMultiplier, end.motionSpeedMultiplier, progress),
            colorAmountMultiplier: interpolate(start.colorAmountMultiplier, end.colorAmountMultiplier, progress),
            hueSpreadMultiplier: interpolate(start.hueSpreadMultiplier, end.hueSpreadMultiplier, progress)
        )
    }

    private static func interpolate(_ start: Double, _ end: Double, _ progress: Double) -> Double {
        start + (end - start) * progress
    }
}

struct TurboCallPrototypeView: View {
    let contact: Contact
    let selectedConversationState: SelectedConversationState
    let primaryAction: ConversationPrimaryAction
    let isTransmitPressActive: Bool
    let isPTTAudioSessionActive: Bool
    let mediaConnectionState: MediaConnectionState
    let mediaSessionContactID: UUID?
    let transportPathState: MediaTransportPathState?
    let audioEncryptionStatus: CallAudioEncryptionStatus
    let localAudioLevel: Double
    let localTelemetry: ConversationParticipantTelemetry?
    let remoteParticipantTelemetry: ConversationParticipantTelemetry?
    var backgroundAnimationsEnabled: Bool = TurboCallScreenBackgroundAnimationFlag.isEnabled()
    var callStatisticsVisible: Bool = TurboCallScreenStatisticsVisibilityFlag.isEnabled()
    var requestSubject: String? = nil
    let onClose: () -> Void
    let onLeave: () -> Void
    let onJoin: () -> Void
    let onBeginTransmit: () -> Void
    let onTransmitTouchReleased: () -> Void
    let onEndTransmit: (String) -> Void

    @State private var holdToTalkGestureState = HoldToTalkGestureState()
    @State private var transmitPressBeganAt: Date?
    @State private var pendingHoldToTalkTask: Task<Void, Never>?
    @State private var holdToTalkDidBeginTransmit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let cloudTuning = TurboCallCloudTuning()
    @State private var cloudFrozenTime: TimeInterval = Date.timeIntervalSinceReferenceDate
    @State private var displayedTalkEnergy: Double = 0
    @State private var hasReachedReadyCloudMotion = false

    private enum AudioBlockerPresentation: Equatable {
        case localVolumeOff(contactName: String)
        case localVolumeVeryLow(contactName: String)
        case localVolumeLow(contactName: String)
        case remoteVolumeOff(contactName: String)
        case remoteVolumeVeryLow(contactName: String)
        case remoteVolumeLow(contactName: String)

        var title: String {
            switch self {
            case .localVolumeOff:
                return "Your volume is off"
            case .localVolumeVeryLow:
                return "Your volume is very low"
            case .localVolumeLow:
                return "Your volume is low"
            case .remoteVolumeOff(let contactName):
                return "\(contactName)’s volume is off"
            case .remoteVolumeVeryLow(let contactName):
                return "\(contactName)’s volume is very low"
            case .remoteVolumeLow(let contactName):
                return "\(contactName)’s volume is low"
            }
        }

        var message: String {
            switch self {
            case .localVolumeOff(let contactName):
                return "Turn it up to hear \(contactName)."
            case .localVolumeVeryLow(let contactName):
                return "Turn it up so you don’t miss \(contactName)."
            case .localVolumeLow(let contactName):
                return "Turn it up if \(contactName) sounds quiet."
            case .remoteVolumeOff:
                return "They need to turn it up before they can hear you."
            case .remoteVolumeVeryLow:
                return "They may miss what you say."
            case .remoteVolumeLow:
                return "They may not hear you clearly."
            }
        }

        var symbolName: String {
            switch self {
            case .localVolumeOff, .remoteVolumeOff:
                return "speaker.slash.fill"
            case .localVolumeVeryLow, .localVolumeLow, .remoteVolumeVeryLow, .remoteVolumeLow:
                return "speaker.wave.1.fill"
            }
        }

        var accessibilityLabel: String {
            "\(title). \(message)"
        }
    }

    @MainActor
    static func prewarmDefaultTexture() {
        let windowSize = UIApplication.shared.connectedScenes.compactMap { scene -> CGSize? in
            guard let windowScene = scene as? UIWindowScene else { return nil }
            return windowScene.windows.first(where: \.isKeyWindow)?.bounds.size
                ?? windowScene.windows.first?.bounds.size
        }.first
        HatTilingBackground.prewarmTexture(size: windowSize ?? CGSize(width: 393, height: 852), tuning: HatTextureTuning())
    }

    var body: some View {
        GeometryReader { proxy in
            let usesWideLayout = proxy.size.width >= 700
            let cloudMotion = cloudMotion
            let topSafePadding = Self.topChromePadding(
                geometrySafeAreaInsets: proxy.safeAreaInsets
            )

            ZStack {
                cloudCallContent(
                    usesWideLayout: usesWideLayout,
                    cloudMotion: cloudMotion,
                    topSafePadding: topSafePadding
                )
                .frame(width: proxy.size.width, height: proxy.size.height)

                if let audioBlockerPresentation {
                    audioBlockerOverlay(audioBlockerPresentation)
                        .frame(maxWidth: min(max(proxy.size.width - 56, 0), 320))
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .zIndex(20)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: audioBlockerPresentation)
        }
        .onChange(of: cloudShouldAnimate) { _, isAnimating in
            if !isAnimating {
                cloudFrozenTime = Date.timeIntervalSinceReferenceDate
            }
            #if DEBUG
            print("cloud animation state changed", "isAnimating=\(isAnimating)", "phase=\(selectedConversationState.phase)", "media=\(mediaConnectionState)", "seed=\(backgroundSeed)")
            #endif
        }
        .onAppear {
            displayedTalkEnergy = rawLocalCloudTalkEnergy
            updateReadyCloudMotionLatch()
        }
        .onChange(of: selectedConversationState.phase) { _, _ in
            updateReadyCloudMotionLatch()
        }
        .onChange(of: selectedConversationState.canTransmitNow) { _, _ in
            updateReadyCloudMotionLatch()
        }
        .onChange(of: primaryAction.isEnabled) { _, isEnabled in
            if isEnabled {
                schedulePendingHoldToTalkStartIfPossible()
            } else if !holdToTalkDidBeginTransmit {
                pendingHoldToTalkTask?.cancel()
                pendingHoldToTalkTask = nil
            }
        }
        .onChange(of: primaryAction.kind) { _, kind in
            guard kind != .holdToTalk else {
                schedulePendingHoldToTalkStartIfPossible()
                return
            }
            let didBeginTransmit = cancelPendingHoldToTalk()
            if didBeginTransmit {
                onEndTransmit("call-primary-action-changed")
            }
        }
        .onChange(of: mediaConnectionState) { _, _ in
            updateReadyCloudMotionLatch()
        }
        .onChange(of: rawLocalCloudTalkEnergy) { _, energy in
            updateDisplayedTalkEnergy(energy)
        }
        .onChange(of: isTransmitPressActive) { _, isActive in
            holdToTalkGestureState.handleMachinePressChanged(isActive: isActive)
            updateDisplayedTalkEnergy(rawLocalCloudTalkEnergy)
            if isActive {
                transmitPressBeganAt = transmitPressBeganAt ?? Date()
            } else {
                pendingHoldToTalkTask?.cancel()
                pendingHoldToTalkTask = nil
                holdToTalkDidBeginTransmit = false
                transmitPressBeganAt = nil
            }
        }
        .onChange(of: contact.id) { _, _ in
            let didBeginTransmit = cancelPendingHoldToTalk()
            if didBeginTransmit {
                onEndTransmit("call-contact-changed")
            }
            transmitPressBeganAt = nil
            displayedTalkEnergy = 0
            hasReachedReadyCloudMotion = false
            updateReadyCloudMotionLatch()
        }
        .onDisappear {
            let didBeginTransmit = cancelPendingHoldToTalk()
            if didBeginTransmit {
                onEndTransmit("call-screen-disappeared")
            }
            transmitPressBeganAt = nil
        }
        #if DEBUG
        .onAppear {
            print("call cloud appeared", "contact=\(contact.id)", "seed=\(backgroundSeed)", "phase=\(selectedConversationState.phase)", "media=\(mediaConnectionState)")
        }
        .onDisappear {
            print("call cloud disappeared", "contact=\(contact.id)", "seed=\(backgroundSeed)", "phase=\(selectedConversationState.phase)", "media=\(mediaConnectionState)")
        }
        #endif
    }

    private static func topChromePadding(geometrySafeAreaInsets: EdgeInsets) -> CGFloat {
        let safeAreaTop = max(geometrySafeAreaInsets.top, currentWindowSafeAreaInsets.top)
        return max(safeAreaTop + 20, 52)
    }

    private static var currentWindowSafeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes.compactMap { scene -> UIEdgeInsets? in
            guard let windowScene = scene as? UIWindowScene else { return nil }
            return windowScene.windows.first(where: \.isKeyWindow)?.safeAreaInsets
                ?? windowScene.windows.first?.safeAreaInsets
        }.first ?? .zero
    }

    @ViewBuilder
    private func cloudCallContent(
        usesWideLayout: Bool,
        cloudMotion: TurboCallCloudMotion,
        topSafePadding: CGFloat
    ) -> some View {
        TurboCallCloudBackground(
            seed: backgroundSeed,
            tuning: cloudTuning,
            motion: cloudMotion,
            frozenTime: cloudFrozenTime,
            animationsEnabled: backgroundAnimationsEnabled
        )

        VStack(spacing: 0) {
            topBar
                .padding(.bottom, usesWideLayout ? 52 : 44)

            identityRow(usesWideLayout: usesWideLayout)

            Spacer(minLength: 0)

            actionButtons
                .frame(maxWidth: usesWideLayout ? 520 : .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, usesWideLayout ? 44 : 16)
        .padding(.top, topSafePadding)
        .padding(.bottom, 58)
    }

    private var cloudShouldAnimate: Bool {
        guard backgroundAnimationsEnabled else { return false }
        if mediaConnectionState == .preparing { return true }
        switch selectedConversationState.phase {
        case .outgoingBeep, .incomingBeep, .waitingForPeer, .systemMismatch:
            return true
        case .idle, .friendReady, .wakeReady, .localJoinFailed, .ready, .startingTransmit,
             .transmitting, .receiving, .blockedByOtherSession:
            return false
        }
    }

    private var cloudMotion: TurboCallCloudMotion {
        let talkEnergy = displayedTalkEnergy
        switch selectedConversationState.phase {
        case .startingTransmit, .transmitting, .receiving:
            return TurboCallCloudMotion(phase: .conversationActive, talkEnergy: talkEnergy)
        case .idle, .outgoingBeep, .incomingBeep, .friendReady, .waitingForPeer, .wakeReady,
             .localJoinFailed, .ready, .blockedByOtherSession, .systemMismatch:
            break
        }
        if talkEnergy > 0 || isTransmitPressActive {
            return TurboCallCloudMotion(phase: .conversationActive, talkEnergy: talkEnergy)
        }
        if cloudShouldAnimate {
            guard !hasReachedReadyCloudMotion else {
                return TurboCallCloudMotion(phase: .idleReady, talkEnergy: 0)
            }
            return TurboCallCloudMotion(phase: .connecting, talkEnergy: 0)
        }
        return TurboCallCloudMotion(phase: .idleReady, talkEnergy: 0)
    }

    private var isReadyCloudMotionLatchEligible: Bool {
        if selectedConversationState.canTransmitNow { return true }
        if mediaConnectionState == .connected { return true }
        switch selectedConversationState.phase {
        case .friendReady, .wakeReady, .ready:
            return true
        case .idle, .outgoingBeep, .incomingBeep, .waitingForPeer, .localJoinFailed,
             .startingTransmit, .transmitting, .receiving, .blockedByOtherSession, .systemMismatch:
            return false
        }
    }

    private func updateReadyCloudMotionLatch() {
        guard isReadyCloudMotionLatchEligible else { return }
        hasReachedReadyCloudMotion = true
    }

    private var rawLocalCloudTalkEnergy: Double {
        guard isPTTAudioSessionActive else { return 0 }
        let isLocallyTalking: Bool
        switch selectedConversationState.phase {
        case .startingTransmit, .transmitting:
            isLocallyTalking = true
        case .idle, .outgoingBeep, .incomingBeep, .friendReady, .waitingForPeer, .wakeReady,
             .localJoinFailed, .ready, .receiving, .blockedByOtherSession, .systemMismatch:
            isLocallyTalking = isTransmitPressActive
        }
        guard isLocallyTalking else { return 0 }
        let measuredEnergy = max(0, min(1, localAudioLevel))
        let responsiveEnergy = min(1, measuredEnergy * cloudTuning.talkSensitivity)
        let curvedEnergy = pow(responsiveEnergy, 0.72)
        let baseline = max(0, min(0.45, cloudTuning.talkBaseline))
        return min(1, baseline + curvedEnergy * (1 - baseline))
    }

    private func updateDisplayedTalkEnergy(_ rawEnergy: Double) {
        let target = rawEnergy < 0.035 ? 0 : rawEnergy
        let delta = abs(target - displayedTalkEnergy)
        guard delta > 0.025 || target == 0 || displayedTalkEnergy == 0 else { return }

        let duration = target > displayedTalkEnergy ? 0.24 : 0.62
        withAnimation(.easeOut(duration: duration)) {
            displayedTalkEnergy = target
        }
    }

    private var backgroundSeed: UInt64 {
        Self.cloudSeed(for: contact.id)
    }

    private static func cloudSeed(for contactID: UUID) -> UInt64 {
        contactID.uuidString.unicodeScalars.reduce(UInt64(0xcbf29ce484222325)) { partial, scalar in
            (partial ^ UInt64(scalar.value)) &* 0x100000001b3
        }
    }

    private var topBar: some View {
        HStack {
            TurboGlassIconButton(
                systemName: "arrow.down.right.and.arrow.up.left",
                accessibilityLabel: "Minimize call",
                action: onClose
            )

            Spacer()
        }
    }

    @ViewBuilder
    private func identityRow(usesWideLayout: Bool) -> some View {
        let avatarSize: CGFloat = usesWideLayout ? 108 : 96
        VStack(spacing: usesWideLayout ? 14 : 12) {
            callAvatar
                .frame(width: avatarSize, height: avatarSize)
                .padding(.bottom, 2)

            presenceText

            if let requestSubjectText {
                Text(requestSubjectText)
                    .font(.system(size: 16, weight: .medium, design: .default))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }

            if callStatisticsVisible, hasVisibleConversationParticipantTelemetry {
                conversationParticipantTelemetryRows
                    .frame(maxWidth: 360, alignment: .leading)
                    .padding(.top, 14)
            } else if let audio = remoteParticipantVolumeWarningAudio {
                remoteParticipantVolumeWarningRow(for: audio)
                    .frame(maxWidth: 360, alignment: .leading)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: 360, alignment: .center)
        .padding(.top, usesWideLayout ? 6 : 8)
    }

    private var presenceText: some View {
        VStack(alignment: .center, spacing: 8) {
            Text(contact.name)
                .font(.system(size: 31, weight: .medium, design: .default))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .multilineTextAlignment(.center)

            let status = callStatusText(now: Date())
            Text(status)
                .font(.system(size: 20, weight: .regular, design: .default))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .multilineTextAlignment(.center)
                .animation(.easeInOut(duration: 0.18), value: status)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var callAvatar: some View {
        TimelineView(.animation) { timeline in
            let pulse = callAvatarPresencePulse(at: timeline.date)
            Circle()
                .fill(callAvatarColor)
                .overlay(
                    Text(initials(for: contact.name))
                        .font(.system(size: 26, weight: .medium, design: .default))
                        .foregroundStyle(Color(red: 0.96, green: 0.95, blue: 0.91))
                        .tracking(0.8)
                )
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(pulse.ringOpacity), lineWidth: pulse.ringWidth)
                        .blur(radius: 0.5)
                )
                .shadow(
                    color: Color.white.opacity(pulse.glowOpacity),
                    radius: pulse.shadowRadius,
                    x: 0,
                    y: 0
                )
                .scaleEffect(pulse.scale)
        }
    }

    private var callAvatarColor: Color {
        let palette = [
            Color(red: 0.45, green: 0.49, blue: 0.41),
            Color(red: 0.50, green: 0.42, blue: 0.38),
            Color(red: 0.42, green: 0.48, blue: 0.52),
            Color(red: 0.52, green: 0.47, blue: 0.36),
            Color(red: 0.44, green: 0.42, blue: 0.50)
        ]
        let hash = contact.id.uuidString.unicodeScalars.reduce(UInt32(2_166_136_261)) { partial, scalar in
            (partial ^ UInt32(scalar.value)) &* 16_777_619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }

    private var requestSubjectText: String? {
        guard let subject = requestSubject?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subject.isEmpty,
              !isGenericRequestSubject(subject) else {
            return nil
        }
        return subject
    }

    private func isGenericRequestSubject(_ subject: String) -> Bool {
        let normalized = subject
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))

        return [
            "generic",
            "talk",
            "Beep",
            "want to talk",
            "wants to talk",
            "want to talk?",
            "wants to talk?",
            "someone wants to talk",
            "someone wants to talk with you",
            "someone wants to talk to you"
        ].contains(normalized)
    }

    private var conversationParticipantTelemetryRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let localVolumeWarningText {
                conversationParticipantTelemetryRow(
                    symbolName: localAudioSymbolName,
                    text: localVolumeWarningText,
                    fontSize: 15,
                    fontWeight: .medium,
                    color: localVolumeWarningColor,
                    accessibilityLabel: localVolumeWarningAccessibilityLabel
                )
            }

            if let audio = remoteParticipantTelemetry?.audio {
                conversationParticipantTelemetryRow(
                    symbolName: audioSymbolName(for: audio),
                    text: remoteParticipantAudioStatusText(for: audio),
                    fontSize: 15,
                    color: remoteParticipantAudioStatusColor(for: audio),
                    accessibilityLabel: remoteParticipantAudioStatusAccessibilityLabel(for: audio)
                )
            } else {
                conversationParticipantTelemetryRow(
                    symbolName: "speaker.wave.2.fill",
                    text: "\(contactShortName)’s audio · Waiting",
                    fontSize: 15,
                    color: conversationParticipantTelemetryColor.opacity(0.62),
                    accessibilityLabel: "\(contact.name)'s audio status is waiting"
                )
            }

            if let remoteParticipantConnectionStatusText {
                conversationParticipantTelemetryRow(
                    symbolName: connectionSymbolName,
                    text: remoteParticipantConnectionStatusText,
                    accessibilityLabel: remoteParticipantConnectionStatusAccessibilityLabel
                )
            }

            conversationParticipantTelemetryRow(
                symbolName: audioEncryptionStatus.symbolName,
                text: audioEncryptionStatus.text,
                iconFontSize: 10,
                iconWeight: .semibold,
                accessibilityLabel: audioEncryptionStatus.accessibilityLabel
            )
        }
    }

    private var remoteParticipantVolumeWarningAudio: ConversationParticipantTelemetry.Audio? {
        guard let audio = remoteParticipantTelemetry?.audio,
              isVolumeLow(audio.volumePercent) else {
            return nil
        }
        return audio
    }

    private func remoteParticipantVolumeWarningRow(for audio: ConversationParticipantTelemetry.Audio) -> some View {
        conversationParticipantTelemetryRow(
            symbolName: audioSymbolName(for: audio),
            text: remoteParticipantAudioStatusText(for: audio),
            fontSize: 15,
            color: remoteParticipantAudioStatusColor(for: audio),
            accessibilityLabel: remoteParticipantAudioStatusAccessibilityLabel(for: audio)
        )
    }

    private func conversationParticipantTelemetryRow(
        symbolName: String,
        text: String,
        fontSize: CGFloat = 14,
        fontWeight: Font.Weight = .regular,
        iconFontSize: CGFloat = 13,
        iconWeight: Font.Weight = .regular,
        color: Color? = nil,
        accessibilityLabel: String
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: iconFontSize, weight: iconWeight, design: .default))
                .frame(width: 15, alignment: .center)
            Text(text)
                .font(.system(size: fontSize, weight: fontWeight, design: .default))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundStyle(color ?? conversationParticipantTelemetryColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var hasVisibleConversationParticipantTelemetry: Bool {
        true
    }

    private var audioBlockerPresentation: AudioBlockerPresentation? {
        if let localAudio = localTelemetry?.audio {
            if localAudio.isVolumeOff {
                return .localVolumeOff(contactName: contactShortName)
            }
            if localAudio.isVolumeVeryLow {
                return .localVolumeVeryLow(contactName: contactShortName)
            }
            if localAudio.isVolumeLow {
                return .localVolumeLow(contactName: contactShortName)
            }
        }
        if let remoteAudio = remoteParticipantTelemetry?.audio {
            if remoteAudio.isVolumeOff {
                return .remoteVolumeOff(contactName: contactShortName)
            }
            if remoteAudio.isVolumeVeryLow {
                return .remoteVolumeVeryLow(contactName: contactShortName)
            }
            if remoteAudio.isVolumeLow {
                return .remoteVolumeLow(contactName: contactShortName)
            }
        }
        return nil
    }

    private func audioBlockerOverlay(_ presentation: AudioBlockerPresentation) -> some View {
        VStack(spacing: 12) {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 31, weight: .semibold, design: .default))
                .foregroundStyle(Color(red: 0.10, green: 0.12, blue: 0.14))
                .frame(width: 48, height: 48)
                .background(Color.black.opacity(0.055), in: Circle())

            VStack(spacing: 5) {
                Text(presentation.title)
                    .font(.system(size: 20, weight: .semibold, design: .default))
                    .foregroundStyle(Color(red: 0.08, green: 0.09, blue: 0.10))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)

                Text(presentation.message)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundStyle(Color(red: 0.28, green: 0.29, blue: 0.31))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.78)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 26, y: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var remoteParticipantConnectionStatusText: String? {
        if selectedConversationState.phase == .wakeReady {
            return "\(contactShortName)’s connection · Background · Wakeable"
        }
        let parts = [
            remoteParticipantTelemetry?.connection?.displayName,
            transportPathLabel
        ].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "\(contactShortName)’s connection · \(parts.joined(separator: " · "))"
    }

    private var remoteParticipantConnectionStatusAccessibilityLabel: String {
        if selectedConversationState.phase == .wakeReady {
            return "\(contact.name)'s connection, background, wakeable"
        }
        let parts = [
            remoteParticipantTelemetry?.connection?.displayName,
            transportPathAccessibilityLabel
        ].compactMap { $0 }
        guard !parts.isEmpty else { return "\(contact.name)'s connection" }
        return "\(contact.name)'s connection, \(parts.joined(separator: ", "))"
    }

    private var connectionSymbolName: String {
        switch remoteParticipantTelemetry?.connection?.interface {
        case .wifi:
            return "wifi"
        case .cellular:
            return "antenna.radiowaves.left.and.right"
        case .wired:
            return "cable.connector"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        case .other, .unknown, .none:
            return "dot.radiowaves.left.and.right"
        }
    }

    private var localAudioSymbolName: String {
        guard let audio = localTelemetry?.audio else {
            return "speaker.wave.2.fill"
        }
        return audioSymbolName(for: audio)
    }

    private func audioSymbolName(for audio: ConversationParticipantTelemetry.Audio) -> String {
        if audio.isVolumeOff {
            return "speaker.slash.fill"
        }
        let routeName = audio.routeName.lowercased()
        if routeName.contains("bluetooth") {
            return "headphones"
        }
        if routeName.contains("headphone") || routeName.contains("airplay") {
            return "headphones"
        }
        if routeName.contains("earpiece") {
            return "speaker.wave.1.fill"
        }
        if routeName.contains("speaker") {
            return "speaker.wave.2.fill"
        }
        return "speaker.wave.2.fill"
    }

    private var transportPathLabel: String? {
        switch transportPathState {
        case .direct:
            return "Direct"
        case .fastRelay:
            return "Fast Relay"
        case .fastRelayTcp:
            return "Fast Relay TCP"
        case .relay:
            return "Relayed"
        case .promoting, .recovering, .none:
            return nil
        }
    }

    private var transportPathAccessibilityLabel: String? {
        switch transportPathState {
        case .direct:
            return "direct"
        case .fastRelay:
            return "fast relay"
        case .fastRelayTcp:
            return "fast relay tcp"
        case .relay:
            return "relayed"
        case .promoting, .recovering, .none:
            return nil
        }
    }

    private var conversationParticipantTelemetryColor: Color {
        .white.opacity(0.52)
    }

    private var lowVolumeAttentionColor: Color {
        Color(red: 0.92, green: 0.67, blue: 0.42)
    }

    private var localVolumeWarningColor: Color {
        guard let percent = localTelemetry?.audio?.volumePercent else {
            return conversationParticipantTelemetryColor
        }
        return isVolumeOff(percent)
            ? lowVolumeAttentionColor
            : .white.opacity(0.68)
    }

    private var localVolumeWarningText: String? {
        guard let percent = localTelemetry?.audio?.volumePercent else { return nil }
        if isVolumeOff(percent) {
            return "Turn up volume to hear \(contactShortName)"
        }
        if isVolumeVeryLow(percent) {
            return "Volume is very low"
        }
        if isVolumeLow(percent) {
            return "Volume is low"
        }
        return nil
    }

    private var localVolumeWarningAccessibilityLabel: String {
        guard let percent = localTelemetry?.audio?.volumePercent else {
            return ""
        }
        if isVolumeOff(percent) {
            return "Your volume is off. Turn up volume to hear \(contact.name)."
        }
        if isVolumeVeryLow(percent) {
            return "Your volume is very low. You may not hear \(contact.name)."
        }
        return "Your volume is low. \(contact.name) may sound quiet."
    }

    private func remoteParticipantAudioStatusText(for audio: ConversationParticipantTelemetry.Audio) -> String {
        if isVolumeOff(audio.volumePercent) {
            return "\(contactShortName)’s volume is off"
        }
        if isVolumeVeryLow(audio.volumePercent) {
            return "\(contactShortName)’s volume is very low"
        }
        if isVolumeLow(audio.volumePercent) {
            return "\(contactShortName)’s volume is low"
        }
        return "\(contactShortName)’s audio · \(audio.routeName) · \(audio.volumePercent)%"
    }

    private func remoteParticipantAudioStatusColor(for audio: ConversationParticipantTelemetry.Audio) -> Color {
        isVolumeLow(audio.volumePercent) ? lowVolumeAttentionColor.opacity(0.9) : conversationParticipantTelemetryColor
    }

    private func remoteParticipantAudioStatusAccessibilityLabel(for audio: ConversationParticipantTelemetry.Audio) -> String {
        if isVolumeOff(audio.volumePercent) {
            return "\(contact.name)'s volume is off. They may not hear you."
        }
        if isVolumeVeryLow(audio.volumePercent) {
            return "\(contact.name)'s volume is very low. They may not hear you."
        }
        if isVolumeLow(audio.volumePercent) {
            return "\(contact.name)'s volume is low. They may not hear you clearly."
        }
        return "\(contactShortName)’s audio, \(audio.routeName), volume \(audio.volumePercent) percent"
    }

    private func isVolumeOff(_ percent: Int) -> Bool {
        percent <= ConversationParticipantTelemetry.Audio.volumeOffMaximumPercent
    }

    private func isVolumeVeryLow(_ percent: Int) -> Bool {
        percent <= ConversationParticipantTelemetry.Audio.veryLowVolumeMaximumPercent
    }

    private func isVolumeLow(_ percent: Int) -> Bool {
        percent <= ConversationParticipantTelemetry.Audio.lowVolumeMaximumPercent
    }

    private var contactShortName: String {
        contact.name.split(separator: " ").first.map(String.init) ?? contact.name
    }

    private var actionButtons: some View {
        HStack(alignment: .top) {
            TurboCallActionButton(
                title: "End",
                symbolName: "xmark",
                tint: Color(red: 0.96, green: 0.28, blue: 0.24),
                isEnabled: true,
                action: onLeave
            )

            Spacer(minLength: 64)

            talkControl
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var talkControl: some View {
        if primaryAction.kind == .holdToTalk {
            TurboCallActionButtonLabel(
                title: "Talk",
                symbolName: "waveform",
                tint: talkButtonTint,
                isEnabled: talkButtonIsEnabled,
                isActive: isTalkButtonActive
            )
            .contentShape(Rectangle())
            .gesture(talkGesture)
            .accessibilityLabel(talkButtonAccessibilityLabel)
            .accessibilityHint(talkButtonAccessibilityHint)
            .accessibilityAddTraits(.isButton)
        } else {
            TurboCallActionButton(
                title: "Talk",
                symbolName: "waveform",
                tint: talkButtonTint,
                isEnabled: talkButtonIsEnabled,
                isActive: isTalkButtonActive,
                action: talkButtonTap
            )
        }
    }

    private var talkButtonIsEnabled: Bool {
        primaryAction.isEnabled
    }

    private var talkButtonTint: Color {
        return Color(red: 0.25, green: 0.52, blue: 0.93)
    }

    private var talkButtonAccessibilityLabel: String {
        guard primaryAction.kind == .holdToTalk,
              !primaryAction.isEnabled,
              remoteParticipantTelemetry?.audio?.isVolumeOff == true else {
            return "Talk"
        }
        return "Talk unavailable. \(contactShortName)'s volume is off."
    }

    private var talkButtonAccessibilityHint: String {
        guard primaryAction.kind == .holdToTalk,
              !primaryAction.isEnabled,
              remoteParticipantTelemetry?.audio?.isVolumeOff == true else {
            return ""
        }
        return "They need to turn it up before they can hear you."
    }

    private var isTalkButtonActive: Bool {
        isTransmitPressActive || selectedConversationState.phase == .transmitting
    }

    private func talkButtonTap() {
        guard primaryAction.kind == .connect else { return }
        onJoin()
    }

    private func cancelPendingHoldToTalk() -> Bool {
        pendingHoldToTalkTask?.cancel()
        pendingHoldToTalkTask = nil
        let didBeginTransmit = holdToTalkDidBeginTransmit
        holdToTalkDidBeginTransmit = false
        _ = holdToTalkGestureState.cancel()
        return didBeginTransmit
    }

    private func schedulePendingHoldToTalkStartIfPossible() {
        guard primaryAction.kind == .holdToTalk else { return }
        guard primaryAction.isEnabled else { return }
        guard holdToTalkGestureState.isTrackingTouch else { return }
        guard !holdToTalkDidBeginTransmit else { return }
        let elapsedNanoseconds: UInt64
        if let transmitPressBeganAt {
            elapsedNanoseconds = UInt64(max(0, Date().timeIntervalSince(transmitPressBeganAt)) * 1_000_000_000)
        } else {
            elapsedNanoseconds = 0
        }
        let delayNanoseconds = 180_000_000 > elapsedNanoseconds
            ? 180_000_000 - elapsedNanoseconds
            : 0
        pendingHoldToTalkTask?.cancel()
        pendingHoldToTalkTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            guard holdToTalkGestureState.isTrackingTouch else { return }
            guard primaryAction.kind == .holdToTalk, primaryAction.isEnabled else { return }
            guard !holdToTalkDidBeginTransmit else { return }
            holdToTalkDidBeginTransmit = true
            onBeginTransmit()
        }
    }

    private var talkGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard primaryAction.kind == .holdToTalk else { return }
                guard holdToTalkGestureState.beginTrackingTouch() else { return }
                transmitPressBeganAt = Date()
                holdToTalkDidBeginTransmit = false
                schedulePendingHoldToTalkStartIfPossible()
            }
            .onEnded { _ in
                guard primaryAction.kind == .holdToTalk else { return }
                pendingHoldToTalkTask?.cancel()
                pendingHoldToTalkTask = nil
                let didBeginTransmit = holdToTalkDidBeginTransmit
                holdToTalkDidBeginTransmit = false
                _ = holdToTalkGestureState.endTouch()
                transmitPressBeganAt = nil
                guard didBeginTransmit else { return }
                onTransmitTouchReleased()
                onEndTransmit("call-touch-ended")
            }
    }

    private func callStatusText(now: Date) -> String {
        if isTransmitPressActive, primaryAction.kind == .holdToTalk {
            if localTransmitAudioIsReady || selectedConversationState.detail == .transmitting {
                return transmitReadyStatusText(now: now)
            }
            return transmitStartupStatusText(now: now)
        }

        switch selectedConversationState.detail {
        case .transmitting:
            return transmitReadyStatusText(now: now)
        case .receiving:
            return "Present"
        case .ready, .readyHoldToTalkDisabled:
            return readyStatusText
        case .startingTransmit:
            return readyStatusText
        case .wakeReady:
            return selectedConversationState.statusMessage
        case .waitingForPeer(let reason):
            switch reason {
            case .disconnecting:
                return "Disconnecting..."
            case .releaseRequiredAfterInterruptedTransmit:
                return "Release to retry"
            case .pendingJoin, .backendConversationTransition, .devicePTTTransition,
                 .friendReadyToConnect:
                guard primaryAction.kind != .holdToTalk else {
                    return selectedConversationState.statusMessage == "Connecting..." ? "Wait" : selectedConversationState.statusMessage
                }
                return selectedConversationState.statusMessage
            case .remoteWakeUnavailable:
                return "Waiting"
            case .systemWakeActivation, .wakePlaybackDeferredUntilForeground,
                 .localAudioPrewarm, .localTransportWarmup, .remoteAudioPrewarm:
                return passiveWarmupStatusText(now: now)
            }
        case .friendReady:
            return readyStatusText
        case .incomingBeep:
            if primaryAction.kind == .connect {
                return "Connecting..."
            }
            return "Wants to talk"
        case .outgoingBeep:
            return "Waiting"
        case .localJoinFailed:
            return selectedConversationState.statusMessage
        case .blockedByOtherSession:
            return "Busy"
        case .systemMismatch:
            return "Reconnecting..."
        case .idle(let isOnline):
            return isOnline ? readyStatusText : "Unavailable"
        }
    }

    private var readyStatusText: String {
        guard primaryAction.kind == .holdToTalk else {
            return selectedConversationState.statusMessage
        }
        if selectedConversationState.statusMessage == "Connected" {
            return "Present"
        }
        if selectedConversationState.phase == .wakeReady {
            return selectedConversationState.statusMessage
        }
        if talkButtonIsEnabled {
            return "Present"
        }
        return selectedConversationState.statusMessage == "Connecting..." ? "Wait" : selectedConversationState.statusMessage
    }

    private func transmitStartupStatusText(now: Date) -> String {
        guard let transmitPressBeganAt else {
            return readyStatusText
        }
        let elapsed = now.timeIntervalSince(transmitPressBeganAt)
        return elapsed < 2 ? readyStatusText : "Wait"
    }

    private func transmitReadyStatusText(now: Date) -> String {
        return "Listening"
    }

    private func passiveWarmupStatusText(now: Date) -> String {
        guard isTransmitPressActive else {
            return "Wait"
        }
        return transmitStartupStatusText(now: now)
    }

    private var localTransmitAudioIsReady: Bool {
        mediaSessionContactID == contact.id
            && isPTTAudioSessionActive
            && mediaConnectionState == .connected
    }

    private struct CallAvatarPresencePulse {
        let scale: CGFloat
        let ringOpacity: Double
        let ringWidth: CGFloat
        let glowOpacity: Double
        let shadowRadius: CGFloat
    }

    private func callAvatarPresencePulse(at date: Date) -> CallAvatarPresencePulse {
        let remoteUserIsSpeaking = selectedConversationState.detail == .receiving
        let localUserIsTransmitting = isTalkButtonActive
        guard remoteUserIsSpeaking || localUserIsTransmitting else {
            return CallAvatarPresencePulse(
                scale: 1,
                ringOpacity: 0.08,
                ringWidth: 1,
                glowOpacity: 0,
                shadowRadius: 0
            )
        }

        guard remoteUserIsSpeaking else {
            return CallAvatarPresencePulse(
                scale: 1.012,
                ringOpacity: 0.22,
                ringWidth: 1.35,
                glowOpacity: 0.10,
                shadowRadius: 7
            )
        }

        let baseIntensity: CGFloat = reduceMotion ? 0.02 : 0.06
        let liveIntensity: CGFloat
        if let percent = remoteParticipantTelemetry?.audio?.volumePercent {
            liveIntensity = max(0.0, min(1.0, CGFloat(percent) / 100.0))
        } else {
            liveIntensity = 0.45
        }
        let phase = date.timeIntervalSinceReferenceDate * 2.6
        let wave = 0.5 + 0.5 * CGFloat(sin(phase))
        let intensity = baseIntensity + (liveIntensity * 0.10)

        return CallAvatarPresencePulse(
            scale: 1 + (intensity * 0.35) + (wave * intensity * 0.55),
            ringOpacity: 0.10 + (wave * 0.10) + (liveIntensity * 0.05),
            ringWidth: 1 + (wave * 0.7),
            glowOpacity: 0.08 + (wave * 0.12) + (liveIntensity * 0.08),
            shadowRadius: 6 + (wave * 8) + (liveIntensity * 3)
        )
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        let initials = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        if initials.isEmpty, let first = name.first {
            return String(first).uppercased()
        }
        return initials.uppercased()
    }
}

private struct TurboCallActionButton: View {
    let title: String
    let symbolName: String
    let tint: Color
    let isEnabled: Bool
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TurboCallActionButtonLabel(
                title: title,
                symbolName: symbolName,
                tint: tint,
                isEnabled: isEnabled,
                isActive: isActive
            )
        }
        .buttonStyle(TurboCallControlButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

private struct TurboCallActionButtonLabel: View {
    let title: String
    let symbolName: String
    let tint: Color
    let isEnabled: Bool
    var isActive: Bool = false

    var body: some View {
        VStack(spacing: 14) {
            Circle()
                .fill(isEnabled ? tint : Color.white.opacity(0.13))
                .frame(width: 82, height: 82)
                .scaleEffect(isActive ? 1.08 : 1)
                .overlay(
                    Image(systemName: symbolName)
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.28))
                )

            Text(title)
                .font(.system(size: 17, weight: .regular, design: .default))
                .foregroundStyle(.white.opacity(isEnabled ? 0.92 : 0.34))
        }
        .padding(.vertical, 8)
        .animation(.interactiveSpring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08), value: isActive)
    }
}

private struct TurboCallControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

private struct TurboCallCloudBackground: View {
    let seed: UInt64
    let tuning: TurboCallCloudTuning
    let motion: TurboCallCloudMotion
    let frozenTime: TimeInterval
    let animationsEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedCloudLayerOpacity: Double?
    @State private var displayedDimOpacity: Double?
    @State private var motionTransition: TurboCallCloudMotionTransition?

    private let baseColor = Color(red: 26.0 / 255.0, green: 27.0 / 255.0, blue: 28.0 / 255.0)
    static let animationEpoch: TimeInterval = 780_000_000

    var body: some View {
        GeometryReader { proxy in
            if shouldAnimate {
                TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { timeline in
                    cloudLayer(animationTime: timeline.date.timeIntervalSinceReferenceDate, size: proxy.size)
                }
            } else {
                cloudLayer(animationTime: frozenTime, size: proxy.size)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            snapToTargetVisualState()
        }
        .onChange(of: motion) { oldMotion, _ in
            let visualState = targetVisualState
            guard shouldAnimate else {
                snapToTargetVisualState()
                return
            }
            guard oldMotion.phase != motion.phase else {
                displayedCloudLayerOpacity = visualState.cloudLayerOpacity
                displayedDimOpacity = visualState.dimOpacity
                return
            }
            let duration = Self.visualTransitionDuration(from: oldMotion.phase, to: motion.phase)
            motionTransition = TurboCallCloudMotionTransition(
                from: oldMotion,
                to: motion,
                startedAt: Date.timeIntervalSinceReferenceDate,
                duration: duration
            )
            withAnimation(.easeInOut(duration: duration)) {
                displayedCloudLayerOpacity = visualState.cloudLayerOpacity
                displayedDimOpacity = visualState.dimOpacity
            }
        }
        .onChange(of: tuning) { _, _ in
            let visualState = targetVisualState
            displayedCloudLayerOpacity = visualState.cloudLayerOpacity
            displayedDimOpacity = visualState.dimOpacity
        }
        .onChange(of: animationsEnabled) { _, _ in
            snapToTargetVisualState()
        }
        .onChange(of: reduceMotion) { _, _ in
            snapToTargetVisualState()
        }
    }

    @ViewBuilder
    private func cloudLayer(animationTime: TimeInterval, size: CGSize) -> some View {
        cloudCanvas(animationTime: animationTime)
    }

    private func cloudCanvas(animationTime: TimeInterval) -> some View {
        let resolvedMotion = resolvedMotion(animationTime: animationTime)
        let surfaceStyle = backgroundSurfaceStyle(animationTime: animationTime)
        let targetDimOpacity = min(maxDimOpacity(for: resolvedMotion.phase), tuning.overallDim + resolvedMotion.dimBoost)
        let cloudLayerOpacity = displayedCloudLayerOpacity ?? resolvedMotion.cloudLayerOpacity
        let dimOpacity = displayedDimOpacity ?? targetDimOpacity

        return Canvas(rendersAsynchronously: true) { context, size in
            let animationTime = animationTime - Self.animationEpoch
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(baseColor))
            context.addFilter(.blur(radius: max(size.width, size.height) * tuning.blur))
            context.drawLayer { layer in
                if let secondaryAnimationMode = resolvedMotion.secondaryAnimationMode,
                   resolvedMotion.secondaryAnimationModeOpacity > 0.001 {
                    drawCloudMode(
                        secondaryAnimationMode,
                        opacity: cloudLayerOpacity * resolvedMotion.secondaryAnimationModeOpacity,
                        in: layer,
                        size: size,
                        animationTime: animationTime,
                        resolvedMotion: resolvedMotion
                    )
                }
                if resolvedMotion.animationModeOpacity > 0.001 {
                    drawCloudMode(
                        resolvedMotion.animationMode,
                        opacity: cloudLayerOpacity * resolvedMotion.animationModeOpacity,
                        in: layer,
                        size: size,
                        animationTime: animationTime,
                        resolvedMotion: resolvedMotion
                    )
                }
            }
        }
        .overlay {
            Rectangle()
                .fill(.black.opacity(dimOpacity))
                .blendMode(.multiply)
        }
        .overlay {
            TurboCallBackgroundSurfaceOverlay(style: surfaceStyle)
        }
    }

    private var shouldAnimate: Bool {
        animationsEnabled && motion.isTimelineActive && !reduceMotion
    }

    private var targetVisualState: (cloudLayerOpacity: Double, dimOpacity: Double) {
        let resolvedMotion = motion.resolved(tuning: tuning)
        return (
            cloudLayerOpacity: resolvedMotion.cloudLayerOpacity,
            dimOpacity: min(maxDimOpacity(for: resolvedMotion.phase), tuning.overallDim + resolvedMotion.dimBoost)
        )
    }

    private func maxDimOpacity(for phase: TurboCallCloudMotion.Phase) -> Double {
        switch phase {
        case .connecting, .idleReady:
            return 0.36
        case .conversationActive:
            return 0.78
        }
    }

    private func snapToTargetVisualState() {
        let visualState = targetVisualState
        motionTransition = nil
        displayedCloudLayerOpacity = visualState.cloudLayerOpacity
        displayedDimOpacity = visualState.dimOpacity
    }

    private func backgroundSurfaceStyle(animationTime: TimeInterval) -> TurboCallBackgroundSurfaceStyle {
        guard animationsEnabled,
              !reduceMotion,
              let transition = motionTransition,
              transition.to == motion else {
            return .forPhase(motion.phase)
        }

        let progress = Self.easeInOut(transition.progress(at: animationTime))
        guard progress < 1 else { return .forPhase(motion.phase) }
        return .interpolated(
            from: .forPhase(transition.from.phase),
            to: .forPhase(transition.to.phase),
            progress: progress
        )
    }

    private func drawCloudMode(
        _ animationMode: TurboCallCloudAnimationMode,
        opacity: Double,
        in layer: GraphicsContext,
        size: CGSize,
        animationTime: TimeInterval,
        resolvedMotion: TurboCallCloudResolvedMotion
    ) {
        var layer = layer
        layer.opacity = opacity
        var random = SeededRandom(seed: seed)
        let anchors = Self.buttonAnchors(for: size, isEnabled: tuning.buttonAnchorsEnabled)
        if animationMode.usesAnchorVoid, let anchors {
            for anchor in anchors {
                let source = TurboCallCloudPatch.makeAnchor(
                    anchor: anchor,
                    size: size,
                    tuning: tuning,
                    motion: resolvedMotion,
                    animationTime: animationTime
                )
                layer.fill(
                    source.path,
                    with: .radialGradient(
                        Gradient(colors: source.colors),
                        center: source.startPoint,
                        startRadius: 0,
                        endRadius: source.endRadius
                    )
                )
            }
        }
        let patchCount = Self.scaledPatchCount(for: size, baseCount: tuning.patchCount)
        for index in 0..<patchCount {
            let cloud = TurboCallCloudPatch.make(
                index: index,
                size: size,
                tuning: tuning,
                animationTime: animationTime,
                animationMode: animationMode,
                motion: resolvedMotion,
                anchors: anchors,
                random: &random
            )
            layer.fill(
                cloud.path,
                with: .linearGradient(
                    Gradient(colors: cloud.colors),
                    startPoint: cloud.startPoint,
                    endPoint: cloud.endPoint
                )
            )
        }
    }

    private func resolvedMotion(animationTime: TimeInterval) -> TurboCallCloudResolvedMotion {
        guard animationsEnabled,
              !reduceMotion,
              let transition = motionTransition,
              transition.to == motion else {
            return motion.resolved(tuning: tuning)
        }
        let progress = Self.easeInOut(transition.progress(at: animationTime))
        guard progress < 1 else {
            return motion.resolved(tuning: tuning)
        }
        return TurboCallCloudResolvedMotion.interpolated(
            from: transition.from.resolved(tuning: tuning),
            to: transition.to.resolved(tuning: tuning),
            progress: progress
        )
    }

    private static func easeInOut(_ progress: Double) -> Double {
        let progress = max(0, min(1, progress))
        return progress * progress * (3 - 2 * progress)
    }

    private static func visualTransitionDuration(
        from start: TurboCallCloudMotion.Phase,
        to end: TurboCallCloudMotion.Phase
    ) -> TimeInterval {
        switch (start, end) {
        case (.connecting, .idleReady):
            return 0.55
        case (.idleReady, .connecting):
            return 0.45
        case (_, .conversationActive):
            return 0.45
        case (.conversationActive, _):
            return 0.65
        default:
            return 0.35
        }
    }

    private static func scaledPatchCount(for size: CGSize, baseCount: Double) -> Int {
        let referenceArea = 393.0 * 852.0
        let area = max(Double(size.width * size.height), referenceArea)
        let densityScale = sqrt(area / referenceArea)
        let largeCanvasScale = size.width >= 700 ? 1.16 : 1.0
        return max(1, Int((baseCount * densityScale * largeCanvasScale).rounded()))
    }

    private static func buttonAnchors(for size: CGSize, isEnabled: Bool) -> [TurboCallCloudAnchor]? {
        guard isEnabled else { return nil }
        let usesWideLayout = size.width >= 700
        let horizontalPadding = usesWideLayout ? 44.0 : 28.0
        let contentWidth = size.width - horizontalPadding * 2.0
        let buttonRowWidth = min(usesWideLayout ? 520.0 : contentWidth, contentWidth)
        let rowMinX = (size.width - buttonRowWidth) / 2.0
        let endCenter = CGPoint(
            x: rowMinX + 41.0,
            y: size.height - 58.0 - 132.0 + 49.0
        )

        return [
            TurboCallCloudAnchor(point: endCenter, role: .voidRepeller)
        ]
    }
}

private struct TurboCallCloudMotionTransition: Equatable {
    let from: TurboCallCloudMotion
    let to: TurboCallCloudMotion
    let startedAt: TimeInterval
    let duration: TimeInterval

    func progress(at time: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return max(0, min(1, (time - startedAt) / duration))
    }
}

private struct TurboCallBackgroundSurfaceStyle: Equatable {
    let materialOpacity: Double
    let tintOpacity: Double
    let centerHighlightOpacity: Double
    let topSheenOpacity: Double
    let edgeShadeOpacity: Double
    let borderOpacity: Double

    static func forPhase(_ phase: TurboCallCloudMotion.Phase) -> Self {
        switch phase {
        case .connecting:
            return Self(
                materialOpacity: 0.14,
                tintOpacity: 0.10,
                centerHighlightOpacity: 0.055,
                topSheenOpacity: 0.070,
                edgeShadeOpacity: 0.24,
                borderOpacity: 0.8
            )
        case .idleReady:
            return Self(
                materialOpacity: 0.14,
                tintOpacity: 0.13,
                centerHighlightOpacity: 0.042,
                topSheenOpacity: 0.056,
                edgeShadeOpacity: 0.29,
                borderOpacity: 0.72
            )
        case .conversationActive:
            return Self(
                materialOpacity: 0.10,
                tintOpacity: 0.16,
                centerHighlightOpacity: 0.018,
                topSheenOpacity: 0.026,
                edgeShadeOpacity: 0.34,
                borderOpacity: 0.34
            )
        }
    }

    static func interpolated(from start: Self, to end: Self, progress: Double) -> Self {
        let progress = max(0, min(1, progress))
        return Self(
            materialOpacity: interpolate(start.materialOpacity, end.materialOpacity, progress),
            tintOpacity: interpolate(start.tintOpacity, end.tintOpacity, progress),
            centerHighlightOpacity: interpolate(start.centerHighlightOpacity, end.centerHighlightOpacity, progress),
            topSheenOpacity: interpolate(start.topSheenOpacity, end.topSheenOpacity, progress),
            edgeShadeOpacity: interpolate(start.edgeShadeOpacity, end.edgeShadeOpacity, progress),
            borderOpacity: interpolate(start.borderOpacity, end.borderOpacity, progress)
        )
    }

    private static func interpolate(_ start: Double, _ end: Double, _ progress: Double) -> Double {
        start + (end - start) * progress
    }
}

private struct TurboCallBackgroundSurfaceOverlay: View {
    let style: TurboCallBackgroundSurfaceStyle

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let longestEdge = max(size.width, size.height)
            let shortestEdge = min(size.width, size.height)

            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(style.materialOpacity)

                Rectangle()
                    .fill(.black.opacity(style.tintOpacity))

                LinearGradient(
                    colors: [
                        .white.opacity(style.topSheenOpacity),
                        .white.opacity(style.topSheenOpacity * 0.25),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                .blendMode(.screen)

                RadialGradient(
                    colors: [
                        .white.opacity(style.centerHighlightOpacity),
                        .clear
                    ],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: longestEdge * 0.92
                )
                .blendMode(.screen)

                RadialGradient(
                    colors: [
                        .clear,
                        .black.opacity(style.edgeShadeOpacity)
                    ],
                    center: .center,
                    startRadius: shortestEdge * 0.18,
                    endRadius: longestEdge * 0.88
                )

                Rectangle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.12),
                                .white.opacity(0.03),
                                .white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .blendMode(.screen)
                    .opacity(style.borderOpacity)
            }
            .compositingGroup()
        }
        .allowsHitTesting(false)
    }
}

private struct TurboCallCloudPatch {
    let path: Path
    let colors: [Color]
    let startPoint: CGPoint
    let endPoint: CGPoint
    var endRadius: CGFloat = 0

    static func make(
        index: Int,
        size: CGSize,
        tuning: TurboCallCloudTuning,
        animationTime: TimeInterval,
        animationMode: TurboCallCloudAnimationMode,
        motion: TurboCallCloudResolvedMotion,
        anchors: [TurboCallCloudAnchor]?,
        random: inout SeededRandom
    ) -> TurboCallCloudPatch {
        let minWidth = min(tuning.minWidth, tuning.maxWidth)
        let maxWidth = max(tuning.minWidth, tuning.maxWidth)
        let minHeight = min(tuning.minHeight, tuning.maxHeight)
        let maxHeight = max(tuning.minHeight, tuning.maxHeight)
        let sizeScale = random.next(in: 0.76...1.08)
        let wideLayoutWidthScale = size.width >= 700 ? 0.74 : 1.0
        let baseWidth = size.width * random.next(in: minWidth...maxWidth) * sizeScale * wideLayoutWidthScale
        let baseHeight = size.height * random.next(in: minHeight...maxHeight) * sizeScale
        let baseCenter = CGPoint(
            x: size.width * random.next(in: -0.12...1.12),
            y: size.height * random.next(in: -0.08...1.08)
        )
        let driftPhase = Double(index) * 1.73 + random.next(in: 0.0...(Double.pi * 2.0))
        let secondaryPhase = Double(index) * 2.31 + random.next(in: 0.0...(Double.pi * 2.0))
        let driftRadiusRoll = random.next(in: 0.45...1.15)
        let secondaryRadiusRoll = random.next(in: 0.18...0.42)
        let motionAmount = tuning.motionAmount * motion.motionAmountMultiplier
        let motionSpeed = tuning.motionSpeed * motion.motionSpeedMultiplier
        let breath = Self.breathScale(
            index: index,
            time: animationTime,
            phase: driftPhase,
            secondaryPhase: secondaryPhase,
            motion: motion
        )
        let width = baseWidth * breath
        let height = baseHeight * breath
        let center: CGPoint
        switch animationMode {
        case .drift:
            let driftRadius = min(size.width, size.height) * motionAmount * driftRadiusRoll
            let secondaryRadius = driftRadius * secondaryRadiusRoll
            let t = animationTime * motionSpeed
            center = CGPoint(
                x: baseCenter.x
                    + sin(t * 0.52 + driftPhase) * driftRadius * 0.58
                    + sin(t * 0.17 + secondaryPhase) * secondaryRadius
                    + Self.smoothNoise(time: t * 0.72, seed: index, salt: 11) * driftRadius
                        * 0.32
                    + Self.smoothNoise(time: t * 0.19, seed: index, salt: 23) * secondaryRadius
                        * 0.42,
                y: baseCenter.y
                    + cos(t * 0.47 + secondaryPhase) * driftRadius * 0.54
                    + cos(t * 0.21 + driftPhase) * secondaryRadius
                    + Self.smoothNoise(time: t * 0.63, seed: index, salt: 37) * driftRadius
                        * 0.32
                    + Self.smoothNoise(time: t * 0.23, seed: index, salt: 41) * secondaryRadius
                        * 0.42
            )
        case .reaction:
            var flow = Self.reactionFlowOffset(
                index: index,
                time: animationTime,
                phase: driftPhase,
                secondaryPhase: secondaryPhase,
                speed: motionSpeed,
                radius: min(size.width, size.height) * motionAmount
            )
            if motion.phase == .conversationActive, motion.talkEnergy > 0 {
                let wave = Self.talkWaveOffset(
                    point: baseCenter,
                    size: size,
                    time: animationTime,
                    phase: driftPhase,
                    speed: motionSpeed,
                    radius: min(size.width, size.height) * motionAmount,
                    energy: motion.talkEnergy
                )
                flow.x += wave.x
                flow.y += wave.y
            }
            var reactionCenter = CGPoint(x: baseCenter.x + flow.x, y: baseCenter.y + flow.y)
            if let anchors, !anchors.isEmpty {
                for anchor in anchors {
                    reactionCenter = Self.repel(
                        point: reactionCenter,
                        from: anchor.point,
                        size: size,
                        amount: motionAmount,
                        index: index,
                        time: animationTime * motionSpeed
                    )
                }
            }
            center = reactionCenter
        }
        let rect = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        let path = makeCellularPath(
            rect: rect,
            animationTime: animationMode.morphsCellShape ? animationTime : nil,
            animationSpeed: motionSpeed,
            morphAmount: motion.cellMorphMultiplier,
            phase: driftPhase,
            random: &random
        )

        let opacityRange: ClosedRange<CGFloat> = 0.055...0.130
        let depthRoll = random.next(in: 0.0...1.0)
        let depthMultiplier: Double
        if depthRoll > 0.95 {
            depthMultiplier = 1.0 + tuning.depthContrast * random.next(in: 0.95...1.55)
        } else if depthRoll > 0.80 {
            depthMultiplier = 1.0 + tuning.depthContrast * random.next(in: 0.35...0.75)
        } else {
            depthMultiplier = 1.0 - tuning.depthContrast * random.next(in: 0.22...0.48)
        }
        let reactionAmount = animationMode == .reaction
            ? Self.reactionAmount(
                point: baseCenter,
                size: size,
                time: animationTime,
                phase: driftPhase,
                speed: motionSpeed
            )
            : 0
        let breathOpacityResponse = motion.phase == .conversationActive ? 0.42 : 1.35
        let breathOpacity = 0.94 + (breath - 1.0) * breathOpacityResponse
        let animationOpacityMultiplier: Double = animationMode == .reaction ? 0.86 + reactionAmount * 0.28 : 1.0
        let opacity = Double(random.next(in: opacityRange)) * tuning.opacity * depthMultiplier * animationOpacityMultiplier
            * breathOpacity
        let colorAmount = min(1.60, tuning.colorAmount * motion.colorAmountMultiplier)
        let hueSpread = min(1.45, tuning.hueSpread * motion.hueSpreadMultiplier)
        let reactionHueShift = animationMode.usesFlowColorShift ? (reactionAmount - 0.5) * 0.22 * hueSpread : 0
        let auroraShift = Double(random.next(in: -0.5...0.5)) * 0.36 * hueSpread + reactionHueShift
        let coolHue = Self.wrapHue(0.54 + auroraShift)
        let warmHue = Self.wrapHue(0.12 + auroraShift * 0.40)
        let neutralHue = Self.wrapHue(0.58 + auroraShift * 0.72)
        let cool = Color(
            hue: coolHue,
            saturation: 0.060 + 0.34 * colorAmount,
            brightness: 0.70 + 0.08 * colorAmount
        )
        let warm = Color(
            hue: warmHue,
            saturation: 0.040 + 0.26 * colorAmount,
            brightness: 0.60 + 0.07 * colorAmount
        )
        let neutral = Color(
            hue: neutralHue,
            saturation: 0.030 + 0.10 * colorAmount,
            brightness: 0.72
        )
        let warmOpacity = opacity * (0.34 + 0.42 * colorAmount)
        let neutralOpacity = opacity * (0.38 - 0.14 * colorAmount)
        let colors: [Color]
        if index.isMultiple(of: 3) {
            colors = [
                warm.opacity(warmOpacity),
                cool.opacity(opacity)
            ]
        } else {
            colors = [
                cool.opacity(opacity),
                neutral.opacity(neutralOpacity)
            ]
        }

        return TurboCallCloudPatch(
            path: path,
            colors: colors,
            startPoint: CGPoint(
                x: rect.minX + width * Self.animatedGradientUnit(
                    base: random.next(in: 0.0...0.26),
                    time: animationTime,
                    phase: driftPhase,
                    mode: animationMode
                ),
                y: rect.minY + height * Self.animatedGradientUnit(
                    base: random.next(in: 0.0...0.7),
                    time: animationTime,
                    phase: secondaryPhase,
                    mode: animationMode
                )
            ),
            endPoint: CGPoint(
                x: rect.maxX - width * Self.animatedGradientUnit(
                    base: random.next(in: 0.0...0.26),
                    time: animationTime,
                    phase: secondaryPhase,
                    mode: animationMode
                ),
                y: rect.maxY - height * Self.animatedGradientUnit(
                    base: random.next(in: 0.0...0.7),
                    time: animationTime,
                    phase: driftPhase,
                    mode: animationMode
                )
            )
        )
    }

    static func makeAnchor(
        anchor: TurboCallCloudAnchor,
        size: CGSize,
        tuning: TurboCallCloudTuning,
        motion: TurboCallCloudResolvedMotion,
        animationTime: TimeInterval
    ) -> TurboCallCloudPatch {
        let breathAmount = motion.breathAmount * 0.65
        let pulse = 1.0 + breathAmount * sin(animationTime * motion.breathSpeed + anchor.phase)
        let radius = min(size.width, size.height) * 0.34 * pulse
        let rect = CGRect(
            x: anchor.point.x - radius,
            y: anchor.point.y - radius,
            width: radius * 2.0,
            height: radius * 2.0
        )
        let path = Path(ellipseIn: rect)
        let opacity = tuning.opacity * 0.10
        let colors: [Color] = [
            Color.black.opacity(opacity),
            Color.black.opacity(opacity * 0.42),
            Color.clear
        ]
        return TurboCallCloudPatch(
            path: path,
            colors: colors,
            startPoint: anchor.point,
            endPoint: anchor.point,
            endRadius: radius
        )
    }

    private static func repel(
        point: CGPoint,
        from anchor: CGPoint,
        size: CGSize,
        amount: Double,
        index: Int,
        time: Double
    ) -> CGPoint {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let distance = max(1.0, sqrt(dx * dx + dy * dy))
        let influenceRadius = min(size.width, size.height) * 0.46
        let influence = max(0.0, 1.0 - distance / influenceRadius)
        guard influence > 0 else { return point }

        let angularWander = Self.smoothNoise(time: time * 0.54, seed: index, salt: 67) * 0.38
        let angle = atan2(dy, dx) + angularWander
        let push = influence * influence * min(size.width, size.height) * amount * 0.92
        return CGPoint(
            x: point.x + cos(angle) * push,
            y: point.y + sin(angle) * push
        )
    }

    private static func animatedGradientUnit(
        base: Double,
        time: TimeInterval,
        phase: Double,
        mode: TurboCallCloudAnimationMode
    ) -> Double {
        guard mode == .reaction else { return base }
        return min(0.92, max(0.0, base + sin(time * 0.74 + phase) * 0.18))
    }

    private static func reactionFlowOffset(
        index: Int,
        time: TimeInterval,
        phase: Double,
        secondaryPhase _: Double,
        speed: Double,
        radius: Double
    ) -> CGPoint {
        let t = time * speed
        let scale = radius * (0.74 + 0.22 * sin(Double(index) * 1.11 + phase))
        let x = Self.smoothNoise(time: t * 0.86, seed: index, salt: 71) * scale
            + Self.smoothNoise(time: t * 0.37, seed: index, salt: 73) * scale * 0.46
            + Self.smoothNoise(time: t * 0.17, seed: index, salt: 79) * scale * 0.28
        let y = Self.smoothNoise(time: t * 0.78, seed: index, salt: 83) * scale
            + Self.smoothNoise(time: t * 0.33, seed: index, salt: 89) * scale * 0.42
            + Self.smoothNoise(time: t * 0.21, seed: index, salt: 97) * scale * 0.24
        return CGPoint(x: x, y: y)
    }

    private static func talkWaveOffset(
        point: CGPoint,
        size: CGSize,
        time: TimeInterval,
        phase: Double,
        speed: Double,
        radius: Double,
        energy: Double
    ) -> CGPoint {
        let x = Double(point.x / max(size.width, 1))
        let y = Double(point.y / max(size.height, 1))
        let t = time * max(speed, 0.01)
        let wavePhase = t * 0.92 + x * 2.1 + y * 4.6 + phase * 0.14
        let wave = sin(wavePhase)
        let crossWave = sin(t * 0.47 + x * -2.8 + y * 2.2 + phase * 0.24)
        let breathWave = sin(t * 0.28 + x * 1.3 + phase * 0.09)
        let amplitude = radius * (0.22 + min(1, energy) * 0.24)
        return CGPoint(
            x: (wave * 0.58 + crossWave * 0.20 + breathWave * 0.16) * amplitude,
            y: (cos(wavePhase * 0.70 + phase * 0.10) * 0.18 + wave * 0.18) * amplitude
        )
    }

    private static func breathScale(
        index: Int,
        time: TimeInterval,
        phase: Double,
        secondaryPhase: Double,
        motion: TurboCallCloudResolvedMotion
    ) -> Double {
        let breathAmount = motion.breathAmount
        guard breathAmount > 0 else { return 1.0 }
        let t = time * motion.breathSpeed
        let depth = 0.72 + 0.28 * sin(Double(index) * 1.13 + phase)

        if motion.phase == .conversationActive {
            let sharedPulse = sin(t)
            let localDrift = sin(t * 0.43 + secondaryPhase) * 0.18
            return max(0.86, min(1.18, 1.0 + (sharedPulse + localDrift) * breathAmount * depth))
        }

        let primary = sin(t + phase)
        let secondary = sin(t * 0.57 + secondaryPhase) * 0.34
        return max(0.86, min(1.16, 1.0 + (primary + secondary) * breathAmount * depth))
    }

    private static func smoothNoise(time: Double, seed: Int, salt: UInt64) -> Double {
        let lower = floor(time)
        let fraction = time - lower
        let smoothed = smoothstep(fraction)
        let a = hashNoise(index: Int(lower), seed: seed, salt: salt)
        let b = hashNoise(index: Int(lower) + 1, seed: seed, salt: salt)
        return a + (b - a) * smoothed
    }

    private static func smoothstep(_ value: Double) -> Double {
        value * value * value * (value * (value * 6 - 15) + 10)
    }

    private static func hashNoise(index: Int, seed: Int, salt: UInt64) -> Double {
        var value = UInt64(bitPattern: Int64(index))
        value &+= UInt64(bitPattern: Int64(seed &* 0x45d9f3b))
        value &+= salt &* 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value = value ^ (value >> 31)
        let unit = Double(value >> 11) / Double(1 << 53)
        return unit * 2.0 - 1.0
    }

    private static func reactionAmount(
        point: CGPoint,
        size: CGSize,
        time: TimeInterval,
        phase: Double,
        speed: Double
    ) -> Double {
        let x = Double(point.x / max(size.width, 1))
        let y = Double(point.y / max(size.height, 1))
        let t = time * speed
        let a = sin((x * 8.7 + y * 3.1) + t * 0.31 + phase)
        let b = sin((x * -4.2 + y * 10.3) - t * 0.23 + phase * 0.71)
        let c = cos((x * 13.1 - y * 6.4) + t * 0.17 + phase * 1.37)
        let value = (a * 0.46 + b * 0.34 + c * 0.20 + 1.0) * 0.5
        return min(1.0, max(0.0, value))
    }

    private static func wrapHue(_ hue: Double) -> Double {
        let wrapped = hue.truncatingRemainder(dividingBy: 1)
        return wrapped >= 0 ? wrapped : wrapped + 1
    }

    private static func makeCellularPath(
        rect: CGRect,
        animationTime: TimeInterval? = nil,
        animationSpeed: Double = 1,
        morphAmount: Double = 1,
        phase: Double = 0,
        random: inout SeededRandom
    ) -> Path {
        let pointCount = 16
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)

        for index in 0..<pointCount {
            let angle = CGFloat(index) / CGFloat(pointCount) * .pi * 2
            var radius = random.next(in: 0.50...1.18)
            if let animationTime {
                let t = animationTime * animationSpeed
                let phaseSeed = Int(abs(phase) * 1_000)
                let wobble = Self.smoothNoise(time: t * 0.82, seed: phaseSeed + index, salt: 101) * 0.10
                    + Self.smoothNoise(time: t * 0.34, seed: phaseSeed + index, salt: 103) * 0.07
                radius *= CGFloat(1.0 + wobble * morphAmount)
            }
            points.append(
                CGPoint(
                    x: center.x + cos(angle) * rect.width * 0.5 * radius,
                    y: center.y + sin(angle) * rect.height * 0.5 * radius
                )
            )
        }

        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let midpoint = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: midpoint, control: current)
        }
        path.closeSubpath()
        return path
    }
}

private struct TurboCallCloudAnchor {
    enum Role {
        case voidRepeller
    }

    let point: CGPoint
    let role: Role

    var phase: Double {
        switch role {
        case .voidRepeller:
            return 0.7
        }
    }
}

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 1 : seed
    }

    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        let unit = CGFloat(nextUnit())
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }

    private mutating func nextUnit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value = value ^ (value >> 31)
        return Double(value >> 11) / Double(1 << 53)
    }
}

private struct HatTilingBackground: View {
    private struct RenderRequest: Equatable {
        let size: CGSize
        let tuning: HatTextureTuning
    }

    let tuning: HatTextureTuning
    @State private var renderedTexture: CGImage?

    private struct PolygonRecord {
        let points: [CGPoint]
        let bounds: CGRect
    }

    private static let fieldPolygons = HatTilingGenerator.patchPolygons(level: 5)
    private static let fieldRecords = fieldPolygons.map { polygon in
        PolygonRecord(
            points: polygon,
            bounds: HatTilingGenerator.boundingBox(for: [polygon])
        )
    }
    private static let fieldBounds = HatTilingGenerator.boundingBox(for: fieldPolygons)
    private static let fieldCenter = CGPoint(
        x: fieldBounds.midX,
        y: fieldBounds.midY
    )
    private static let referenceBounds = HatTilingGenerator.boundingBox(
        for: HatTilingGenerator.polygons(level: 1, tileIndex: 0)
    )
    @MainActor private static var renderedTextureCache: [String: CGImage] = [:]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let request = RenderRequest(size: size, tuning: tuning)

            ZStack {
                Color.white
                    .ignoresSafeArea()

                if let renderedTexture {
                    Image(decorative: renderedTexture, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                }

                Color(
                    hue: tuning.backgroundHue,
                    saturation: tuning.backgroundSaturation,
                    brightness: tuning.backgroundBrightness
                )
                    .opacity(tuning.opacity)
                    .ignoresSafeArea()
            }
            .task(id: request) {
                guard size.width > 0, size.height > 0 else { return }
                renderedTexture = Self.cachedTexture(size: size, tuning: tuning)
            }
        }
    }

    @MainActor
    static func prewarmTexture(size: CGSize, tuning: HatTextureTuning) {
        guard size.width > 0, size.height > 0 else { return }
        _ = cachedTexture(size: size, tuning: tuning)
    }

    @MainActor
    private static func cachedTexture(size: CGSize, tuning: HatTextureTuning) -> CGImage? {
        let cacheKey = textureCacheKey(size: size, tuning: tuning)
        if let cachedTexture = renderedTextureCache[cacheKey] {
            return cachedTexture
        }

        guard let renderedTexture = renderTexture(size: size, tuning: tuning) else {
            return nil
        }

        renderedTextureCache[cacheKey] = renderedTexture
        return renderedTexture
    }

    private static func textureCacheKey(size: CGSize, tuning: HatTextureTuning) -> String {
        [
            "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))",
            String(format: "z%.3f", tuning.zoom),
            String(format: "o%.3f", tuning.opacity),
            String(format: "l%.3f", tuning.lineWidth),
            String(format: "h%.3f", tuning.backgroundHue),
            String(format: "s%.3f", tuning.backgroundSaturation),
            String(format: "b%.3f", tuning.backgroundBrightness)
        ].joined(separator: "|")
    }

    private static func renderTexture(size: CGSize, tuning: HatTextureTuning) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { rendererContext in
            let cgContext = rendererContext.cgContext
            cgContext.setAllowsAntialiasing(true)
            cgContext.setShouldAntialias(true)
            Self.drawField(context: cgContext, size: size, tuning: tuning)
        }
        return image.cgImage
    }

    private static func drawField(
        context: CGContext,
        size: CGSize,
        tuning: HatTextureTuning
    ) {
        let targetWidth = min(size.width, size.height) * 0.42 * tuning.zoom
        let scale = targetWidth / max(Self.referenceBounds.width, 1)
        let viewport = CGRect(
            x: -80,
            y: -80,
            width: size.width + 160,
            height: size.height + 160
        )

        Self.drawTexture(
            context: context,
            polygons: Self.fieldRecords,
            sourceCenter: Self.fieldCenter,
            destinationCenter: CGPoint(
                x: size.width * 0.5,
                y: size.height * 0.54
            ),
            scale: scale,
            viewport: viewport,
            lineWidth: tuning.lineWidth
        )
    }

    private static func drawTexture(
        context: CGContext,
        polygons: [PolygonRecord],
        sourceCenter: CGPoint,
        destinationCenter: CGPoint,
        scale: CGFloat,
        viewport: CGRect,
        lineWidth: CGFloat
    ) {
        for polygon in polygons {
            let transformedBounds = CGRect(
                x: destinationCenter.x + (polygon.bounds.minX - sourceCenter.x) * scale,
                y: destinationCenter.y + (polygon.bounds.minY - sourceCenter.y) * scale,
                width: polygon.bounds.width * scale,
                height: polygon.bounds.height * scale
            )

            guard transformedBounds.intersects(viewport) else { continue }

            let path = CGMutablePath()

            for (index, point) in polygon.points.enumerated() {
                let transformed = Self.transform(
                    point: point,
                    sourceCenter: sourceCenter,
                    destinationCenter: destinationCenter,
                    scale: scale
                )

                if index == 0 {
                    path.move(to: transformed)
                } else {
                    path.addLine(to: transformed)
                }
            }

            path.closeSubpath()
            context.addPath(path)
            context.setStrokeColor(UIColor.black.cgColor)
            context.setLineWidth(max(0.65, scale * 0.138 * lineWidth))
            context.strokePath()
        }
    }

    private static func transform(
        point: CGPoint,
        sourceCenter: CGPoint,
        destinationCenter: CGPoint,
        scale: CGFloat
    ) -> CGPoint {
        let translatedX = (point.x - sourceCenter.x) * scale
        let translatedY = (point.y - sourceCenter.y) * scale

        return CGPoint(
            x: destinationCenter.x + translatedX,
            y: destinationCenter.y + translatedY
        )
    }
}

#Preview("Call Prototype") {
        TurboCallPrototypeView(
            contact: Contact(id: UUID(), name: "Mellow Claude", handle: "@mellow", isOnline: true, channelId: UUID()),
        selectedConversationState: SelectedConversationState(
            relationship: .none,
            detail: .ready,
            statusMessage: "Connected",
            canTransmitNow: true
        ),
        primaryAction: ConversationPrimaryAction(
            kind: .holdToTalk,
            label: "Hold To Talk",
            isEnabled: true,
            style: .accent
        ),
        isTransmitPressActive: false,
        isPTTAudioSessionActive: true,
        mediaConnectionState: .connected,
        mediaSessionContactID: nil,
        transportPathState: .direct,
        audioEncryptionStatus: .endToEndEncrypted,
        localAudioLevel: 0,
        localTelemetry: ConversationParticipantTelemetry(
            audio: .init(routeName: "Speaker", volumePercent: 45),
            connection: .init(interface: .wifi)
        ),
        remoteParticipantTelemetry: ConversationParticipantTelemetry(
            audio: .init(routeName: "Speaker", volumePercent: 70),
            connection: .init(interface: .cellular)
        ),
        onClose: {},
        onLeave: {},
        onJoin: {},
        onBeginTransmit: {},
        onTransmitTouchReleased: {},
        onEndTransmit: { _ in }
    )
}
