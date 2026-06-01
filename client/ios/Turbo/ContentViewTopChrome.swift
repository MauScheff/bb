import SwiftUI

struct TurboHeaderView: View {
    let statusMessage: String?
    let transportPathState: MediaTransportPathState?
    let transportPathTint: Color
    let diagnosticsPublishStatusText: String?
    let latestErrorText: String?
    let microphonePermissionStatus: String
    let needsMicrophonePermission: Bool
    let notificationPermissionStatus: String
    let needsNotificationPermission: Bool
    let localNetworkPermissionStatus: String
    let showsLocalNetworkPermissionControl: Bool
    let showsResolvedMicrophoneStatus: Bool
    let showsDebugPermissionControls: Bool
    let showsAddContactButton: Bool
    let onAddContact: () -> Void
    let onShowProfile: () -> Void
    let onShowTransportPathInfo: () -> Void
    let onRequestMicrophonePermission: () -> Void
    let onRequestLocalNetworkPermission: () -> Void
    let onRequestNotificationPermission: () -> Void

    private let navigationButtonWidth: CGFloat = TurboGlassIconButton.size

    var body: some View {
        let trailingButtonCount = showsAddContactButton ? 1 : 0
        let sideWidth = navigationButtonWidth * CGFloat(max(1, trailingButtonCount))
            + 12 * CGFloat(max(0, trailingButtonCount - 1))

        VStack(spacing: 8) {
            ZStack {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, sideWidth + 20)
                }

                HStack(spacing: 12) {
                    headerIconButton(
                        systemName: "person.crop.circle",
                        accessibilityLabel: "Profile",
                        action: onShowProfile
                    )

                    Spacer(minLength: 0)

                    if showsAddContactButton {
                        headerIconButton(
                            systemName: "plus",
                            accessibilityLabel: "Add friend",
                            action: onAddContact
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            if let transportPathState {
                Button(action: onShowTransportPathInfo) {
                    TurboTransportPathBadge(
                        state: transportPathState,
                        tint: transportPathTint
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(transportPathState.label) connection path")
                .accessibilityHint("Shows what the connection badge means")
            }

            if let diagnosticsPublishStatusText {
                Label(diagnosticsPublishStatusText, systemImage: "icloud.and.arrow.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            if needsMicrophonePermission {
                Button(action: onRequestMicrophonePermission) {
                    Text(microphonePermissionStatus)
                        .font(.caption2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else if showsResolvedMicrophoneStatus {
                Text(microphonePermissionStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if showsDebugPermissionControls {
                VStack(spacing: 6) {
                    if showsLocalNetworkPermissionControl {
                        Button(action: onRequestLocalNetworkPermission) {
                            Text(localNetworkPermissionStatus)
                                .font(.caption2.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text(localNetworkPermissionStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if needsNotificationPermission {
                        Button(action: onRequestNotificationPermission) {
                            Text(notificationPermissionStatus)
                                .font(.caption2.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text(notificationPermissionStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let latestErrorText {
                Text(latestErrorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private func headerIconButton(
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

struct TurboGlassIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    static let size: CGFloat = 48

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct TurboTransportPathInfoModal: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Text("Connection types")
                    .font(.headline.weight(.semibold))

                Spacer(minLength: 8)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.thinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            VStack(alignment: .leading, spacing: 12) {
                TurboTransportPathInfoRow(
                    state: .direct,
                    tint: .green,
                    description: "Fast device-to-device audio. Needs Local Network access."
                )

                TurboTransportPathInfoRow(
                    state: .relay,
                    tint: .orange,
                    description: "Audio passes through BeepBeep when direct is not available."
                )

                TurboTransportPathInfoRow(
                    state: .fastRelay,
                    tint: .teal,
                    description: "Low-latency relayed audio through BeepBeep when direct is blocked."
                )
            }

            Text("The call shows when end-to-end encryption is active. We use the fastest connection available automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        .padding(.horizontal, 18)
    }
}

private struct TurboTransportPathInfoRow: View {
    let state: MediaTransportPathState
    let tint: Color
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TurboTransportPathBadge(state: state, tint: tint)

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TurboTransportPathBadge: View {
    let state: MediaTransportPathState
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            if state.showsSecureIcon {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
            }

            Text(state.label)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(tint.opacity(state == .direct ? 0.24 : 0.12), lineWidth: 1)
        )
        .foregroundStyle(state == .direct ? tint : .secondary)
    }
}

struct TurboEmptyContactsView: View {
    let onAddContact: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()
                .frame(height: 18)

            VStack(spacing: 6) {
                Text("No contacts yet")
                    .font(.title3.weight(.semibold))

                Text("Add someone by QR, link, or handle to start talking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
                .frame(height: 26)

            Button(action: onAddContact) {
                Text("Add Friend")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)
        }
        .frame(maxWidth: TurboLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct TurboContactsLoadingView: View {
    var body: some View {
        VStack(spacing: 0) {
            ProgressView()
                .controlSize(.large)

            Spacer()
                .frame(height: 18)

            VStack(spacing: 6) {
                Text("Restoring session")
                    .font(.title3.weight(.semibold))

                Text("Your contacts will appear in a moment.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: TurboLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct TurboLaunchSplashView: View {
    let wordmarkName: String

    var body: some View {
        GeometryReader { geometry in
            let topInset = max(geometry.size.height * 0.42, 180)

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: topInset)

                Image(wordmarkName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 42)
                    .frame(maxWidth: TurboLayout.contentMaxWidth)
                    .accessibilityLabel("BeepBeep")

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, TurboLayout.horizontalPadding)
    }
}

struct TurboStartView: View {
    let wordmarkName: String
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let buttonWidth = TurboLayout.primaryButtonWidth(for: geometry.size.width)
            let columnWidth = TurboLayout.contentWidth(for: geometry.size.width)
            let topInset = max(geometry.safeAreaInsets.top + 24, 52)
            let bottomInset = max(geometry.safeAreaInsets.bottom + 20, 28)

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: topInset)

                VStack(spacing: 0) {
                    Image(wordmarkName)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 31)
                        .accessibilityLabel("BeepBeep")

                    Spacer(minLength: 0)

                    VStack(spacing: 14) {
                        Text("Voice, when it matters.")
                            .font(.title.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.84)

                        Text("A quiet way to reach the people you trust.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                        .frame(height: 34)

                    VStack(spacing: 16) {
                        TurboStartStepRow(
                            symbolName: "person.crop.circle.badge.plus",
                            title: "Choose a handle",
                            subtitle: "How close contacts recognize you."
                        )
                        TurboStartStepRow(
                            symbolName: "mic.fill",
                            title: "Allow microphone",
                            subtitle: "Used only while you hold to talk."
                        )
                        TurboStartStepRow(
                            symbolName: "bell.badge.fill",
                            title: "Allow requests",
                            subtitle: "Asked only when BeepBeep needs it."
                        )
                    }

                    Spacer(minLength: 0)

                    Button(action: onContinue) {
                        Text("Continue")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .frame(width: buttonWidth)
                }
                .frame(width: columnWidth)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)

                Spacer()
                    .frame(height: bottomInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, TurboLayout.horizontalPadding)
    }
}

private struct TurboStartStepRow: View {
    let symbolName: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.thinMaterial, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
