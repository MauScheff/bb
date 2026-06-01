import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
#if canImport(VisionKit)
import Vision
import VisionKit
#endif

struct TurboAddContactSheet: View {
    @Binding var draftReference: String
    let currentIdentityHandle: String
    let currentShareLink: String
    let quickFriendHandles: [String]
    let isOpeningFriend: Bool
    let isResettingDevState: Bool
    let statusMessage: String?
    let onClose: () -> Void
    let onShowShareIdentity: () -> Void
    let onOpenReference: (String) -> Void

    @State private var copiedStatus: String?
    @State private var isShowingScanner: Bool = false
    @State private var isShowingShareSheet: Bool = false

    private var isBusy: Bool {
        isOpeningFriend || isResettingDevState
    }

    private var trimmedDraftReference: String {
        draftReference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let columnWidth = TurboLayout.contentWidth(for: geometry.size.width)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        nearbyActionsCard
                        addByReferenceCard
                    }
                    .frame(width: columnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, TurboLayout.horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
            .sheet(isPresented: $isShowingScanner) {
                TurboQRScannerSheet(
                    onClose: { isShowingScanner = false },
                    onCodeScanned: handleScannedCode(_:)
                )
            }
            .sheet(isPresented: $isShowingShareSheet) {
                TurboShareIdentitySheet(
                    currentIdentityHandle: currentIdentityHandle,
                    currentShareLink: currentShareLink,
                    copiedStatus: $copiedStatus,
                    onClose: { isShowingShareSheet = false }
                )
            }
        }
    }

    private var nearbyActionsCard: some View {
        TurboSection(
            title: "Add nearby",
            subtitle: "Scan someone else, or show your own BeepBeep."
        ) {
            HStack(spacing: 10) {
                Button("Scan QR") {
                    isShowingScanner = true
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .disabled(isBusy)

                Button("Show My QR") {
                    onShowShareIdentity()
                    isShowingShareSheet = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 50)
                .disabled(isBusy)
            }
        }
    }

    private var addByReferenceCard: some View {
        TurboSection(
            title: "Add by handle or link",
            subtitle: "Enter a BeepBeep handle or link."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Handle or link", text: $draftReference)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .turboFieldStyle()

                HStack(spacing: 10) {
                    Button {
                        onOpenReference(trimmedDraftReference)
                    } label: {
                        Text(isOpeningFriend ? "Opening…" : "Continue")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)
                    .disabled(trimmedDraftReference.isEmpty || isBusy)

                    Button("Paste") {
                        guard let pastedValue = UIPasteboard.general.string else { return }
                        draftReference = pastedValue
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }

                if let statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !quickFriendHandles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dev quick add")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(quickFriendHandles, id: \.self) { handle in
                                    Button(handle) {
                                        draftReference = handle
                                        onOpenReference(handle)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isBusy)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleScannedCode(_ code: String) {
        draftReference = code
        isShowingScanner = false
        onOpenReference(code)
    }
}

private struct TurboShareIdentitySheet: View {
    let currentIdentityHandle: String
    let currentShareLink: String
    @Binding var copiedStatus: String?
    let onClose: () -> Void

    private var shareURL: URL? {
        URL(string: currentShareLink)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let columnWidth = TurboLayout.contentWidth(for: geometry.size.width)

                ScrollView {
                    TurboSection(
                        title: "Share your BeepBeep",
                        subtitle: "Let someone scan this or open your link.",
                        showsDivider: false
                    ) {
                        VStack(alignment: .center, spacing: 16) {
                            TurboQRCodeView(payload: currentShareLink)
                                .frame(width: 188, height: 188)

                            VStack(spacing: 6) {
                                Text(currentIdentityHandle)
                                    .font(.title3.weight(.semibold))

                                Text(currentShareLink)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .textSelection(.enabled)
                            }

                            HStack(spacing: 10) {
                                Button("Copy Handle") {
                                    UIPasteboard.general.string = currentIdentityHandle
                                    copiedStatus = "Copied handle"
                                }
                                .buttonStyle(.bordered)

                                Button("Copy Link") {
                                    UIPasteboard.general.string = currentShareLink
                                    copiedStatus = "Copied link"
                                }
                                .buttonStyle(.bordered)

                                if let shareURL {
                                    ShareLink(item: shareURL) {
                                        Text("Share")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }

                            if let copiedStatus {
                                Text(copiedStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(width: columnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, TurboLayout.horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Your QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}

private struct TurboQRCodeView: View {
    let payload: String

    var body: some View {
        Group {
            if let image = qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .background(.white)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 72, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemBackground))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var qrImage: UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 12, y: 12)
        ) else {
            return nil
        }

        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

private struct TurboQRScannerSheet: View {
    let onClose: () -> Void
    let onCodeScanned: (String) -> Void

    @State private var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var isRequestingCameraAccess = false

    private var scannerSupported: Bool {
#if canImport(VisionKit)
        if #available(iOS 16.0, *) {
            return DataScannerViewController.isSupported
        }
#endif
        return false
    }

    var body: some View {
        NavigationStack {
            Group {
                if !scannerSupported {
                    scannerMessage(
                        title: "Scanning unavailable",
                        detail: "This device does not support live QR scanning. You can still paste a BeepBeep link or handle."
                    )
                } else {
                    switch cameraAuthorizationStatus {
                    case .authorized:
                        scannerView
                    case .notDetermined:
                        permissionPrompt
                    case .denied, .restricted:
                        scannerMessage(
                            title: "Camera access needed",
                            detail: "Allow camera access in Settings to scan BeepBeep QR codes."
                        )
                    @unknown default:
                        scannerMessage(
                            title: "Camera unavailable",
                            detail: "The camera could not be prepared right now. You can still paste a BeepBeep link or handle."
                        )
                    }
                }
            }
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    @ViewBuilder
    private var scannerView: some View {
#if canImport(VisionKit)
        if #available(iOS 16.0, *) {
            TurboLiveQRScannerView(onCodeScanned: onCodeScanned)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text("Point the camera at a BeepBeep QR code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 24)
                }
        }
#endif
    }

    private var permissionPrompt: some View {
        scannerMessage(
            title: "Allow camera access",
            detail: "BeepBeep needs the camera to scan QR codes in person."
        ) {
            Button {
                requestCameraAccess()
            } label: {
                Text(isRequestingCameraAccess ? "Requesting…" : "Allow Camera Access")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequestingCameraAccess)
        }
    }

    private func scannerMessage<Actions: View>(
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            actions()

            Spacer()
        }
        .padding(24)
    }

    private func scannerMessage(title: String, detail: String) -> some View {
        scannerMessage(title: title, detail: detail) {
            EmptyView()
        }
    }

    private func requestCameraAccess() {
        guard !isRequestingCameraAccess else { return }
        isRequestingCameraAccess = true
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                cameraAuthorizationStatus = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .video)
                isRequestingCameraAccess = false
            }
        }
    }
}

#if canImport(VisionKit)
@available(iOS 16.0, *)
private struct TurboLiveQRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCodeScanned: (String) -> Void
        private var hasDeliveredCode = false

        init(onCodeScanned: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasDeliveredCode else { return }
            guard let code = recognizedCode(in: addedItems) else { return }
            hasDeliveredCode = true
            onCodeScanned(code)
        }

        private func recognizedCode(in items: [RecognizedItem]) -> String? {
            for item in items {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue,
                   !payload.isEmpty {
                    return payload
                }
            }
            return nil
        }
    }
}
#endif
