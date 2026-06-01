//
//  ContentView.swift
//  Turbo
//
//  Created by Maurice on 20.03.2026.
//

import SwiftUI
import AVFAudio
import UIKit

private enum ContentRoute: Equatable {
    case launchSplash
    case start
    case accountChoice
    case profileSetup
    case handleSetup
    case permissionSetup(TurboOnboardingPermissionKind)
    case live
}

private enum TurboContactActionPrototype {
    static let isEnabled = true
    static let showsListBottomAction = false
}

enum ContactListSelectionDisposition: Equatable {
    case openCall(selectReason: String)
    case focusDetail(selectReason: String)
}

struct RequestedExpandedCallPresentationState: Equatable {
    let focusedContactID: UUID?
    let minimizedCallContactID: UUID?
}

enum CallScreenDismissalAction: Equatable {
    case minimize
    case leave
}

struct CallScreenDismissalPresentationState: Equatable {
    let focusedContactID: UUID?
    let requestedExpandedCallContactID: UUID?
    let minimizedCallContactID: UUID?
}

struct ContentView: View {
    @State private var viewModel: PTTViewModel
    @State private var route: ContentRoute = .launchSplash
    @State private var isShowingAddContactSheet: Bool = false
    @State private var isShowingProfileSheet: Bool = false
    @State private var isShowingDevIdentitySheet: Bool = false
    @State private var isShowingDiagnostics: Bool = false
    @State private var isShowingCallPrototype: Bool = false
    @State private var isShowingTransportPathInfo: Bool = false
    @State private var minimizedCallContactID: UUID?
    @State private var contactDetailsContactID: UUID?
    @State private var focusedContactID: UUID?
    @State private var draftDevUserHandle: String = ""
    @State private var draftFriendReference: String = ""
    @State private var draftExistingIdentityReference: String = ""
    @State private var draftProfileName: String = ""
    @State private var draftHandleBody: String = ""
    @State private var draftLocalContactName: String = ""
    @State private var isSavingDevIdentity: Bool = false
    @State private var isSavingProfileName: Bool = false
    @State private var isCreatingIdentity: Bool = false
    @State private var isSigningOut: Bool = false
    @State private var isRestoringIdentity: Bool = false
    @State private var isOpeningFriend: Bool = false
    @State private var isDeletingContact: Bool = false
    @State private var isResettingDevState: Bool = false
    @State private var isUploadingDiagnostics: Bool = false
    @State private var isRequestingMicrophonePermission: Bool = false
    @State private var isRequestingLocalNetworkPermission: Bool = false
    @State private var isRequestingNotificationPermission: Bool = false
    @State private var isRunningDirectQuicDebugAction: Bool = false
    @State private var diagnosticsUploadStatus: String?
    @State private var shakeReportPresentation: ShakeReportPresentation?
    @State private var lastShakeReportStartedAt: Date?
    @State private var identityRestoreError: String?
    @State private var handleSetupError: String?
    @State private var contactDeleteError: String?
    @Environment(\.colorScheme) private var colorScheme

