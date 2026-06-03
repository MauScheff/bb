import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BeepBeepLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        BeepBeepLiveActivityWidget()
    }
}

struct BeepBeepLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BeepBeepLiveActivityAttributes.self) { context in
            BeepBeepLiveActivityLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.contactName)
                            .font(.headline)
                        Text(displayHandle(context.attributes.contactHandle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: openURL(for: context)) {
                        Label("Open", systemImage: "arrow.up.forward")
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let speakerName = context.state.speakerName {
                        Text("\(speakerName) \(context.state.phase == .speaking ? "is talking" : "is live")")
                            .font(.caption)
                            .lineLimit(1)
                    } else {
                        Text("Open the conversation")
                            .font(.caption)
                    }
                }
            } compactLeading: {
                BeepBeepActivityMark(size: 20, showsBackground: false)
            } compactTrailing: {
                Text(shortStatus(for: context.state.phase))
            } minimal: {
                BeepBeepActivityMark(size: 18, showsBackground: false)
            }
            .widgetURL(openURL(for: context))
        }
    }
}

private struct BeepBeepLiveActivityLockScreenView: View {
    let context: ActivityViewContext<BeepBeepLiveActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            BeepBeepActivityMark(size: 44, showsBackground: true)

            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.contactName)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Link(destination: openURL(for: context)) {
                Text("Open")
                    .font(.headline)
                    .frame(minWidth: 52, minHeight: 36)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .activityBackgroundTint(Color(.systemBackground))
        .activitySystemActionForegroundColor(.accentColor)
    }

    private var statusLine: String {
        if let speakerName = context.state.speakerName {
            return context.state.phase == .speaking
                ? "\(speakerName) is talking"
                : "\(speakerName) is live"
        }
        return displayHandle(context.attributes.contactHandle)
    }
}

private func openURL(for context: ActivityViewContext<BeepBeepLiveActivityAttributes>) -> URL {
    conversationURL(for: context, action: "open")
}

private func conversationURL(
    for context: ActivityViewContext<BeepBeepLiveActivityAttributes>,
    action: String
) -> URL {
    var components = URLComponents()
    components.scheme = "beepbeep"
    components.host = "conversation"
    components.queryItems = [
        URLQueryItem(name: "handle", value: context.attributes.contactHandle),
        URLQueryItem(name: "action", value: action),
    ]
    return components.url ?? URL(string: "beepbeep://conversation")!
}

private func displayHandle(_ handle: String) -> String {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "@" }
    return trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"
}

private struct BeepBeepActivityMark: View {
    let size: CGFloat
    let showsBackground: Bool

    var body: some View {
        ZStack {
            if showsBackground {
                Circle()
                    .fill(Color.accentColor)
            }
            Image(systemName: "waveform")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(showsBackground ? .white : Color.accentColor)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private func shortStatus(for phase: BeepBeepLiveActivityPhase) -> String {
    switch phase {
    case .connecting:
        return "..."
    case .connected:
        return "Open"
    case .speaking:
        return "Talk"
    case .listening:
        return "Live"
    case .reconnecting:
        return "..."
    }
}
