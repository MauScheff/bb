import SwiftUI

struct ContactStatusPillModel {
    let text: String
    let tint: Color
}

struct TurboIncomingBeepBanner: View {
    let beep: IncomingBeepSurface
    let onDismiss: () -> Void
    let onAccept: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(beep.contactName) wants to talk")
                    .font(.body.weight(.semibold))
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
            }

            Spacer(minLength: 12)

            if beep.requestCount > 1 {
                Text("\(beep.requestCount)x")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12))
                    .foregroundStyle(.white.opacity(0.72))
                    .clipShape(Capsule())
            }

            Button("Not now", action: onDismiss)
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.72))

            Button(action: onAccept) {
                Text(primaryActionTitle)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.12).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 10)
    }

    private var subtitleText: String {
        if beep.requestCount > 1 {
            return "\(beep.contactHandle) sent \(beep.requestCount) Beeps."
        }
        return "\(beep.contactHandle) sent you a Beep."
    }

    private var primaryActionTitle: String {
        "Connect"
    }
}

struct TurboContactListView: View {
    let activeContact: Contact?
    let systemSessionSubtitle: String?
    let contactSections: ContactListSections
    let activeStatusPill: (Contact) -> ContactStatusPillModel
    let itemStatusPill: (ContactListItem) -> ContactStatusPillModel
    let activeSubtitle: (Contact) -> String
    let itemSubtitle: (ContactListItem) -> String
    let selectContact: (Contact) -> Void
    let longPressContact: (Contact) -> Void
    let endSystemSession: () -> Void

    private struct ContactRowRenderIdentity: Hashable {
        let contactID: UUID
        let section: ConversationListSection?
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Color.clear
                            .frame(height: 0)
                            .id("contact-list-top")

                        if let activeContact {
                            sectionHeader("Active", topPadding: 4)
                            TurboContactRow(
                                title: activeContact.name,
                                subtitle: activeSubtitle(activeContact),
                                pill: activeStatusPill(activeContact),
                                onTap: { selectContact(activeContact) },
                                onLongPress: {
                                    longPressContact(activeContact)
                                }
                            )
                            .id(
                                ContactRowRenderIdentity(
                                    contactID: activeContact.id,
                                    section: nil
                                )
                            )
                            if let systemSessionSubtitle {
                                TurboSystemSessionRow(
                                    subtitle: systemSessionSubtitle,
                                    onEndSession: endSystemSession
                                )
                            }
                        } else if let systemSessionSubtitle {
                            sectionHeader("Active", topPadding: 4)
                            TurboSystemSessionRow(
                                subtitle: systemSessionSubtitle,
                                onEndSession: endSystemSession
                            )
                        }

                        contactSection(
                            .wantsToTalk,
                            items: contactSections.wantsToTalk,
                            topPadding: activeContact == nil ? 4 : 8
                        )
                        contactSection(
                            .readyToTalk,
                            items: contactSections.readyToTalk,
                            topPadding: contactSections.wantsToTalk.isEmpty ? 4 : 8
                        )
                        contactSection(
                            .outgoingBeep,
                            items: contactSections.outgoingBeep,
                            topPadding: contactSections.readyToTalk.isEmpty ? 4 : 8
                        )
                        contactSection(
                            .contacts,
                            items: contactSections.contacts,
                            topPadding: 4
                        )
                    }
                    .padding(.bottom, 16)
                }
            }
            .onChange(of: activeContact?.id) { _, newValue in
                guard newValue != nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("contact-list-top", anchor: .top)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, topPadding: CGFloat) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, topPadding)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func contactSection(
        _ section: ConversationListSection,
        items: [ContactListItem],
        topPadding: CGFloat
    ) -> some View {
        if !items.isEmpty {
            sectionHeader(section.title, topPadding: topPadding)
            ForEach(items) { item in
                TurboContactRow(
                    title: item.contact.name,
                    subtitle: itemSubtitle(item),
                    pill: itemStatusPill(item),
                    onTap: { selectContact(item.contact) },
                    onLongPress: {
                        longPressContact(item.contact)
                    }
                )
                .id(
                    ContactRowRenderIdentity(
                        contactID: item.contact.id,
                        section: section
                    )
                )
            }
        }
    }

}
private struct TurboContactRow: View {
    let title: String
    let subtitle: String
    let pill: ContactStatusPillModel
    let onTap: () -> Void
    let onLongPress: (() -> Void)?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                TurboContactAvatar(name: title, size: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Circle()
                        .fill(pill.tint)
                        .frame(width: 7, height: 7)
                    Text(pill.text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .systemBackground).opacity(0.001))
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    onLongPress?()
                }
        )
    }
}