    @MainActor
    init(viewModel: PTTViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            switch route {
            case .launchSplash:
                launchSplashView
            case .start:
                startView
            case .accountChoice:
                accountChoiceView
            case .profileSetup:
                profileSetupView
            case .handleSetup:
                handleSetupView
            case .permissionSetup(let permission):
                permissionSetupView(permission)
            case .live:
                mainView
            }
        }
        .task {
            await viewModel.initializeIfNeeded()
            if draftProfileName.isEmpty {
                draftProfileName = viewModel.currentProfileName
            }
            if route == .launchSplash {
                route = viewModel.hasCompletedIdentityOnboarding ? .live : .start
            }
        }
        .overlay(alignment: .top) {
            if let activeIncomingBeep = viewModel.activeIncomingBeep {
                TurboIncomingBeepBanner(
                    beep: activeIncomingBeep,
                    onDismiss: viewModel.dismissIncomingBeepSurface,
                    onAccept: {
                        viewModel.acceptIncomingBeepSurface(activeIncomingBeep)
                    }
                )
                .padding(.horizontal)
                .padding(.top, route == .launchSplash ? 18 : 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if isShowingTransportPathInfo {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture {
                            isShowingTransportPathInfo = false
                        }

                    TurboTransportPathInfoModal(
                        onClose: { isShowingTransportPathInfo = false }
                    )
                    .padding(.top, 72)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: viewModel.activeIncomingBeep?.id)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isShowingTransportPathInfo)
        .background {
            ShakeReportDetector {
                startShakeReport()
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onChange(of: viewModel.selectedContactId) { _, _ in
            route = .live
            isShowingAddContactSheet = false
        }
        .onChange(of: callScreenContact?.id) { _, newValue in
            if newValue == nil {
                minimizedCallContactID = nil
            }
        }
        .onChange(of: viewModel.requestedExpandedCallSequence) { _, _ in
            guard let state = requestedExpandedCallPresentationState(
                requestedContactID: viewModel.requestedExpandedCallContactID,
                focusedContactID: focusedContactID,
                minimizedCallContactID: minimizedCallContactID
            ) else { return }
            focusedContactID = state.focusedContactID
            minimizedCallContactID = state.minimizedCallContactID
        }
        .onChange(of: viewModel.currentProfileName) { _, newValue in
            if !isSavingProfileName && !isShowingProfileSheet {
                draftProfileName = newValue
            }
        }
        .sheet(isPresented: $isShowingAddContactSheet) {
            TurboAddContactSheet(
                draftReference: $draftFriendReference,
                currentIdentityHandle: viewModel.currentIdentityHandle,
                currentShareLink: viewModel.currentIdentityShareLink,
                quickFriendHandles: viewModel.quickFriendHandles,
                isOpeningFriend: isOpeningFriend,
                isResettingDevState: isResettingDevState,
                statusMessage: addContactStatusMessage,
                onClose: { isShowingAddContactSheet = false },
                onOpenReference: openFriend
            )
        }
        .sheet(isPresented: $isShowingProfileSheet) {
            TurboProfileSheet(
                draftProfileName: $draftProfileName,
                currentIdentityHandle: viewModel.currentIdentityHandle,
                currentShareLink: viewModel.currentIdentityShareLink,
                isSavingProfileName: isSavingProfileName,
                isSigningOut: isSigningOut,
                showsDeveloperControls: viewModel.developerIdentityControlsEnabled,
                onClose: { isShowingProfileSheet = false },
                onSaveProfileName: saveProfileNameFromSheet,
                onSignOut: signOut,
                onShowDevIdentity: {
                    isShowingProfileSheet = false
                    draftDevUserHandle = viewModel.currentDevUserHandle
                    isShowingDevIdentitySheet = true
                },
                onShowDiagnostics: {
                    isShowingProfileSheet = false
                    isShowingDiagnostics = true
                },
                onShowCallPrototype: {
                    TurboCallPrototypeView.prewarmDefaultTexture()
                    isShowingProfileSheet = false
                    isShowingCallPrototype = true
                },
                onRunSelfCheck: {
                    isShowingProfileSheet = false
                    runSelfCheckAndShowDiagnostics()
                },
                onResetDevState: {
                    isShowingProfileSheet = false
                    resetDevState()
                }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { contactDetailsContactID != nil && detailContact != nil },
                set: { isPresented in
                    if !isPresented {
                        contactDetailsContactID = nil
                        contactDeleteError = nil
                        isDeletingContact = false
                    }
                }
            )
        ) {
            if let detailContact {
                TurboContactDetailSheet(
                    contact: detailContact,
                    draftLocalName: $draftLocalContactName,
                    shareLink: viewModel.contactShareLink(for: detailContact.id) ?? "",
                    did: viewModel.contactDID(for: detailContact.id) ?? "",
                    isDeletingContact: isDeletingContact,
                    deleteErrorMessage: contactDeleteError,
                    onClose: { contactDetailsContactID = nil },
                    onSaveLocalName: saveLocalContactName,
                    onClearLocalName: clearLocalContactName,
                    onDeleteContact: deleteContactFromDetails
                )
            }
        }
        .sheet(isPresented: $isShowingDevIdentitySheet) {
            TurboDevIdentitySheet(
                draftDevUserHandle: $draftDevUserHandle,
                availableDevUserHandles: viewModel.availableDevUserHandles,
                isSaving: isSavingDevIdentity,
                onCancel: { isShowingDevIdentitySheet = false },
                onSave: saveDevIdentity
            )
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            TurboDiagnosticsSheet(
                report: viewModel.latestSelfCheckReport,
                projection: viewModel.stateMachineProjection,
                directQuic: viewModel.developerIdentityControlsEnabled
                    ? viewModel.selectedDirectQuicDiagnosticsSummary
                    : nil,
                microphonePermissionStatus: viewModel.microphonePermissionStatusText,
                needsMicrophonePermission: viewModel.needsMicrophonePermission,
                notificationPermissionStatus: notificationPermissionButtonTitle,
                needsNotificationPermission: viewModel.needsAlertNotificationPermission,
                localNetworkPermissionStatus: viewModel.localNetworkPreflightStatus.detailText,
                uploadStatus: diagnosticsUploadStatus,
                automaticPublishStatusText: viewModel.automaticDiagnosticsPublishStatusText,
                isUploading: isUploadingDiagnostics,
                isRequestingMicrophonePermission: isRequestingMicrophonePermission,
                isRequestingLocalNetworkPermission: isRequestingLocalNetworkPermission,
                isRequestingNotificationPermission: isRequestingNotificationPermission,
                isRunningDirectQuicDebugAction: isRunningDirectQuicDebugAction,
                onClose: { isShowingDiagnostics = false },
                onUpload: uploadDiagnostics,
                onClear: { viewModel.diagnostics.clear() },
                onRequestMicrophonePermission: requestMicrophonePermission,
                onRequestLocalNetworkPermission: requestLocalNetworkPermission,
                onRequestNotificationPermission: requestNotificationPermission,
                onImportDirectQuicIdentity: importDirectQuicIdentityFromDiagnostics,
                onUseInstalledDirectQuicIdentity: useInstalledDirectQuicIdentityFromDiagnostics,
                onSetRelayOnlyForced: setDirectPathRelayOnlyForced,
                onSetDirectQuicAutoUpgradeDisabled: setDirectQuicAutoUpgradeDisabled,
                onSetDirectQuicTransmitStartupPolicy: setDirectQuicTransmitStartupPolicy,
                onSetMediaRelayEnabled: setMediaRelayEnabled,
                onSetMediaRelayForced: setMediaRelayForced,
                onSetMediaRelayConfig: setMediaRelayConfig,
                onSetAudioPacketDiagnosticsEnabled: setAudioPacketDiagnosticsEnabled,
                onForceDirectQuicProbe: forceDirectQuicProbeFromDiagnostics,
                onClearDirectQuicRetryBackoff: clearDirectQuicRetryBackoffFromDiagnostics,
                onCancelDirectQuicAttempt: cancelDirectQuicAttemptFromDiagnostics
            )
        }
        .sheet(
            isPresented: Binding(
                get: { shakeReportPresentation != nil },
                set: { isPresented in
                    if !isPresented {
                        shakeReportPresentation = nil
                    }
                }
            )
        ) {
            if let shakeReportPresentation {
                TurboShakeReportSheet(
                    presentation: shakeReportPresentation,
                    onDone: {
                        self.shakeReportPresentation = nil
                    },
                    onSend: {
                        submitShakeReport(
                            incidentID: shakeReportPresentation.incidentID,
                            requestedAt: Date(),
                            userReport: ""
                        )
                    }
                )
            }
        }
        .fullScreenCover(isPresented: $isShowingCallPrototype) {
            callScreenView(
                contact: callPrototypeContact,
                selectedConversationState: callPrototypeSelectedConversationState,
                primaryAction: callPrototypePrimaryAction,
                onClose: { isShowingCallPrototype = false }
            )
        }
        .fullScreenCover(isPresented: callScreenPresentationBinding) {
            if let contact = callScreenContact {
                callScreenView(
                    contact: contact,
                    selectedConversationState: viewModel.selectedConversationState(for: contact.id),
                    primaryAction: callScreenPrimaryAction(for: contact),
                    onClose: {
                        minimizeCallScreen(for: contact)
                    }
                )
            }
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
            guard let url = userActivity.webpageURL else { return }
            handleIncomingURL(url)
        }
        .onContinueUserActivity("INStartCallIntent") { userActivity in
            handleStartCallUserActivity(userActivity)
        }
    }

    private var mainView: some View {
        let transportPathBadgeState = viewModel.transportPathBadgeState

        return VStack(spacing: 16) {
            if focusedContact == nil {
                TurboHeaderView(
                    statusMessage: nil,
                    transportPathState: transportPathBadgeState,
                    transportPathTint: transportPathTint(
                        for: transportPathBadgeState ?? viewModel.mediaTransportPathState
                    ),
                    diagnosticsPublishStatusText: viewModel.automaticDiagnosticsPublishStatusText,
                    latestErrorText: latestDiagnosticsErrorText,
                    microphonePermissionStatus: viewModel.microphonePermissionStatusText,
                    needsMicrophonePermission: false,
                    notificationPermissionStatus: viewModel.alertNotificationAuthorizationStatusText,
                    needsNotificationPermission: viewModel.needsAlertNotificationPermission,
                    localNetworkPermissionStatus: localNetworkPermissionButtonTitle,
                    showsLocalNetworkPermissionControl: viewModel.localNetworkPreflightStatus.shouldShowMainSurfaceControl,
                    showsResolvedMicrophoneStatus: false,
                    showsDebugPermissionControls: false,
                    showsAddContactButton: !viewModel.contacts.isEmpty,
                    onAddContact: {
                        isShowingAddContactSheet = true
                    },
                    onShowProfile: {
                        draftProfileName = viewModel.currentProfileName
                        isShowingProfileSheet = true
                    },
                    onShowTransportPathInfo: {
                        isShowingTransportPathInfo = true
                    },
                    onRequestMicrophonePermission: requestMicrophonePermission,
                    onRequestLocalNetworkPermission: requestLocalNetworkPermission,
                    onRequestNotificationPermission: requestNotificationPermission
                )
                if let permissionPrompt = missingPermissionPrompt {
                    TurboPermissionNoticeBanner(
                        prompt: permissionPrompt,
                        isRequesting: isRequestingPermission(permissionPrompt.kind),
                        onEnable: { handleMainPermissionPrompt(permissionPrompt.kind) }
                    )
                }
            }
            if viewModel.contacts.isEmpty, viewModel.activeConversationContact == nil {
                if shouldShowContactsLoadingSurface() {
                    TurboContactsLoadingView()
                } else if shouldShowEmptyContactsSurface() {
                    TurboEmptyContactsView(onAddContact: {
                        isShowingAddContactSheet = true
                    })
                } else {
                    TurboContactListView(
                        activeContact: nil,
                        systemSessionSubtitle: systemSessionSubtitle,
                        contactSections: viewModel.contactListSections,
                        activeStatusPill: contactStatusPillModel,
                        itemStatusPill: contactListItemStatusPillModel,
                        activeSubtitle: { viewModel.contactSubtitle(for: $0) },
                        itemSubtitle: contactListItemSubtitle,
                        selectContact: selectContactFromList,
                        longPressContact: handleContactRowLongPress,
                        endSystemSession: viewModel.endSystemSession
                    )
                    .frame(maxHeight: .infinity)
                }
            } else if let focusedContact {
                TurboContactActionView(
                    contact: focusedContact,
                    status: focusedContactStatusPillModel(focusedContact),
                    isJoined: viewModel.isJoined,
                    activeChannelID: viewModel.activeChannelId,
                    isTransmitting: viewModel.isTransmitting,
                    isTransmitPressActive: viewModel.isTransmitPressActive,
                    selectedConversationState: viewModel.selectedConversationState(for:),
                    beepCooldownRemaining: viewModel.beepCooldownRemaining(for:now:),
                    joinChannel: {
                        ensureContactSelected(focusedContact, reason: "focused-contact-action")
                        viewModel.joinChannel()
                    },
                    beginTransmit: {
                        ensureContactSelected(focusedContact, reason: "focused-contact-action")
                        viewModel.beginTransmit()
                    },
                    noteTransmitTouchReleased: viewModel.noteTransmitTouchReleased,
                    endTransmit: { reason in viewModel.endTransmit(reason: reason) },
                    onBack: {
                        focusedContactID = nil
                    },
                    onShowDetails: {
                        showContactDetails(for: focusedContact)
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .task(id: focusedContact.id) {
                    guard viewModel.selectedContactId != focusedContact.id else { return }
                    viewModel.selectContact(focusedContact, reason: "focused-contact")
                }
            } else {
                TurboContactListView(
                    activeContact: viewModel.activeConversationContact,
                    systemSessionSubtitle: systemSessionSubtitle,
                    contactSections: viewModel.contactListSections,
                    activeStatusPill: contactStatusPillModel,
                    itemStatusPill: contactListItemStatusPillModel,
                    activeSubtitle: { viewModel.contactSubtitle(for: $0) },
                    itemSubtitle: contactListItemSubtitle,
                    selectContact: selectContactFromList,
                    longPressContact: handleContactRowLongPress,
                    endSystemSession: viewModel.endSystemSession
                )
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal)
        .padding(.top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.selectedContactId != nil,
               TurboContactActionPrototype.showsListBottomAction || !TurboContactActionPrototype.isEnabled {
                TurboTalkControlsView(
                    selectedContactID: viewModel.selectedContactId,
                    isJoined: viewModel.isJoined,
                    activeChannelID: viewModel.activeChannelId,
                    isTransmitting: viewModel.isTransmitting,
                    isTransmitPressActive: viewModel.isTransmitPressActive,
                    selectedConversationState: viewModel.selectedConversationState(for:),
                    beepCooldownRemaining: viewModel.beepCooldownRemaining(for:now:),
                    joinChannel: viewModel.joinChannel,
                    beginTransmit: viewModel.beginTransmit,
                    noteTransmitTouchReleased: viewModel.noteTransmitTouchReleased,
                    endTransmit: { reason in viewModel.endTransmit(reason: reason) }
                )
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
    }

    private func transportPathTint(for state: MediaTransportPathState) -> Color {
        switch state {
        case .relay:
            return .orange
        case .fastRelay:
            return .teal
        case .fastRelayTcp:
            return .purple
        case .promoting:
            return .blue
        case .direct:
            return .green
        case .recovering:
            return .red
        }
    }

    private var launchSplashView: some View {
        TurboLaunchSplashView(wordmarkName: wordmarkName)
    }

    private var startView: some View {
        TurboStartView(
            wordmarkName: wordmarkName,
            onContinue: {
                if viewModel.hasCompletedIdentityOnboarding {
                    route = .live
                } else {
                    draftExistingIdentityReference = ""
                    identityRestoreError = nil
                    route = .accountChoice
                }
            }
        )
    }

    private var accountChoiceView: some View {
        TurboIdentityChoiceView(
            wordmarkName: wordmarkName,
            draftExistingIdentityReference: $draftExistingIdentityReference,
            isRestoring: isRestoringIdentity,
            errorMessage: identityRestoreError,
            onChooseNew: {
                draftProfileName = viewModel.currentProfileName
                draftHandleBody = TurboHandle.suggestedEditableBody(from: draftProfileName)
                identityRestoreError = nil
                handleSetupError = nil
                route = .profileSetup
            },
            onRestore: restoreExistingIdentityAndContinue
        )
    }

    private var profileSetupView: some View {
        TurboProfileSetupView(
            wordmarkName: wordmarkName,
            draftProfileName: $draftProfileName,
            isSaving: isSavingProfileName,
            onShuffle: shuffleSuggestedProfileName,
            onContinue: continueToHandleSetup
        )
    }

    private var handleSetupView: some View {
        TurboHandleSetupView(
            wordmarkName: wordmarkName,
            draftHandleBody: $draftHandleBody,
            isSaving: isCreatingIdentity,
            errorMessage: handleSetupError,
            onContinue: createIdentityAndContinue
        )
    }

    private func permissionSetupView(_ permission: TurboOnboardingPermissionKind) -> some View {
        TurboPermissionOnboardingView(
            wordmarkName: wordmarkName,
            permission: permission,
            isRequesting: isRequestingPermission(permission),
            onAllow: { requestOnboardingPermissionAndContinue(permission) },
            onSkip: { route = routeAfterPermission(permission) }
        )
    }

    private var wordmarkName: String {
        colorScheme == .dark ? "Wordmark-dark" : "Wordmark-light"
    }

    private var latestDiagnosticsErrorText: String? {
        viewModel.topChromeDiagnosticsErrorText
    }

    private var detailContact: Contact? {
        guard let contactDetailsContactID else { return nil }
        return viewModel.contact(for: contactDetailsContactID)
    }

    private var focusedContact: Contact? {
        guard TurboContactActionPrototype.isEnabled,
              let focusedContactID else {
            return nil
        }
        return viewModel.contact(for: focusedContactID)
    }

    private var callPrototypeContact: Contact {
        viewModel.selectedContact
            ?? viewModel.activeConversationContact
            ?? viewModel.contacts.first
            ?? Contact(id: UUID(), name: "Mellow Claude", handle: "@mellow", isOnline: true, channelId: UUID())
    }

    private var callPrototypeSelectedConversationState: SelectedConversationState {
        guard let contact = viewModel.selectedContact ?? viewModel.activeConversationContact ?? viewModel.contacts.first else {
            return SelectedConversationState(
                relationship: .none,
                detail: .ready,
                statusMessage: "Connected",
                canTransmitNow: true
            )
        }
        return viewModel.selectedConversationState(for: contact.id)
    }

    private var callPrototypePrimaryAction: ConversationPrimaryAction {
        ConversationPrimaryAction(
            kind: .holdToTalk,
            label: "Hold To Talk",
            isEnabled: true,
            style: .accent
        )
    }

    private var callScreenContact: Contact? {
        let candidates = [
            viewModel.selectedContact,
            viewModel.activeConversationContact
        ].compactMap { $0 }

        var seen = Set<UUID>()
        for contact in candidates where !seen.contains(contact.id) {
            seen.insert(contact.id)
            if shouldShowCallScreen(for: contact) {
                return contact
            }
        }
        return nil
    }

    private var callScreenPresentationBinding: Binding<Bool> {
        Binding(
            get: {
                guard route == .live,
                      let contact = callScreenContact else {
                    return false
                }
                return minimizedCallContactID != contact.id
            },
            set: { isPresented in
                guard !isPresented,
                      let contact = callScreenContact else {
                    return
                }
                minimizedCallContactID = contact.id
            }
        )
    }

    private var currentUIProjectionDiagnostics: UIProjectionDiagnostics {
        let contact = callScreenContact
        let selectedConversationState = contact.map { viewModel.selectedConversationState(for: $0.id) }
        let primaryAction = contact.map { callScreenPrimaryAction(for: $0) }
        return UIProjectionDiagnostics(
            route: String(describing: route),
            callScreenVisible: route == .live
                && contact != nil
                && contact.map { minimizedCallContactID != $0.id } == true,
            callScreenContactHandle: contact?.handle,
            callScreenRequestedExpanded: contact.map {
                viewModel.requestedExpandedCallContactID == $0.id
            } ?? false,
            callScreenMinimized: contact.map {
                minimizedCallContactID == $0.id
            } ?? false,
            primaryActionKind: primaryAction.map { String(describing: $0.kind) },
            primaryActionLabel: primaryAction?.label,
            primaryActionEnabled: primaryAction?.isEnabled,
            selectedConversationPhase: selectedConversationState.map { String(describing: $0.phase) } ?? "none",
            selectedConversationStatus: selectedConversationState?.statusMessage ?? "none"
        )
    }

    @ViewBuilder
    private func callScreenView(
        contact: Contact,
        selectedConversationState: SelectedConversationState,
        primaryAction: ConversationPrimaryAction,
        onClose: @escaping () -> Void
    ) -> some View {
        TurboCallPrototypeView(
            contact: contact,
            selectedConversationState: selectedConversationState,
            primaryAction: primaryAction,
            isTransmitPressActive: viewModel.isTransmitPressActive,
            isPTTAudioSessionActive: viewModel.isPTTAudioSessionActive,
            mediaConnectionState: viewModel.mediaConnectionState,
            mediaSessionContactID: viewModel.mediaSessionContactID,
            transportPathState: viewModel.transportPathBadgeState,
            audioEncryptionStatus: viewModel.mediaEndToEndEncryptionIsActive(
                contactID: contact.id,
                channelID: contact.backendChannelId
            ) ? .endToEndEncrypted : .unavailable,
            localAudioLevel: viewModel.localAudioLevel,
            localTelemetry: viewModel.localConversationParticipantTelemetry,
            remoteParticipantTelemetry: viewModel.conversationParticipantTelemetry(for: contact.id),
            onClose: onClose,
            onLeave: {
                leaveCallScreen(for: contact)
                ensureContactSelected(contact, reason: "call-screen-action")
                viewModel.disconnect()
            },
            onJoin: {
                ensureContactSelected(contact, reason: "call-screen-action")
                viewModel.joinChannel()
            },
            onBeginTransmit: {
                ensureContactSelected(contact, reason: "call-screen-action")
                viewModel.beginTransmit()
            },
            onTransmitTouchReleased: viewModel.noteTransmitTouchReleased,
            onEndTransmit: { reason in viewModel.endTransmit(reason: reason) }
        )
    }

    private func shouldShowCallScreen(for contact: Contact) -> Bool {
        let selectedConversationState = viewModel.selectedConversationState(for: contact.id)
        if callScreenHasEstablishedSessionClaim(for: contact),
           !callScreenShouldHideEstablishedSessionDuringDisconnect(
                for: contact,
                selectedConversationState: selectedConversationState
           ) {
            return true
        }
        guard ConversationStateMachine.shouldShowCallScreen(
            selectedConversationState: selectedConversationState,
            requestedExpanded: viewModel.requestedExpandedCallContactID == contact.id
        ) else {
            return false
        }

        switch selectedConversationState.phase {
        case .friendReady:
            return viewModel.requestedExpandedCallContactID == contact.id
        case .incomingBeep:
            return false
        case .waitingForPeer, .ready, .wakeReady, .startingTransmit,
             .transmitting, .receiving, .blockedByOtherSession,
             .systemMismatch, .localJoinFailed:
            return callScreenHasSessionClaim(for: contact, selectedConversationState: selectedConversationState)
        case .idle, .outgoingBeep:
            return false
        }
    }

    private func callScreenHasEstablishedSessionClaim(for contact: Contact) -> Bool {
        if viewModel.isJoined, viewModel.activeChannelId == contact.id {
            return true
        }
        if viewModel.systemSessionMatches(contact.id) {
            return true
        }
        return false
    }

    private func callScreenShouldHideEstablishedSessionDuringDisconnect(
        for contact: Contact,
        selectedConversationState: SelectedConversationState
    ) -> Bool {
        guard selectedConversationState.detail == .waitingForPeer(reason: .disconnecting) else {
            return false
        }
        if viewModel.conversationActionCoordinator.pendingAction.isLeaveInFlight(for: contact.id) {
            return true
        }
        return viewModel.devicePTTRestoreBarrier(for: contact).blocksAutomaticRestore
    }

    private func callScreenHasSessionClaim(
        for contact: Contact,
        selectedConversationState: SelectedConversationState
    ) -> Bool {
        if callScreenHasEstablishedSessionClaim(for: contact) {
            return true
        }
        if viewModel.pendingJoinContactId == contact.id {
            return true
        }
        if viewModel.requestedExpandedCallContactID == contact.id,
           viewModel.pendingConnectAcceptedIncomingBeepContactId == contact.id {
            return true
        }
        return false
    }

    private func callScreenPrimaryAction(for contact: Contact) -> ConversationPrimaryAction {
        let selectedConversationState = viewModel.selectedConversationState(for: contact.id)
        let isSelectedChannelJoined = viewModel.isJoined && viewModel.activeChannelId == contact.id
        return ConversationStateMachine.primaryAction(
            selectedConversationState: selectedConversationState,
            isSelectedChannelJoined: isSelectedChannelJoined,
            isTransmitting: viewModel.isTransmitting,
            beepCooldownRemaining: viewModel.beepCooldownRemaining(for: contact.id, now: Date())
        )
    }

    private func ensureContactSelected(_ contact: Contact, reason: String) {
        guard viewModel.selectedContactId != contact.id else { return }
        viewModel.selectContact(contact, reason: reason)
    }

    private func minimizeCallScreen(for contact: Contact) {
        let state = callScreenDismissalPresentationState(
            for: contact.id,
            action: .minimize,
            focusedContactID: focusedContactID,
            requestedExpandedCallContactID: viewModel.requestedExpandedCallContactID,
            minimizedCallContactID: minimizedCallContactID
        )
        focusedContactID = state.focusedContactID
        viewModel.requestedExpandedCallContactID = state.requestedExpandedCallContactID
        minimizedCallContactID = state.minimizedCallContactID
    }

    private func leaveCallScreen(for contact: Contact) {
        let state = callScreenDismissalPresentationState(
            for: contact.id,
            action: .leave,
            focusedContactID: focusedContactID,
            requestedExpandedCallContactID: viewModel.requestedExpandedCallContactID,
            minimizedCallContactID: minimizedCallContactID
        )
        focusedContactID = state.focusedContactID
        viewModel.requestedExpandedCallContactID = state.requestedExpandedCallContactID
        minimizedCallContactID = state.minimizedCallContactID
    }

    private var addContactStatusMessage: String? {
        if isOpeningFriend {
            return "Opening friend…"
        }
        guard viewModel.backendCommandCoordinator.state.lastError != nil else { return nil }
        return viewModel.backendStatusMessage
    }

    private func openFriend(_ handle: String) {
        beginOpeningFriend(handle)
    }

    private func showContactDetails(for contact: Contact) {
        ensureContactSelected(contact, reason: "contact-details")
        contactDetailsContactID = contact.id
        draftLocalContactName = viewModel.contactLocalName(for: contact.id) ?? ""
        contactDeleteError = nil
        isDeletingContact = false
    }

    private func selectContactFromList(_ contact: Contact) {
        if TurboContactActionPrototype.isEnabled {
            switch contactListSelectionDisposition(for: contact) {
            case .openCall(let selectReason):
                viewModel.selectContact(contact, reason: selectReason)
                minimizedCallContactID = nil
                focusedContactID = nil
            case .focusDetail(let selectReason):
                viewModel.selectContact(contact, reason: selectReason)
                focusedContactID = contact.id
            }
            return
        }

        viewModel.selectContact(contact)
        if shouldShowCallScreen(for: contact) {
            minimizedCallContactID = nil
        }
    }

    func contactListSelectionDisposition(for contact: Contact) -> ContactListSelectionDisposition {
        if shouldShowCallScreen(for: contact) {
            return .openCall(selectReason: "contact-list-active-call")
        }
        return .focusDetail(selectReason: "contact-list-focused-detail")
    }

    func shouldShowContactsLoadingSurface() -> Bool {
        viewModel.contacts.isEmpty
            && viewModel.activeConversationContact == nil
            && systemSessionSubtitle == nil
            && viewModel.shouldShowContactsLoadingPlaceholder
    }

    func shouldShowEmptyContactsSurface() -> Bool {
        viewModel.contacts.isEmpty
            && viewModel.activeConversationContact == nil
            && systemSessionSubtitle == nil
            && !viewModel.shouldShowContactsLoadingPlaceholder
    }

    func shouldShowSystemSessionContactListSurface() -> Bool {
        viewModel.contacts.isEmpty
            && viewModel.activeConversationContact == nil
            && systemSessionSubtitle != nil
    }

    func requestedExpandedCallPresentationState(
        requestedContactID: UUID?,
        focusedContactID: UUID?,
        minimizedCallContactID: UUID?
    ) -> RequestedExpandedCallPresentationState? {
        guard let requestedContactID else { return nil }
        return RequestedExpandedCallPresentationState(
            focusedContactID: nil,
            minimizedCallContactID: minimizedCallContactID == requestedContactID
                ? nil
                : minimizedCallContactID
        )
    }

    func callScreenDismissalPresentationState(
        for contactID: UUID,
        action: CallScreenDismissalAction,
        focusedContactID: UUID?,
        requestedExpandedCallContactID: UUID?,
        minimizedCallContactID: UUID?
    ) -> CallScreenDismissalPresentationState {
        let minimizedCallContactID: UUID? = switch action {
        case .minimize:
            contactID
        case .leave:
            minimizedCallContactID == contactID ? nil : minimizedCallContactID
        }

        return CallScreenDismissalPresentationState(
            focusedContactID: nil,
            requestedExpandedCallContactID: nil,
            minimizedCallContactID: minimizedCallContactID
        )
    }

    private func handleContactRowLongPress(_ contact: Contact) {
        if TurboContactActionPrototype.isEnabled {
            focusedContactID = nil
            viewModel.selectContact(contact, reason: "contact-list-long-press")
            viewModel.joinChannel()
            return
        }

        viewModel.selectContact(contact)
        showContactDetails(for: contact)
    }

    private func saveLocalContactName() {
        guard let contactDetailsContactID else { return }
        viewModel.updateLocalContactName(draftLocalContactName, for: contactDetailsContactID)
        draftLocalContactName = viewModel.contactLocalName(for: contactDetailsContactID) ?? ""
    }

    private func clearLocalContactName() {
        guard let contactDetailsContactID else { return }
        viewModel.updateLocalContactName(nil, for: contactDetailsContactID)
        draftLocalContactName = ""
    }

    private func deleteContactFromDetails() {
        guard let contactDetailsContactID else { return }
        contactDeleteError = nil
        isDeletingContact = true
        Task {
            let deleted = await viewModel.deleteContact(contactDetailsContactID)
            await MainActor.run {
                isDeletingContact = false
                if deleted {
                    draftLocalContactName = ""
                    contactDeleteError = nil
                    self.contactDetailsContactID = nil
                } else {
                    contactDeleteError = viewModel.backendStatusMessage
                }
            }
        }
    }

    private func beginOpeningFriend(_ handle: String, ensureInitialized: Bool = false) {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHandle.isEmpty else { return }
        draftFriendReference = trimmedHandle
        isOpeningFriend = true
        Task {
            if ensureInitialized {
                await viewModel.initializeIfNeeded()
            }
            await viewModel.openFriend(reference: trimmedHandle)
            await MainActor.run {
                isOpeningFriend = false
                if viewModel.backendCommandCoordinator.state.lastError == nil {
                    draftFriendReference = ""
                    isShowingAddContactSheet = false
                    route = .live
                }
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        if let conversationIntent = TurboIncomingLink.conversationOpenIntent(from: url) {
            route = .live
            isShowingAddContactSheet = false
            Task {
                await viewModel.initializeIfNeeded()
                await viewModel.handleConversationOpenIntent(conversationIntent)
            }
            return
        }
        guard let reference = TurboIncomingLink.reference(from: url) else { return }
        route = .live
        isShowingAddContactSheet = false
        beginOpeningFriend(reference, ensureInitialized: true)
    }

    private func handleStartCallUserActivity(_ userActivity: NSUserActivity) {
        route = .live
        isShowingAddContactSheet = false
        Task {
            await viewModel.initializeIfNeeded()
            await viewModel.handleStartCallUserActivity(userActivity)
        }
    }

    private func contactListItemSubtitle(_ item: ContactListItem) -> String {
        viewModel.contactSubtitle(for: item.contact, requestCount: item.presentation.requestCount)
    }

    private func runSelfCheckAndShowDiagnostics() {
        Task {
            await viewModel.runSelfCheck()
            await MainActor.run {
                isShowingDiagnostics = true
            }
        }
    }

    private func resetDevState() {
        isResettingDevState = true
        Task {
            await viewModel.resetDevEnvironment()
            await MainActor.run {
                draftFriendReference = ""
                isResettingDevState = false
                route = .live
            }
        }
    }

    private func saveDevIdentity() {
        let updatedHandle = draftDevUserHandle
        isSavingDevIdentity = true
        Task {
            await viewModel.updateDevUserHandle(updatedHandle)
            await MainActor.run {
                isSavingDevIdentity = false
                isShowingDevIdentitySheet = false
            }
        }
    }

    private func uploadDiagnostics() {
        isUploadingDiagnostics = true
        diagnosticsUploadStatus = nil
        Task {
            do {
                let response = try await viewModel.publishDiagnostics()
                await MainActor.run {
                    diagnosticsUploadStatus =
                        "Uploaded for \(response.report.deviceId) at \(response.report.uploadedAt)"
                    isUploadingDiagnostics = false
                }
            } catch {
                await MainActor.run {
                    diagnosticsUploadStatus = "Upload failed: \(error.localizedDescription)"
                    isUploadingDiagnostics = false
                }
            }
        }
    }

    private func startShakeReport() {
        let now = Date()
        if let lastShakeReportStartedAt,
           now.timeIntervalSince(lastShakeReportStartedAt) < 60 {
            return
        }
        lastShakeReportStartedAt = now
        shakeReportPresentation = ShakeReportPresentation(
            incidentID: "inc_\(UUID().uuidString.lowercased())",
            state: .composing
        )
    }

    private func submitShakeReport(
        incidentID: String,
        requestedAt: Date,
        userReport: String
    ) {
        shakeReportPresentation = ShakeReportPresentation(
            incidentID: incidentID,
            state: .sending
        )
        Task { @MainActor in
            do {
                let result = try await viewModel.submitShakeReport(
                    incidentID: incidentID,
                    requestedAt: requestedAt,
                    userReport: userReport
                )
                updateShakeReportPresentation(incidentID: incidentID, state: .sent(result))
            } catch {
                updateShakeReportPresentation(
                    incidentID: incidentID,
                    state: .failed("Try again in a moment.")
                )
            }
        }
    }

    private func updateShakeReportPresentation(
        incidentID: String,
        state: ShakeReportPresentation.State
    ) {
        guard var presentation = shakeReportPresentation,
              presentation.incidentID == incidentID else {
            return
        }
        presentation.state = state
        shakeReportPresentation = presentation
    }

    private func requestMicrophonePermission() {
        isRequestingMicrophonePermission = true
        Task {
            await viewModel.requestMicrophonePermission()
            await MainActor.run {
                isRequestingMicrophonePermission = false
            }
        }
    }

    private func requestOnboardingPermissionAndContinue(_ permission: TurboOnboardingPermissionKind) {
        Task {
            await performPermissionRequest(permission)
            await MainActor.run {
                route = routeAfterPermission(permission)
            }
        }
    }

    private func handleMainPermissionPrompt(_ permission: TurboOnboardingPermissionKind) {
        switch permission {
        case .microphone where viewModel.microphonePermission == .denied:
            openAppSettings()
        case .notifications where viewModel.notificationAuthorizationStatus == .denied:
            openAppSettings()
        case .localNetwork:
            requestLocalNetworkPermission()
        case .microphone:
            requestMicrophonePermission()
        case .notifications:
            requestNotificationPermission()
        }
    }

    private func performPermissionRequest(_ permission: TurboOnboardingPermissionKind) async {
        await MainActor.run {
            setPermissionRequesting(true, for: permission)
        }

        switch permission {
        case .localNetwork:
            await viewModel.requestLocalNetworkPermissionPreflight()
        case .microphone:
            await viewModel.requestMicrophonePermission()
        case .notifications:
            await viewModel.requestAlertNotificationPermissionPreflight()
        }

        await MainActor.run {
            setPermissionRequesting(false, for: permission)
        }
    }

    private func setPermissionRequesting(_ isRequesting: Bool, for permission: TurboOnboardingPermissionKind) {
        switch permission {
        case .localNetwork:
            isRequestingLocalNetworkPermission = isRequesting
        case .microphone:
            isRequestingMicrophonePermission = isRequesting
        case .notifications:
            isRequestingNotificationPermission = isRequesting
        }
    }

    private func isRequestingPermission(_ permission: TurboOnboardingPermissionKind) -> Bool {
        switch permission {
        case .localNetwork:
            return isRequestingLocalNetworkPermission
        case .microphone:
            return isRequestingMicrophonePermission
        case .notifications:
            return isRequestingNotificationPermission
        }
    }

    private func routeAfterPermission(_ permission: TurboOnboardingPermissionKind) -> ContentRoute {
        let following: [TurboOnboardingPermissionKind]
        switch permission {
        case .localNetwork:
            following = [.microphone, .notifications]
        case .microphone:
            following = [.notifications]
        case .notifications:
            following = []
        }
        return firstPermissionRoute(in: following)
    }

    private func firstPermissionRoute(in permissions: [TurboOnboardingPermissionKind]) -> ContentRoute {
        for permission in permissions where permissionNeedsAttention(permission) {
            return .permissionSetup(permission)
        }
        return .live
    }

    private func permissionNeedsAttention(_ permission: TurboOnboardingPermissionKind) -> Bool {
        switch permission {
        case .localNetwork:
            return viewModel.localNetworkPreflightStatus.shouldShowMainSurfaceControl
        case .microphone:
            return viewModel.needsMicrophonePermission
        case .notifications:
            return viewModel.needsAlertNotificationPermission
        }
    }

    private var missingPermissionPrompt: TurboPermissionNoticePrompt? {
        if viewModel.needsMicrophonePermission {
            return TurboPermissionNoticePrompt(
                kind: .microphone,
                title: "Microphone access needed",
                message: viewModel.microphonePermission == .denied
                    ? "Turn it on in Settings to talk."
                    : "Allow microphone access to talk.",
                actionTitle: viewModel.microphonePermission == .denied ? "Open Settings" : "Allow"
            )
        }

        if viewModel.localNetworkPreflightStatus.shouldShowMainSurfaceControl {
            return TurboPermissionNoticePrompt(
                kind: .localNetwork,
                title: "Local Network helps calls start faster",
                message: "Allow it so nearby devices can connect directly.",
                actionTitle: localNetworkPermissionButtonTitle
            )
        }

        if viewModel.needsAlertNotificationPermission {
            return TurboPermissionNoticePrompt(
                kind: .notifications,
                title: "Notifications are off",
                message: viewModel.notificationAuthorizationStatus == .denied
                    ? "Turn them on in Settings to receive Beeps."
                    : "Allow notifications to receive Beeps.",
                actionTitle: viewModel.notificationAuthorizationStatus == .denied ? "Open Settings" : "Allow"
            )
        }

        return nil
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }

    private var localNetworkPermissionButtonTitle: String {
        if isRequestingLocalNetworkPermission {
            return "Checking local network..."
        }
        switch viewModel.localNetworkPreflightStatus {
        case .notRun:
            return "Enable local network"
        case .running:
            return "Checking local network..."
        case .completed:
            return "Local network enabled"
        case .failed:
            return "Retry local network"
        }
    }

    private var notificationPermissionButtonTitle: String {
        if isRequestingNotificationPermission {
            return "Requesting push notifications..."
        }
        if viewModel.needsAlertNotificationPermission {
            return "Enable push notifications"
        }
        return viewModel.alertNotificationAuthorizationStatusText
    }

    private func requestLocalNetworkPermission() {
        isRequestingLocalNetworkPermission = true
        Task {
            await viewModel.requestLocalNetworkPermissionPreflight()
            await MainActor.run {
                isRequestingLocalNetworkPermission = false
            }
        }
    }

    private func requestNotificationPermission() {
        isRequestingNotificationPermission = true
        Task {
            await viewModel.requestAlertNotificationPermissionPreflight()
            await MainActor.run {
                isRequestingNotificationPermission = false
            }
        }
    }

    private func setDirectPathRelayOnlyForced(_ isForced: Bool) {
        isRunningDirectQuicDebugAction = true
        Task {
            await viewModel.setDirectPathRelayOnlyForcedForDebug(isForced)
            await MainActor.run {
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func setDirectQuicAutoUpgradeDisabled(_ isDisabled: Bool) {
        isRunningDirectQuicDebugAction = true
        Task {
            await viewModel.setDirectQuicAutoUpgradeDisabledForDebug(isDisabled)
            await MainActor.run {
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func setDirectQuicTransmitStartupPolicy(_ policy: DirectQuicTransmitStartupPolicy) {
        viewModel.setDirectQuicTransmitStartupPolicyForDebug(policy)
    }

    private func setMediaRelayEnabled(_ isEnabled: Bool) {
        viewModel.setMediaRelayEnabledForDebug(isEnabled)
    }

    private func setMediaRelayForced(_ isForced: Bool) {
        viewModel.setMediaRelayForcedForDebug(isForced)
    }

    private func setMediaRelayConfig(
        host: String,
        quicPort: UInt16,
        tcpPort: UInt16,
        token: String
    ) {
        viewModel.setMediaRelayConfigForDebug(
            host: host,
            quicPort: quicPort,
            tcpPort: tcpPort,
            token: token
        )
    }

    private func setAudioPacketDiagnosticsEnabled(_ isEnabled: Bool) {
        viewModel.setAudioPacketDiagnosticsEnabledForDebug(isEnabled)
    }

    private func importDirectQuicIdentityFromDiagnostics(fileURL: URL, password: String) {
        isRunningDirectQuicDebugAction = true
        Task {
            await viewModel.importDirectQuicIdentityForDebug(
                from: fileURL,
                password: password
            )
            await MainActor.run {
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func useInstalledDirectQuicIdentityFromDiagnostics() {
        isRunningDirectQuicDebugAction = true
        Task {
            await MainActor.run {
                viewModel.adoptInstalledDirectQuicIdentityForDebug()
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func forceDirectQuicProbeFromDiagnostics() {
        isRunningDirectQuicDebugAction = true
        Task {
            await viewModel.forceSelectedDirectQuicProbeForDebug()
            await MainActor.run {
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func clearDirectQuicRetryBackoffFromDiagnostics() {
        isRunningDirectQuicDebugAction = true
        Task {
            await MainActor.run {
                viewModel.clearSelectedDirectQuicRetryBackoffForDebug()
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func cancelDirectQuicAttemptFromDiagnostics() {
        isRunningDirectQuicDebugAction = true
        Task {
            await viewModel.cancelSelectedDirectQuicAttemptForDebug()
            await MainActor.run {
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func shuffleSuggestedProfileName() {
        draftProfileName = TurboSuggestedProfileName.generate()
    }

    private func restoreExistingIdentityAndContinue() {
        let reference = draftExistingIdentityReference
        isRestoringIdentity = true
        identityRestoreError = nil
        Task {
            let restored = await viewModel.restoreExistingIdentity(from: reference)
            await MainActor.run {
                isRestoringIdentity = false
                if restored {
                    draftProfileName = viewModel.currentProfileName
                    draftHandleBody = TurboHandle.normalizedEditableBody(viewModel.currentIdentityHandle)
                    draftExistingIdentityReference = ""
                    route = firstPermissionRoute(in: [.localNetwork, .microphone, .notifications])
                } else {
                    identityRestoreError = "Couldn’t restore that handle."
                }
            }
        }
    }

    private func continueToHandleSetup() {
        draftHandleBody = TurboHandle.suggestedEditableBody(from: draftProfileName)
        handleSetupError = nil
        route = .handleSetup
    }

    private func createIdentityAndContinue() {
        let profileName = draftProfileName
        let handleBody = TurboHandle.normalizedEditableBody(draftHandleBody)
        guard TurboHandle.isValidEditableBody(handleBody) else {
            handleSetupError = "Use 3–20 lowercase letters or numbers."
            return
        }

        isCreatingIdentity = true
        handleSetupError = nil
        Task {
            let created = await viewModel.createFreshIdentity(
                handle: TurboHandle.canonicalHandle(fromEditableBody: handleBody),
                profileName: profileName
            )
            await MainActor.run {
                isCreatingIdentity = false
                if created {
                    draftProfileName = viewModel.currentProfileName
                    draftHandleBody = handleBody
                    route = firstPermissionRoute(in: [.localNetwork, .microphone, .notifications])
                } else {
                    handleSetupError =
                        viewModel.backendStatusMessage.isEmpty
                        ? "Couldn’t claim that handle."
                        : viewModel.backendStatusMessage
                }
            }
        }
    }

    private func saveProfileNameFromSheet() {
        let profileName = draftProfileName
        isSavingProfileName = true
        Task {
            await viewModel.updateProfileName(profileName, markOnboardingComplete: true)
            await MainActor.run {
                draftProfileName = viewModel.currentProfileName
                isSavingProfileName = false
            }
        }
    }

    private func signOut() {
        isSigningOut = true
        Task {
            await viewModel.signOutToFreshIdentity()
            await MainActor.run {
                isSigningOut = false
                isShowingProfileSheet = false
                draftFriendReference = ""
                draftExistingIdentityReference = ""
                draftProfileName = viewModel.currentProfileName
                draftHandleBody = TurboHandle.suggestedEditableBody(from: draftProfileName)
                identityRestoreError = nil
                handleSetupError = nil
                route = .start
            }
        }
    }

    private var systemSessionSubtitle: String? {
        switch viewModel.systemSessionState {
        case .none:
            return nil
        case .active(let contactID, _):
            return viewModel.contactName(for: contactID).map { "with \($0)" } ?? "Active in iOS"
        case .mismatched:
            return "iOS still holds a session the app cannot reconcile"
        }
    }

    private func contactStatusPillModel(_ contact: Contact) -> ContactStatusPillModel {
        pillModel(
            for: viewModel.contactListItem(for: contact).presentation,
            isActiveConversation: true
        )
    }

    private func focusedContactStatusPillModel(_ contact: Contact) -> ContactStatusPillModel {
        let selectedConversationState = viewModel.selectedConversationState(for: contact.id)
        switch selectedConversationState.phase {
        case .ready, .wakeReady, .startingTransmit, .transmitting, .receiving:
            return ContactStatusPillModel(text: "Connected", tint: .green)
        case .waitingForPeer:
            return ContactStatusPillModel(text: "Connecting", tint: .green)
        case .outgoingBeep:
            return ContactStatusPillModel(text: "Sent", tint: .orange)
        case .incomingBeep:
            return ContactStatusPillModel(text: "Incoming", tint: .orange)
        case .friendReady:
            return ContactStatusPillModel(text: "Ready", tint: .green)
        case .blockedByOtherSession, .systemMismatch, .localJoinFailed:
            return ContactStatusPillModel(text: "Needs attention", tint: .orange)
        case .idle:
            return pillModel(for: viewModel.contactListItem(for: contact).presentation)
        }
    }

    private func contactListItemStatusPillModel(_ item: ContactListItem) -> ContactStatusPillModel {
        pillModel(for: item.presentation)
    }

    private func pillModel(
        for presentation: ContactListPresentation,
        isActiveConversation: Bool = false
    ) -> ContactStatusPillModel {
        switch presentation.availabilityPill {
        case .online:
            return ContactStatusPillModel(
                text: presentation.statusPillText(isActiveConversation: isActiveConversation),
                tint: .green
            )
        case .offline:
            return ContactStatusPillModel(text: presentation.statusPillText(), tint: .gray)
        case .busy:
            return ContactStatusPillModel(text: presentation.statusPillText(), tint: .orange)
        }
    }
}

#Preview {
    ContentView(viewModel: .shared)
}
