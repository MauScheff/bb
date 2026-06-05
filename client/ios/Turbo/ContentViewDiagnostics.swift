import SwiftUI
import UniformTypeIdentifiers

struct TurboDiagnosticsView: View {
    let report: DevSelfCheckReport?
    let projection: StateMachineProjection
    let directQuic: DirectQuicDiagnosticsSummary?
    let microphonePermissionStatus: String
    let needsMicrophonePermission: Bool
    let notificationPermissionStatus: String
    let needsNotificationPermission: Bool
    let localNetworkPermissionStatus: String
    let uploadStatus: String?
    let automaticPublishStatusText: String?
    let isRequestingMicrophonePermission: Bool
    let isRequestingLocalNetworkPermission: Bool
    let isRequestingNotificationPermission: Bool
    let isRunningDirectQuicDebugAction: Bool
    let onRequestMicrophonePermission: () -> Void
    let onRequestLocalNetworkPermission: () -> Void
    let onRequestNotificationPermission: () -> Void
    let onImportDirectQuicIdentity: () -> Void
    let onUseInstalledDirectQuicIdentity: () -> Void
    let onSetRelayOnlyForced: (Bool) -> Void
    let onSetDirectQuicAutoUpgradeDisabled: (Bool) -> Void
    let onSetDirectQuicTransmitStartupPolicy: (DirectQuicTransmitStartupPolicy) -> Void
    let onSetMediaRelayEnabled: (Bool) -> Void
    let onSetMediaRelayForced: (Bool) -> Void
    let onSetMediaRelayConfig: (String, UInt16, UInt16, String) -> Void
    let onSetAudioPacketDiagnosticsEnabled: (Bool) -> Void
    let onSetVoiceMediaCoreMode: (VoiceMediaCoreMode) -> Void
    let onSetBinaryVoicePacketV1Enabled: (Bool) -> Void
    let onForceDirectQuicProbe: () -> Void
    let onClearDirectQuicRetryBackoff: () -> Void
    let onCancelDirectQuicAttempt: () -> Void

    @State private var draftMediaRelayHost: String = ""
    @State private var draftMediaRelayQuicPort: String = "443"
    @State private var draftMediaRelayTcpPort: String = "443"
    @State private var draftMediaRelayToken: String = ""

    private var activeInvariantCandidates: [DiagnosticsInvariantViolationCandidate] {
        projection.devicePTT.derivedInvariantCandidates
    }

