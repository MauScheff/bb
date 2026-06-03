import ActivityKit
import Foundation

struct LiveConversationActivityProjection: Equatable {
    let conversationID: String
    let contactHandle: String
    let contactName: String
    let phase: BeepBeepLiveActivityPhase
    let speakerName: String?

    init?(
        contact: Contact,
        selectedConversationState: SelectedConversationState,
        localDisplayName: String,
        hasDevicePTTSession: Bool
    ) {
        guard hasDevicePTTSession else { return nil }
        guard let phase = Self.activityPhase(for: selectedConversationState) else { return nil }
        conversationID = contact.id.uuidString
        contactHandle = contact.handle
        contactName = contact.name
        self.phase = phase
        switch phase {
        case .speaking:
            speakerName = localDisplayName.isEmpty ? "You" : localDisplayName
        case .listening:
            speakerName = contact.name
        case .connecting, .connected, .reconnecting:
            speakerName = nil
        }
    }

    var attributes: BeepBeepLiveActivityAttributes {
        BeepBeepLiveActivityAttributes(
            conversationID: conversationID,
            contactHandle: contactHandle,
            contactName: contactName,
            startedAt: Date()
        )
    }

    var contentState: BeepBeepLiveActivityAttributes.ContentState {
        BeepBeepLiveActivityAttributes.ContentState(
            phase: phase,
            speakerName: speakerName,
            lastUpdatedAt: Date()
        )
    }

    private static func activityPhase(for state: SelectedConversationState) -> BeepBeepLiveActivityPhase? {
        switch state.detail {
        case .friendReady, .waitingForPeer, .startingTransmit:
            return .connecting
        case .wakeReady, .ready, .readyHoldToTalkDisabled:
            return .connected
        case .transmitting:
            return .speaking
        case .receiving:
            return .listening
        case .idle, .outgoingBeep, .incomingBeep, .localJoinFailed, .blockedByOtherSession, .systemMismatch:
            return nil
        }
    }
}

@MainActor
final class LiveConversationActivityController {
    private var activity: Activity<BeepBeepLiveActivityAttributes>?
    private var currentConversationID: String?
    private var lastProjection: LiveConversationActivityProjection?
    var isEnabled: Bool = !ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath")

    func reconcile(_ projection: LiveConversationActivityProjection?) {
        guard isEnabled else { return }

        guard let projection else {
            endActiveActivity()
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            endActiveActivity()
            return
        }

        if currentConversationID != projection.conversationID {
            endActiveActivity()
            startActivity(for: projection)
            return
        }

        guard lastProjection != projection else { return }
        lastProjection = projection
        let content = ActivityContent(state: projection.contentState, staleDate: nil)
        Task {
            await activity?.update(content)
        }
    }

    private func startActivity(for projection: LiveConversationActivityProjection) {
        endPersistedActivities()
        currentConversationID = projection.conversationID
        lastProjection = projection
        let attributes = projection.attributes
        let content = ActivityContent(state: projection.contentState, staleDate: nil)
        Task { @MainActor in
            do {
                activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            } catch {
                activity = nil
                currentConversationID = nil
                lastProjection = nil
            }
        }
    }

    func endActiveActivity() {
        let persistedActivities = Activity<BeepBeepLiveActivityAttributes>.activities
        guard activity != nil || currentConversationID != nil || !persistedActivities.isEmpty else { return }
        let activityToEnd = activity
        activity = nil
        currentConversationID = nil
        lastProjection = nil
        Task {
            await activityToEnd?.end(nil, dismissalPolicy: .immediate)
            for persistedActivity in persistedActivities {
                await persistedActivity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func endPersistedActivities() {
        let persistedActivities = Activity<BeepBeepLiveActivityAttributes>.activities
        guard !persistedActivities.isEmpty else { return }
        Task {
            for persistedActivity in persistedActivities {
                await persistedActivity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
