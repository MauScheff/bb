import SwiftUI

enum TurboLayout {
    static let horizontalPadding: CGFloat = 24
    static let contentMaxWidth: CGFloat = 360
    static let primaryButtonMaxWidth: CGFloat = 320
    static let sectionSpacing: CGFloat = 28
    static let fieldCornerRadius: CGFloat = 18

    static func contentWidth(for availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth - (horizontalPadding * 2), 0), contentMaxWidth)
    }

    static func primaryButtonWidth(for availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth - (horizontalPadding * 2), 0), primaryButtonMaxWidth)
    }
}

struct TurboSection<Content: View>: View {
    let title: String
    let subtitle: String
    let showsDivider: Bool
    let content: Content

    init(
        title: String,
        subtitle: String,
        showsDivider: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showsDivider = showsDivider
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider()
            }
        }
    }
}

extension View {
    func turboFieldStyle(verticalPadding: CGFloat = 15) -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, verticalPadding)
            .background(Color(uiColor: .secondarySystemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: TurboLayout.fieldCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: TurboLayout.fieldCornerRadius, style: .continuous))
    }
}
