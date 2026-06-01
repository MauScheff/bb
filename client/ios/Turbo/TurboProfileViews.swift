import SwiftUI
import UIKit

struct TurboIdentityChoiceView: View {
    let wordmarkName: String
    @Binding var draftExistingIdentityReference: String
    let isRestoring: Bool
    let errorMessage: String?
    let onChooseNew: () -> Void
    let onRestore: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = TurboLayout.contentWidth(for: geometry.size.width)
            let topInset = max(geometry.size.height * 0.12, 56)
            let wordmarkGap = max(geometry.size.height * 0.1, 44)
            let choiceGap = max(geometry.size.height * 0.08, 36)

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: topInset)

                VStack(spacing: 0) {
                    Image(wordmarkName)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("BeepBeep")

                    Spacer()
                        .frame(height: wordmarkGap)

                    VStack(spacing: 18) {
                        Button(action: onChooseNew) {
                            Text("I'm New")
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)

                        Text("or")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        VStack(spacing: 12) {
                            Text("Enter your handle")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .center)

                            TextField("", text: $draftExistingIdentityReference)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body)
                                .turboFieldStyle()

                            Button(action: onRestore) {
                                Text(isRestoring ? "Restoring…" : "Continue")
                                    .frame(maxWidth: .infinity, minHeight: 50)
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)
                            .disabled(
                                draftExistingIdentityReference
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty || isRestoring
                            )

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.top, choiceGap)
                }
                .frame(width: columnWidth)
                .frame(maxWidth: .infinity)

                Spacer(minLength: 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, TurboLayout.horizontalPadding)
    }
}