    var body: some View {
        List {
            if uploadStatus != nil || automaticPublishStatusText != nil {
                Section("Diagnostics upload") {
                    if let automaticPublishStatusText {
                        Label(automaticPublishStatusText, systemImage: "icloud.and.arrow.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let uploadStatus {
                        Text(uploadStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let report {
                Section("Self-check") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(report.summary)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(report.isPassing ? Color.primary : Color.red)
                            Spacer()
                            Text(report.completedAt.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        if let targetHandle = report.targetHandle {
                            Text("Target: \(targetHandle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(report.steps) { step in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: iconName(for: step.status))
                                    .foregroundStyle(color(for: step.status))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.id.title)
                                        .font(.caption.weight(.semibold))
                                    Text(step.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Selected Conversation") {
                diagnosticsRow("Selected", projection.selectedConversation.selectedHandle ?? "none")
                diagnosticsRow("Phase", projection.selectedConversation.selectedPhase)
                diagnosticsRow("Relationship", projection.selectedConversation.relationship)
                diagnosticsRow("Status", projection.selectedConversation.statusMessage)
                diagnosticsRow("Can transmit", projection.selectedConversation.canTransmitNow ? "yes" : "no")
                diagnosticsRow("Joined locally", projection.selectedConversation.isJoined ? "yes" : "no")
                diagnosticsRow("Transmitting", projection.selectedConversation.isTransmitting ? "yes" : "no")
                diagnosticsRow("Pending action", projection.selectedConversation.pendingAction)
                diagnosticsRow("System session", projection.selectedConversation.systemSession)
                diagnosticsRow("Media state", projection.selectedConversation.mediaState)
                diagnosticsRow("Backend channel status", projection.selectedConversation.backendChannelStatus ?? "none")
                diagnosticsRow("Backend readiness", projection.selectedConversation.backendReadiness ?? "none")
                diagnosticsRow("Backend membership", projection.selectedConversation.backendMembership ?? "none")
                diagnosticsRow("Backend Beep Thread", projection.selectedConversation.backendBeepThreadProjection ?? "none")
                diagnosticsRow("Backend self joined", boolText(projection.selectedConversation.backendSelfJoined))
                diagnosticsRow("Backend peer joined", boolText(projection.selectedConversation.backendPeerJoined))
                diagnosticsRow("Peer device connected", boolText(projection.selectedConversation.backendPeerDeviceConnected))
                diagnosticsRow("Remote audio readiness", projection.selectedConversation.remoteAudioReadiness ?? "unknown")
                diagnosticsRow("Backend can transmit", boolText(projection.selectedConversation.backendCanTransmit))
                diagnosticsRow("Active channel", projection.selectedConversation.activeChannelID ?? "none")
                diagnosticsRow("WebSocket", projection.isWebSocketConnected ? "connected" : "disconnected")
            }

            Section("Active invariants") {
                if activeInvariantCandidates.isEmpty {
                    diagnosticsRow("Current", "none")
                } else {
                    ForEach(activeInvariantCandidates, id: \.invariantID) { invariant in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(invariant.invariantID)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                            Text(invariant.message)
                                .font(.caption)
                            if !invariant.metadata.isEmpty {
                                Text(invariant.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Audio") {
                diagnosticsRow("Microphone", microphonePermissionStatus)
                if needsMicrophonePermission {
                    Button(isRequestingMicrophonePermission ? "Requesting…" : "Enable microphone") {
                        onRequestMicrophonePermission()
                    }
                    .disabled(isRequestingMicrophonePermission)
                }
            }

            Section("Permission preflight") {
                diagnosticsRow("Local network", localNetworkPermissionStatus)
                Button(isRequestingLocalNetworkPermission ? "Checking…" : "Enable local network") {
                    onRequestLocalNetworkPermission()
                }
                .disabled(isRequestingLocalNetworkPermission)

                diagnosticsRow("Push notifications", notificationPermissionStatus)
                if needsNotificationPermission {
                    Button(isRequestingNotificationPermission ? "Requesting…" : "Enable push notifications") {
                        onRequestNotificationPermission()
                    }
                    .disabled(isRequestingNotificationPermission)
                }
            }

            if let directQuic {
                Section("Direct QUIC") {
                    diagnosticsRow("Selected", directQuic.selectedHandle ?? "none")
                    diagnosticsRow("Role", directQuic.role ?? "none")
                    diagnosticsRow("Identity label", directQuic.identityLabel ?? "none")
                    diagnosticsRow("Identity status", directQuic.identityStatus)
                    diagnosticsRow("Installed identities", "\(directQuic.installedIdentityCount)")
                    diagnosticsRow("Path state", directQuic.transportPathState.label)
                    diagnosticsRow("Relay-only override", directQuic.relayOnlyOverride ? "on" : "off")
                    diagnosticsRow("Auto-upgrade", directQuic.autoUpgradeDisabled ? "off" : "on")
                    diagnosticsRow("Media relay enabled", directQuic.mediaRelayEnabled ? "yes" : "no")
                    diagnosticsRow("Media relay forced", directQuic.mediaRelayForced ? "yes" : "no")
                    diagnosticsRow("Media relay configured", directQuic.mediaRelayConfigured ? "yes" : "no")
                    diagnosticsRow("Media relay active", directQuic.mediaRelayActive ? "yes" : "no")
                    diagnosticsRow("Audio packet metadata", directQuic.audioPacketDiagnosticsEnabled ? "on" : "off")
                    diagnosticsRow("Voice media core", directQuic.voiceMediaCoreMode.rawValue)
                    diagnosticsRow("Binary packet v1", directQuic.binaryVoicePacketV1Enabled ? "on" : "off")
                    diagnosticsRow("Media relay host", directQuic.mediaRelayHost ?? "none")
                    diagnosticsRow(
                        "Media relay ports",
                        "\(directQuic.mediaRelayQuicPort.map(String.init) ?? "none") / \(directQuic.mediaRelayTcpPort.map(String.init) ?? "none")"
                    )
                    diagnosticsRow("Backend advertised", directQuic.backendAdvertisesUpgrade ? "yes" : "no")
                    diagnosticsRow("Effective upgrade", directQuic.effectiveUpgradeEnabled ? "yes" : "no")
                    diagnosticsRow("Probe controller", directQuic.probeControllerReady ? "ready" : "idle")
                    diagnosticsRow("Local device", directQuic.localDeviceID ?? "none")
                    diagnosticsRow("Peer device", directQuic.peerDeviceID ?? "none")
                    diagnosticsRow("Attempt", directQuic.attemptID ?? "none")
                    diagnosticsRow("Channel", directQuic.channelID ?? "none")
                    diagnosticsRow("Attempt active", directQuic.isDirectActive ? "yes" : "no")
                    diagnosticsRow("Remote candidates", "\(directQuic.remoteCandidateCount)")
                    diagnosticsRow("End of candidates", directQuic.remoteEndOfCandidates ? "yes" : "no")
                    diagnosticsRow("Started", formattedDateTime(directQuic.attemptStartedAt))
                    diagnosticsRow("Updated", formattedDateTime(directQuic.lastUpdatedAt))
                    diagnosticsRow(
                        "Nominated path",
                        nominatedPathText(directQuic)
                    )
                    diagnosticsRow(
                        "Retry backoff",
                        retryBackoffText(directQuic)
                    )
                    diagnosticsRow("STUN servers", "\(directQuic.stunServerCount)")
                    diagnosticsRow("Promotion timeout", "\(directQuic.promotionTimeoutMilliseconds) ms")
                    diagnosticsRow("Base retry backoff", "\(directQuic.retryBackoffBaseMilliseconds) ms")
                    diagnosticsRow("Transmit startup", directQuic.transmitStartupPolicy.rawValue)

                    Toggle(
                        "Relay-only override",
                        isOn: Binding(
                            get: { directQuic.relayOnlyOverride },
                            set: onSetRelayOnlyForced
                        )
                    )
                    .disabled(isRunningDirectQuicDebugAction)

                    Button {
                        onSetDirectQuicAutoUpgradeDisabled(!directQuic.autoUpgradeDisabled)
                    } label: {
                        Label(
                            directQuic.autoUpgradeDisabled
                                ? "Enable auto-upgrade"
                                : "Disable auto-upgrade",
                            systemImage: directQuic.autoUpgradeDisabled ? "bolt.fill" : "bolt.slash"
                        )
                    }
                    .disabled(isRunningDirectQuicDebugAction)

                    Picker("Transmit startup", selection: Binding(
                        get: { directQuic.transmitStartupPolicy },
                        set: onSetDirectQuicTransmitStartupPolicy
                    )) {
                        Text("Apple-gated").tag(DirectQuicTransmitStartupPolicy.appleGated)
                    }
                    .disabled(isRunningDirectQuicDebugAction)

                    Toggle(
                        "Enable media relay",
                        isOn: Binding(
                            get: { directQuic.mediaRelayEnabled },
                            set: onSetMediaRelayEnabled
                        )
                    )
                    .disabled(isRunningDirectQuicDebugAction)

                    Toggle(
                        "Force media relay",
                        isOn: Binding(
                            get: { directQuic.mediaRelayForced },
                            set: onSetMediaRelayForced
                        )
                    )
                    .disabled(isRunningDirectQuicDebugAction || !directQuic.mediaRelayEnabled)

                    Toggle(
                        "Audio packet metadata",
                        isOn: Binding(
                            get: { directQuic.audioPacketDiagnosticsEnabled },
                            set: onSetAudioPacketDiagnosticsEnabled
                        )
                    )
                    .disabled(isRunningDirectQuicDebugAction)

                    Picker("Voice media core", selection: Binding(
                        get: { directQuic.voiceMediaCoreMode },
                        set: onSetVoiceMediaCoreMode
                    )) {
                        Text("Legacy").tag(VoiceMediaCoreMode.legacyAdaptive)
                        Text("Shadow").tag(VoiceMediaCoreMode.shadowLegacyScheduled)
                        Text("Swift NetEQ").tag(VoiceMediaCoreMode.swiftNetEqV1)
                    }
                    .disabled(isRunningDirectQuicDebugAction)

                    Toggle(
                        "Binary packet v1",
                        isOn: Binding(
                            get: { directQuic.binaryVoicePacketV1Enabled },
                            set: onSetBinaryVoicePacketV1Enabled
                        )
                    )
                    .disabled(isRunningDirectQuicDebugAction)

                    TextField("Relay host", text: $draftMediaRelayHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onAppear {
                            if draftMediaRelayHost.isEmpty {
                                draftMediaRelayHost = directQuic.mediaRelayHost ?? "relay.beepbeep.to"
                            }
                            draftMediaRelayQuicPort = directQuic.mediaRelayQuicPort.map(String.init) ?? "443"
                            draftMediaRelayTcpPort = directQuic.mediaRelayTcpPort.map(String.init) ?? "443"
                        }
                    HStack {
                        TextField("QUIC port", text: $draftMediaRelayQuicPort)
                            .keyboardType(.numberPad)
                        TextField("TCP port", text: $draftMediaRelayTcpPort)
                            .keyboardType(.numberPad)
                    }
                    SecureField("Relay token optional", text: $draftMediaRelayToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        let quicPort = UInt16(draftMediaRelayQuicPort) ?? 443
                        let tcpPort = UInt16(draftMediaRelayTcpPort) ?? 443
                        onSetMediaRelayConfig(
                            draftMediaRelayHost.isEmpty ? "relay.beepbeep.to" : draftMediaRelayHost,
                            quicPort,
                            tcpPort,
                            draftMediaRelayToken
                        )
                    } label: {
                        Label("Save media relay config", systemImage: "square.and.arrow.down")
                    }

                    Text("PKCS#12 controls are a developer fallback. Production Direct QUIC uses the generated local identity and backend fingerprint registration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(isRunningDirectQuicDebugAction ? "Running…" : "Import debug PKCS#12 identity") {
                        onImportDirectQuicIdentity()
                    }
                    .disabled(isRunningDirectQuicDebugAction)

                    Button(isRunningDirectQuicDebugAction ? "Running…" : "Use installed debug identity") {
                        onUseInstalledDirectQuicIdentity()
                    }
                    .disabled(
                        isRunningDirectQuicDebugAction
                            || directQuic.installedIdentityCount == 0
                    )

                    Button(isRunningDirectQuicDebugAction ? "Running…" : "Force probe") {
                        onForceDirectQuicProbe()
                    }
                    .disabled(
                        isRunningDirectQuicDebugAction
                            || directQuic.selectedHandle == nil
                            || directQuic.relayOnlyOverride
                            || directQuic.peerDeviceID == nil
                            || directQuic.attemptID != nil
                    )

                    Button("Clear retry backoff") {
                        onClearDirectQuicRetryBackoff()
                    }
                    .disabled(
                        isRunningDirectQuicDebugAction
                            || directQuic.selectedHandle == nil
                            || directQuic.retryRemainingMilliseconds == nil
                    )

                    Button("Cancel current attempt") {
                        onCancelDirectQuicAttempt()
                    }
                    .disabled(
                        isRunningDirectQuicDebugAction
                            || directQuic.selectedHandle == nil
                            || directQuic.attemptID == nil
                    )
                }
            }

            if !projection.contacts.isEmpty {
                Section("Contacts") {
                    ForEach(projection.contacts) { contact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(contact.handle)
                                .font(.caption.weight(.semibold))
                            Text("online=\(contact.isOnline ? "yes" : "no") listState=\(contact.listState)")
                                .font(.caption.monospaced())
                            Text("section=\(contact.listSection) presence=\(contact.presencePill)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text("badge=\(contact.badgeStatus ?? "none") relationship=\(contact.beepThreadProjection) incoming=\(contact.hasIncomingBeep ? "yes" : "no") outgoing=\(contact.hasOutgoingBeep ? "yes" : "no") requestCount=\(contact.requestCount)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text("incomingBeepCount=\(contact.incomingBeepCount.map(String.init(describing:)) ?? "none") outgoingBeepCount=\(contact.outgoingBeepCount.map(String.init(describing:)) ?? "none")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosticsRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func boolText(_ value: Bool?) -> String {
        guard let value else { return "none" }
        return value ? "yes" : "no"
    }

    private func iconName(for status: DevSelfCheckStatus) -> String {
        switch status {
        case .passed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .skipped:
            return "minus.circle.fill"
        }
    }

    private func color(for status: DevSelfCheckStatus) -> Color {
        switch status {
        case .passed:
            return .green
        case .failed:
            return .red
        case .skipped:
            return .secondary
        }
    }

    private func formattedDateTime(_ value: Date?) -> String {
        guard let value else { return "none" }
        return value.formatted(date: .omitted, time: .standard)
    }

    private func nominatedPathText(_ summary: DirectQuicDiagnosticsSummary) -> String {
        guard let address = summary.nominatedRemoteAddress,
              let port = summary.nominatedRemotePort else {
            return "none"
        }
        let source = summary.nominatedPathSource ?? "unknown"
        let kind = summary.nominatedRemoteCandidateKind ?? "observed"
        return "\(source) \(address):\(port) (\(kind))"
    }

    private func retryBackoffText(_ summary: DirectQuicDiagnosticsSummary) -> String {
        guard let reason = summary.retryReason,
              let category = summary.retryCategory,
              let remainingMilliseconds = summary.retryRemainingMilliseconds else {
            return "none"
        }
        let totalMilliseconds = summary.retryBackoffMilliseconds ?? remainingMilliseconds
        return "\(category) \(remainingMilliseconds)ms remaining of \(totalMilliseconds)ms (\(reason))"
    }
}

struct TurboDevIdentitySheet: View {
    @Binding var draftDevUserHandle: String
    let availableDevUserHandles: [String]
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Current backend user") {
                    TextField("Dev handle", text: $draftDevUserHandle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Use a different handle on each physical device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Suggested handles") {
                    ForEach(availableDevUserHandles, id: \.self) { handle in
                        Button(handle) {
                            draftDevUserHandle = handle
                        }
                    }
                }
            }
            .navigationTitle("Dev Identity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(draftDevUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct TurboDirectQuicIdentityImportSheet: View {
    let fileName: String
    let suggestedLabel: String
    @Binding var password: String
    let isImporting: Bool
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("PKCS#12 file") {
                    Text(fileName)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                Section("Direct QUIC identity") {
                    diagnosticsTextRow("Label", suggestedLabel)
                    SecureField("PKCS#12 password", text: $password)
                        .textContentType(.password)
                }
            }
            .navigationTitle("Import Identity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isImporting ? "Importing…" : "Import", action: onImport)
                        .disabled(isImporting)
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func diagnosticsTextRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

struct TurboDiagnosticsSheet: View {
    let report: DevSelfCheckReport?
    let projection: StateMachineProjection
    let directQuic: DirectQuicDiagnosticsSummary?
    let microphonePermissionStatus: String
    let needsMicrophonePermission: Bool
    let notificationPermissionStatus: String
    let needsNotificationPermission: Bool
    let localNetworkPermissionStatus: String
    let uploadStatus: String?
    let automaticPublishStatusText: String?
    let isUploading: Bool
    let isRequestingMicrophonePermission: Bool
    let isRequestingLocalNetworkPermission: Bool
    let isRequestingNotificationPermission: Bool
    let isRunningDirectQuicDebugAction: Bool
    let onClose: () -> Void
    let onUpload: () -> Void
    let onClear: () -> Void
    let onRequestMicrophonePermission: () -> Void
    let onRequestLocalNetworkPermission: () -> Void
    let onRequestNotificationPermission: () -> Void
    let onImportDirectQuicIdentity: (URL, String) -> Void
    let onUseInstalledDirectQuicIdentity: () -> Void
    let onSetRelayOnlyForced: (Bool) -> Void
    let onSetDirectQuicAutoUpgradeDisabled: (Bool) -> Void
    let onSetDirectQuicTransmitStartupPolicy: (DirectQuicTransmitStartupPolicy) -> Void
    let onSetMediaRelayEnabled: (Bool) -> Void
    let onSetMediaRelayForced: (Bool) -> Void
    let onSetMediaRelayConfig: (String, UInt16, UInt16, String) -> Void
    let onSetAudioPacketDiagnosticsEnabled: (Bool) -> Void
    let onSetVoiceMediaCoreMode: (VoiceMediaCoreMode) -> Void
    let onSetBinaryVoicePacketV1Enabled: (Bool) -> Void
    let onForceDirectQuicProbe: () -> Void
    let onClearDirectQuicRetryBackoff: () -> Void
    let onCancelDirectQuicAttempt: () -> Void

    @State private var isShowingDirectQuicIdentityImporter: Bool = false
    @State private var pendingDirectQuicIdentityImportURL: URL?
    @State private var draftDirectQuicIdentityPassword: String = ""
    @State private var isShowingDirectQuicIdentityImportSheet: Bool = false

    var body: some View {
        NavigationStack {
            TurboDiagnosticsView(
                report: report,
                projection: projection,
                directQuic: directQuic,
                microphonePermissionStatus: microphonePermissionStatus,
                needsMicrophonePermission: needsMicrophonePermission,
                notificationPermissionStatus: notificationPermissionStatus,
                needsNotificationPermission: needsNotificationPermission,
                localNetworkPermissionStatus: localNetworkPermissionStatus,
                uploadStatus: uploadStatus,
                automaticPublishStatusText: automaticPublishStatusText,
                isRequestingMicrophonePermission: isRequestingMicrophonePermission,
                isRequestingLocalNetworkPermission: isRequestingLocalNetworkPermission,
                isRequestingNotificationPermission: isRequestingNotificationPermission,
                isRunningDirectQuicDebugAction: isRunningDirectQuicDebugAction,
                onRequestMicrophonePermission: onRequestMicrophonePermission,
                onRequestLocalNetworkPermission: onRequestLocalNetworkPermission,
                onRequestNotificationPermission: onRequestNotificationPermission,
                onImportDirectQuicIdentity: {
                    isShowingDirectQuicIdentityImporter = true
                },
                onUseInstalledDirectQuicIdentity: onUseInstalledDirectQuicIdentity,
                onSetRelayOnlyForced: onSetRelayOnlyForced,
                onSetDirectQuicAutoUpgradeDisabled: onSetDirectQuicAutoUpgradeDisabled,
                onSetDirectQuicTransmitStartupPolicy: onSetDirectQuicTransmitStartupPolicy,
                onSetMediaRelayEnabled: onSetMediaRelayEnabled,
                onSetMediaRelayForced: onSetMediaRelayForced,
                onSetMediaRelayConfig: onSetMediaRelayConfig,
                onSetAudioPacketDiagnosticsEnabled: onSetAudioPacketDiagnosticsEnabled,
                onSetVoiceMediaCoreMode: onSetVoiceMediaCoreMode,
                onSetBinaryVoicePacketV1Enabled: onSetBinaryVoicePacketV1Enabled,
                onForceDirectQuicProbe: onForceDirectQuicProbe,
                onClearDirectQuicRetryBackoff: onClearDirectQuicRetryBackoff,
                onCancelDirectQuicAttempt: onCancelDirectQuicAttempt
            )
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isUploading ? "Uploading…" : "Upload", action: onUpload)
                        .disabled(isUploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clear", action: onClear)
                        .disabled(isUploading)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $isShowingDirectQuicIdentityImportSheet) {
            TurboDirectQuicIdentityImportSheet(
                fileName: pendingDirectQuicIdentityImportURL?.lastPathComponent ?? "Identity",
                suggestedLabel: directQuic?.identityLabel ?? "pending",
                password: $draftDirectQuicIdentityPassword,
                isImporting: isRunningDirectQuicDebugAction,
                onCancel: {
                    pendingDirectQuicIdentityImportURL = nil
                    draftDirectQuicIdentityPassword = ""
                    isShowingDirectQuicIdentityImportSheet = false
                },
                onImport: {
                    guard let fileURL = pendingDirectQuicIdentityImportURL else { return }
                    onImportDirectQuicIdentity(fileURL, draftDirectQuicIdentityPassword)
                    pendingDirectQuicIdentityImportURL = nil
                    draftDirectQuicIdentityPassword = ""
                    isShowingDirectQuicIdentityImportSheet = false
                }
            )
        }
        .fileImporter(
            isPresented: $isShowingDirectQuicIdentityImporter,
            allowedContentTypes: [UTType(importedAs: "com.rsa.pkcs-12")]
        ) { result in
            switch result {
            case .success(let url):
                pendingDirectQuicIdentityImportURL = url
                draftDirectQuicIdentityPassword = ""
                isShowingDirectQuicIdentityImportSheet = true
            case .failure:
                break
            }
        }
    }
}
