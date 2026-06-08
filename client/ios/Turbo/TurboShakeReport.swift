import SwiftUI
import UIKit

struct ShakeReportResult: Equatable {
    let incidentID: String
    let deviceID: String
    let uploadedAt: String
    let diagnosticsLatestURL: String?
}

struct ShakeReportPresentation: Equatable {
    enum State: Equatable {
        case composing
        case sending
        case sent(ShakeReportResult)
        case failed(String)
    }

    let incidentID: String
    var state: State
}

struct ShakeReportSensitivityPolicy: Equatable {
    var minimumShakeDuration: TimeInterval = 0.55

    func acceptsShake(startedAt: Date?, endedAt: Date) -> Bool {
        guard let startedAt else { return false }
        return endedAt.timeIntervalSince(startedAt) >= minimumShakeDuration
    }
}

struct ShakeReportStartPolicy: Equatable {
    func canStart(activePresentation: ShakeReportPresentation?) -> Bool {
        activePresentation == nil
    }
}

struct TurboShakeReportSheet: View {
    let presentation: ShakeReportPresentation
    let onDone: () -> Void
    let onSend: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                statusIcon

                VStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actionArea
            }
            .padding(.horizontal, TurboLayout.horizontalPadding)
            .padding(.vertical, 24)
            .frame(maxWidth: TurboLayout.contentMaxWidth)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                        .disabled(isSending)
                }
            }
        }
        .presentationDetents([presentationDetent])
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch presentation.state {
        case .composing:
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.blue)
        case .sending:
            ProgressView()
                .controlSize(.large)
        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }

    private var title: String {
        switch presentation.state {
        case .composing:
            return "Report a problem"
        case .sending:
            return "Sending report..."
        case .sent:
            return "Report sent"
        case .failed:
            return "Couldn't send report"
        }
    }

    private var message: String {
        switch presentation.state {
        case .composing:
            return "We'll include recent diagnostics so you don't have to type anything."
        case .sending:
            return "Thanks. We're collecting recent diagnostics."
        case .sent:
            return "Thanks. We'll take a look."
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch presentation.state {
        case .composing:
            Button("Send Report") {
                onSend()
            }
            .buttonStyle(.borderedProminent)
        case .sending:
            EmptyView()
        case .sent:
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
        case .failed:
            HStack(spacing: 12) {
                Button("Done", action: onDone)
                    .buttonStyle(.bordered)
                Button("Try Again") {
                    onSend()
                }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var isSending: Bool {
        if case .sending = presentation.state {
            return true
        }
        return false
    }

    private var presentationDetent: PresentationDetent {
        switch presentation.state {
        case .composing:
            return .height(260)
        default:
            return .height(240)
        }
    }
}

struct ShakeReportDetector: UIViewRepresentable {
    let onShake: () -> Void

    func makeUIView(context: Context) -> ShakeReportDetectorView {
        let view = ShakeReportDetectorView()
        view.onShake = onShake
        return view
    }

    func updateUIView(_ uiView: ShakeReportDetectorView, context: Context) {
        uiView.onShake = onShake
    }
}

final class ShakeReportDetectorView: UIView {
    var onShake: (() -> Void)?
    var sensitivityPolicy = ShakeReportSensitivityPolicy()

    private var shakeStartedAt: Date?

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            _ = self?.becomeFirstResponder()
        }
    }

    override func motionBegan(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else { return }
        shakeStartedAt = Date()
    }

    override func motionCancelled(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else { return }
        shakeStartedAt = nil
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else { return }
        defer { shakeStartedAt = nil }
        guard sensitivityPolicy.acceptsShake(startedAt: shakeStartedAt, endedAt: Date()) else {
            return
        }
        onShake?()
    }
}