struct TurboProfileSetupView: View {
    let wordmarkName: String
    @Binding var draftProfileName: String
    let isSaving: Bool
    let onShuffle: () -> Void
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = TurboLayout.contentWidth(for: geometry.size.width)
            let topInset = max(geometry.size.height * 0.12, 56)
            let wordmarkGap = max(geometry.size.height * 0.1, 44)
            let copyGap = max(geometry.size.height * 0.05, 28)
            let bottomInset = max(geometry.safeAreaInsets.bottom + 24, 28)

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: topInset)

                VStack(spacing: 0) {
                    Image(wordmarkName)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("BeepBeep")

                    Spacer()
                        .frame(height: wordmarkGap)

                    VStack(spacing: 10) {
                        Text("Choose a name")
                            .font(.system(size: 32, weight: .semibold, design: .default))
                            .tracking(-0.6)

                        Text("People will see this with your handle when you share your BeepBeep. You can change it later.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                    Spacer()
                        .frame(height: copyGap)

                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            TextField("Name", text: $draftProfileName)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .font(.body)
                                .turboFieldStyle()

                            Button(action: onShuffle) {
                                Image(systemName: "shuffle")
                                    .font(.body.weight(.semibold))
                                    .frame(width: 50, height: 50)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Shuffle suggested name")
                        }

                        Button(action: onContinue) {
                            Text(isSaving ? "Saving…" : "Continue")
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)
                        .disabled(draftProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(width: columnWidth)
                .frame(maxWidth: .infinity)

                Spacer(minLength: bottomInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, TurboLayout.horizontalPadding)
    }
}

struct TurboHandleSetupView: View {
    let wordmarkName: String
    @Binding var draftHandleBody: String
    let isSaving: Bool
    let errorMessage: String?
    let onContinue: () -> Void

    private var validationMessage: String? {
        let trimmed = draftHandleBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard TurboHandle.isValidEditableBody(trimmed) else {
            return "Use 3–20 lowercase letters or numbers."
        }
        return nil
    }

    private var previewHandle: String {
        TurboHandle.canonicalHandle(fromEditableBody: draftHandleBody)
    }

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = TurboLayout.contentWidth(for: geometry.size.width)
            let topInset = max(geometry.size.height * 0.12, 56)
            let wordmarkGap = max(geometry.size.height * 0.1, 44)
            let copyGap = max(geometry.size.height * 0.05, 28)
            let bottomInset = max(geometry.safeAreaInsets.bottom + 24, 28)

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: topInset)

                VStack(spacing: 0) {
                    Image(wordmarkName)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("BeepBeep")

                    Spacer()
                        .frame(height: wordmarkGap)

                    VStack(spacing: 10) {
                        Text("Choose a handle")
                            .font(.system(size: 32, weight: .semibold, design: .default))
                            .tracking(-0.6)

                        Text("People will use this to add you. You only choose it once.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                    Spacer()
                        .frame(height: copyGap)

                    VStack(spacing: 12) {
                        HStack(spacing: 2) {
                            Text("@")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)

                            TextField(
                                "handle",
                                text: Binding(
                                    get: { draftHandleBody },
                                    set: { draftHandleBody = TurboHandle.normalizedEditableBody($0) }
                                )
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .font(.body)
                        }
                        .turboFieldStyle()

                        Text("beepbeep.to/\(previewHandle)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        if let validationMessage {
                            Text(validationMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        Spacer()
                            .frame(height: 8)

                        Button(action: onContinue) {
                            Text(isSaving ? "Creating…" : "Continue")
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)
                        .disabled(!TurboHandle.isValidEditableBody(draftHandleBody) || isSaving)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(width: columnWidth)
                .frame(maxWidth: .infinity)

                Spacer(minLength: bottomInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, TurboLayout.horizontalPadding)
    }
}

struct TurboProfileSheet: View {
    @Binding var draftProfileName: String
    let currentIdentityHandle: String
    let currentShareLink: String
    let isSavingProfileName: Bool
    let isSigningOut: Bool
    let showsDeveloperControls: Bool
    let onClose: () -> Void
    let onSaveProfileName: () -> Void
    let onSignOut: () -> Void
    let onShowDevIdentity: () -> Void
    let onShowDiagnostics: () -> Void
    let onShowCallPrototype: () -> Void
    let onRunSelfCheck: () -> Void
    let onResetDevState: () -> Void

    private var shareURL: URL? {
        URL(string: currentShareLink)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let columnWidth = TurboLayout.contentWidth(for: geometry.size.width)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        profileCard
                        identityCard

                        if showsDeveloperControls {
                            developerCard
                        }

                        Button(role: .destructive, action: onSignOut) {
                            Text(isSigningOut ? "Signing Out…" : "Sign Out")
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)
                        .padding(.top, 28)
                        .disabled(isSigningOut || isSavingProfileName)
                    }
                    .frame(width: columnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, TurboLayout.horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    private var profileCard: some View {
        TurboSection(
            title: "Your name",
            subtitle: "You can change this later."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: $draftProfileName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .turboFieldStyle()

                Button(action: onSaveProfileName) {
                    Text(isSavingProfileName ? "Saving…" : "Save Name")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)
                .disabled(draftProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingProfileName || isSigningOut)
            }
        }
    }

    private var identityCard: some View {
        TurboSection(
            title: "Your BeepBeep",
            subtitle: "This is the handle and link tied to this BeepBeep identity."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Handle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(currentIdentityHandle)
                        .font(.headline)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Share link")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(currentShareLink)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Button("Copy Handle") {
                        UIPasteboard.general.string = currentIdentityHandle
                    }
                    .buttonStyle(.bordered)

                    Button("Copy Link") {
                        UIPasteboard.general.string = currentShareLink
                    }
                    .buttonStyle(.bordered)

                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Text("Share")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var developerCard: some View {
        TurboSection(
            title: "Developer",
            subtitle: "Debug-only tools stay here, not in the main flow.",
            showsDivider: false
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Button("Choose Dev Identity", action: onShowDevIdentity)
                    .buttonStyle(.bordered)

                Button("Diagnostics", action: onShowDiagnostics)
                    .buttonStyle(.bordered)

                Button("Call Prototype", action: onShowCallPrototype)
                    .buttonStyle(.bordered)

                Button("Run Self-Check", action: onRunSelfCheck)
                    .buttonStyle(.bordered)

                Button("Reset Dev State", role: .destructive, action: onResetDevState)
                    .buttonStyle(.bordered)
            }
        }
    }
}