private struct TurboContactAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(Color(uiColor: .secondarySystemBackground))
            }
            .overlay {
                Circle()
                    .stroke(Color(uiColor: .separator).opacity(0.12), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap(\.first)
            .map { String($0).uppercased() }
        return parts.isEmpty ? "?" : parts.joined()
    }
}

private struct TurboSystemSessionRow: View {
    let subtitle: String
    let onEndSession: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color(uiColor: .secondarySystemBackground), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("PTT session active")
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onEndSession) {
                Text("End")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.09), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End PTT session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct TurboTalkControlsView: View {
    let selectedContactID: UUID?
    let isJoined: Bool
    let activeChannelID: UUID?
    let isTransmitting: Bool
    let isTransmitPressActive: Bool
    let selectedConversationState: (UUID) -> SelectedConversationState
    let beepCooldownRemaining: (UUID, Date) -> Int?
    let joinChannel: () -> Void
    let beginTransmit: () -> Void
    let noteTransmitTouchReleased: () -> Void
    let endTransmit: (String) -> Void
    @State private var holdToTalkGestureState = HoldToTalkGestureState()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if let selectedContactID {
                VStack(spacing: 12) {
                    let selectedConversationState = selectedConversationState(selectedContactID)
                    let isSelectedChannelJoined = isJoined && activeChannelID == selectedContactID
                    let cooldownRemaining = beepCooldownRemaining(selectedContactID, timeline.date)
                    let primaryAction = ConversationStateMachine.primaryAction(
                        selectedConversationState: selectedConversationState,
                        isSelectedChannelJoined: isSelectedChannelJoined,
                        isTransmitting: isTransmitting,
                        beepCooldownRemaining: cooldownRemaining
                    )
                    let effectiveGestureIsActive = isTransmitPressActive
                    let displayedPrimaryAction = HoldToTalkButtonPolicy.displayAction(
                        primaryAction,
                        gestureIsActive: effectiveGestureIsActive
                    )
                    let shouldRenderHoldToTalkControl = HoldToTalkButtonPolicy.shouldRenderHoldToTalkControl(
                        primaryAction,
                        gestureIsActive: effectiveGestureIsActive
                    )

                    if shouldRenderHoldToTalkControl {
                        Text(displayedPrimaryAction.label)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: TurboLayout.primaryButtonMaxWidth, minHeight: 58)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(primaryActionTint(displayedPrimaryAction.style))
                                    .opacity(displayedPrimaryAction.isEnabled ? 1 : 0.45)
                            )
                            .contentShape(Capsule(style: .continuous))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in
                                        guard holdToTalkGestureState.beginIfAllowed(isEnabled: primaryAction.isEnabled) else { return }
                                        beginTransmit()
                                    }
                                    .onEnded { _ in
                                        noteTransmitTouchReleased()
                                        guard holdToTalkGestureState.endTouch() else { return }
                                        endTransmit("touch-ended")
                                    }
                            )
                            .accessibilityAddTraits(.isButton)
                            .opacity(displayedPrimaryAction.isEnabled ? 1 : 0.8)
                    } else {
                        connectActionButton(primaryAction)
                    }

                }
            }
        }
        .onChange(of: selectedContactID) { _, _ in
            if holdToTalkGestureState.cancel() {
                endTransmit("selected-contact-changed")
            }
        }
        .onChange(of: isTransmitPressActive) { _, isActive in
            holdToTalkGestureState.handleMachinePressChanged(isActive: isActive)
        }
        .onChange(of: isJoined) { _, joined in
            if !joined {
                _ = holdToTalkGestureState.cancel()
            }
        }
        .onDisappear {
            if holdToTalkGestureState.cancel() {
                endTransmit("hold-control-disappeared")
            }
        }
    }

    private func primaryActionTint(_ style: ConversationPrimaryActionStyle) -> Color {
        switch style {
        case .accent:
            return .blue
        case .active:
            return .blue
        case .muted:
            return .gray
        }
    }

    private func shouldPromoteConnectAction(_ action: ConversationPrimaryAction) -> Bool {
        action.kind == .connect && action.isEnabled && action.style == .accent
    }

    @ViewBuilder
    private func connectActionButton(_ action: ConversationPrimaryAction) -> some View {
        let label = Text(action.label)
            .font(.headline.weight(.semibold))
            .frame(maxWidth: min(TurboLayout.contentMaxWidth, 340), minHeight: 60)

        if shouldPromoteConnectAction(action) {
            Button(action: joinChannel) {
                label
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(primaryActionTint(action.style))
            .disabled(!action.isEnabled)
        } else {
            Button(action: joinChannel) {
                label
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(primaryActionTint(action.style))
            .disabled(!action.isEnabled)
        }
    }
}

struct TurboContactActionView: View {
    let contact: Contact
    let status: ContactStatusPillModel
    let isJoined: Bool
    let activeChannelID: UUID?
    let isTransmitting: Bool
    let isTransmitPressActive: Bool
    let selectedConversationState: (UUID) -> SelectedConversationState
    let beepCooldownRemaining: (UUID, Date) -> Int?
    let joinChannel: () -> Void
    let beginTransmit: () -> Void
    let noteTransmitTouchReleased: () -> Void
    let endTransmit: (String) -> Void
    let onBack: () -> Void
    let onShowDetails: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                floatingIconButton(
                    systemName: "chevron.left",
                    accessibilityLabel: "Back to contacts",
                    action: onBack
                )

                Spacer(minLength: 0)

                floatingIconButton(
                    systemName: "info",
                    accessibilityLabel: "Contact info",
                    action: onShowDetails
                )
            }
            .padding(.top, 4)

            Spacer(minLength: 34)

            VStack(spacing: 16) {
                TurboContactAvatar(name: contact.name, size: 86)

                VStack(spacing: 10) {
                    Text(contact.name)
                        .font(.title.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    HStack(spacing: 10) {
                        Text(contact.handle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Circle()
                            .fill(status.tint)
                            .frame(width: 8, height: 8)

                        Text(status.text)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                }
            }
            .frame(maxWidth: TurboLayout.contentMaxWidth)

            Spacer(minLength: 36)

            TurboTalkControlsView(
                selectedContactID: contact.id,
                isJoined: isJoined,
                activeChannelID: activeChannelID,
                isTransmitting: isTransmitting,
                isTransmitPressActive: isTransmitPressActive,
                selectedConversationState: selectedConversationState,
                beepCooldownRemaining: beepCooldownRemaining,
                joinChannel: joinChannel,
                beginTransmit: beginTransmit,
                noteTransmitTouchReleased: noteTransmitTouchReleased,
                endTransmit: endTransmit
            )
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func floatingIconButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        TurboGlassIconButton(
            systemName: systemName,
            accessibilityLabel: accessibilityLabel,
            action: action
        )
    }
}

struct HoldToTalkGestureState: Equatable {
    var isTrackingTouch = false
    var requiresReleaseBeforeNextPress = false

    mutating func beginIfAllowed(isEnabled: Bool) -> Bool {
        guard isEnabled else { return false }
        guard !isTrackingTouch else { return false }
        guard !requiresReleaseBeforeNextPress else { return false }
        isTrackingTouch = true
        return true
    }

    mutating func beginTrackingTouch() -> Bool {
        guard !isTrackingTouch else { return false }
        guard !requiresReleaseBeforeNextPress else { return false }
        isTrackingTouch = true
        return true
    }

    mutating func endTouch() -> Bool {
        let shouldEndTransmit = isTrackingTouch
        isTrackingTouch = false
        requiresReleaseBeforeNextPress = false
        return shouldEndTransmit
    }

    mutating func handleMachinePressChanged(isActive: Bool) {
        if !isActive && isTrackingTouch {
            isTrackingTouch = false
            requiresReleaseBeforeNextPress = true
        }
    }

    mutating func cancel() -> Bool {
        let shouldEndTransmit = isTrackingTouch
        isTrackingTouch = false
        requiresReleaseBeforeNextPress = false
        return shouldEndTransmit
    }
}

enum HoldToTalkButtonPolicy {
    static func shouldRenderHoldToTalkControl(
        _ primaryAction: ConversationPrimaryAction,
        gestureIsActive: Bool
    ) -> Bool {
        gestureIsActive || primaryAction.kind == .holdToTalk
    }

    static func displayAction(
        _ primaryAction: ConversationPrimaryAction,
        gestureIsActive: Bool
    ) -> ConversationPrimaryAction {
        guard shouldRenderHoldToTalkControl(primaryAction, gestureIsActive: gestureIsActive) else {
            return primaryAction
        }
        guard gestureIsActive else {
            return primaryAction
        }
        return ConversationPrimaryAction(
            kind: .holdToTalk,
            label: "Release To Stop",
            isEnabled: primaryAction.isEnabled,
            style: .active
        )
    }
}
