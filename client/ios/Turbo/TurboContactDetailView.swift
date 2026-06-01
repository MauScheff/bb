import SwiftUI
import UIKit

struct TurboContactDetailSheet: View {
    let contact: Contact
    @Binding var draftLocalName: String
    let shareLink: String
    let did: String
    let isDeletingContact: Bool
    let deleteErrorMessage: String?
    let onClose: () -> Void
    let onSaveLocalName: () -> Void
    let onClearLocalName: () -> Void
    let onDeleteContact: () -> Void
    @State private var isShowingDeleteConfirmation: Bool = false

    private var shareURL: URL? {
        URL(string: shareLink)
    }

    private var hasLocalOverride: Bool {
        contact.localName != nil
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let columnWidth = TurboLayout.contentWidth(for: geometry.size.width)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        localNameSection
                        identitySection
                        deleteSection
                    }
                    .frame(width: columnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, TurboLayout.horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(contact.name)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Delete this contact?",
                isPresented: $isShowingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Contact", role: .destructive, action: onDeleteContact)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the saved contact from this BeepBeep account.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    private var localNameSection: some View {
        TurboSection(
            title: "Name on this phone",
            subtitle: "Only you see this. Leave it blank to use the BeepBeep name."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField(contact.profileName, text: $draftLocalName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .turboFieldStyle()

                HStack(spacing: 10) {
                    Button("Save Name", action: onSaveLocalName)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)

                    if hasLocalOverride {
                        Button("Use BeepBeep Name", action: onClearLocalName)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var identitySection: some View {
        TurboSection(
            title: "BeepBeep identity",
            subtitle: "This is the shared identity you can use to recognize or re-add this contact.",
            showsDivider: true
        ) {
            VStack(alignment: .leading, spacing: 18) {
                identityRow(title: "BeepBeep name", value: contact.profileName, monospaced: false)
                identityRow(title: "Handle", value: contact.handle, monospaced: true)
                identityRow(title: "Share link", value: shareLink, monospaced: true, selectable: true)

                DisclosureGroup {
                    identityRow(title: "DID", value: did, monospaced: true, selectable: true)
                } label: {
                    Text("Identity details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("Copy Handle") {
                        UIPasteboard.general.string = contact.handle
                    }
                    .buttonStyle(.bordered)

                    Button("Copy Link") {
                        UIPasteboard.general.string = shareLink
                    }
                    .buttonStyle(.bordered)

                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Text("Share")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var deleteSection: some View {
        TurboSection(
            title: "Remove contact",
            subtitle: "This deletes the saved contact on this account. You can add them again later with their handle or link.",
            showsDivider: false
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    Text(isDeletingContact ? "Deleting…" : "Delete Contact")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)
                .disabled(isDeletingContact)

                if let deleteErrorMessage {
                    Text(deleteErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func identityRow(
        title: String,
        value: String,
        monospaced: Bool,
        selectable: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if selectable {
                Text(value)
                    .font(monospaced ? .caption.monospaced() : .body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(monospaced ? .caption.monospaced() : .body)
                    .foregroundStyle(.primary)
            }
        }
    }
}
