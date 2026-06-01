import SwiftUI

enum TurboOnboardingPermissionKind: Equatable {
    case localNetwork
    case microphone
    case notifications

    var title: String {
        switch self {
        case .localNetwork:
            return "Faster nearby audio"
        case .microphone:
            return "Microphone access"
        case .notifications:
            return "Beeps"
        }
    }

    var message: String {
        switch self {
        case .localNetwork:
            return "BeepBeep can find a direct path between nearby devices when it is available."
        case .microphone:
            return "Your microphone is used only while you hold to talk."
        case .notifications:
            return "BeepBeep can let you know when someone asks to talk."
        }
    }

    var allowTitle: String {
        switch self {
        case .localNetwork:
            return "Allow Local Network"
        case .microphone:
            return "Allow Microphone"
        case .notifications:
            return "Allow Notifications"
        }
    }

    var stepIndex: Int {
        switch self {
        case .localNetwork:
            return 1
        case .microphone:
            return 2
        case .notifications:
            return 3
        }
    }

    var symbolName: String {
        switch self {
        case .localNetwork:
            return "point.3.connected.trianglepath.dotted"
        case .microphone:
            return "mic.fill"
        case .notifications:
            return "bell.badge.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .localNetwork:
            return .teal
        case .microphone:
            return .blue
        case .notifications:
            return .orange
        }
    }
}

struct TurboPermissionNoticePrompt {
    let kind: TurboOnboardingPermissionKind
    let title: String
    let message: String
    let actionTitle: String
}

struct TurboPermissionOnboardingView: View {
    let wordmarkName: String
    let permission: TurboOnboardingPermissionKind
    let isRequesting: Bool
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = TurboLayout.contentWidth(for: geometry.size.width)
            let topInset = max(geometry.safeAreaInsets.top + 24, 52)
            let bottomInset = max(geometry.safeAreaInsets.bottom + 22, 28)

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: topInset)

                VStack(spacing: 28) {
                    Image(wordmarkName)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 27)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("BeepBeep")

                    Spacer(minLength: 0)

                    VStack(spacing: 18) {
                        Image(systemName: permission.symbolName)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(permission.accentColor)
                            .frame(width: 66, height: 66)
                            .background(.thinMaterial, in: Circle())
                            .overlay(
                                Circle()
                                    .stroke(permission.accentColor.opacity(0.20), lineWidth: 1)
                            )

                        Text("Step \(permission.stepIndex) of 3")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Text(permission.title)
                            .font(.title.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)

                        Text(permission.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)

                    Spacer(minLength: 0)

                    VStack(spacing: 12) {
                        Button(action: onAllow) {
                            Text(isRequesting ? "Waiting..." : permission.allowTitle)
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)
                        .disabled(isRequesting)

                        Button(action: onSkip) {
                            Text("Maybe Later")
                                .font(.body)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(isRequesting)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(width: columnWidth)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)

                Spacer()
                    .frame(height: bottomInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, TurboLayout.horizontalPadding)
    }
}

struct TurboPermissionNoticeBanner: View {
    let prompt: TurboPermissionNoticePrompt
    let isRequesting: Bool
    let onEnable: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.title)
                    .font(.subheadline.weight(.semibold))
                Text(prompt.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: onEnable) {
                Text(isRequesting ? "Waiting..." : prompt.actionTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isRequesting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(Color.red.opacity(0.18))
        }
    }
}
