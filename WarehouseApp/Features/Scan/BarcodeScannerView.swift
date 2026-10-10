import SwiftUI
import VisionKit

/// Live camera barcode scanner. Only works on a real device —
/// callers must check `isSupported` and provide a fallback.
struct BarcodeScannerView: UIViewControllerRepresentable {
    /// False stops the camera while the scanner is covered or off screen.
    var isActive = true
    let onScan: (String) -> Void

    @MainActor
    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        if isActive {
            if !uiViewController.isScanning { try? uiViewController.startScanning() }
        } else if uiViewController.isScanning {
            uiViewController.stopScanning()
        }
    }

    static func dismantleUIViewController(
        _ uiViewController: DataScannerViewController, coordinator: Coordinator
    ) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var lastValue: String?

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue,
                      value != lastValue else { continue }
                lastValue = value
                onScan(value)
            }
        }
    }
}

/// Sheet wrapper: camera scanner on device, manual entry fallback on simulator.
struct ScannerSheet: View {
    let title: String
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var manualValue = ""
    @State private var pendingValue: String?

    var body: some View {
        NavigationStack {
            Group {
                if BarcodeScannerView.isSupported {
                    BarcodeScannerView { value in
                        accept(value)
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    Form {
                        Section("Camera unavailable — enter the barcode manually") {
                            TextField("Barcode value", text: $manualValue)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                            Button("Use This Barcode") {
                                accept(manualValue)
                            }
                            .disabled(manualValue.isEmpty)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        // Deliver the value only after this sheet is fully gone. Calling onScan
        // while still presented makes the caller's follow-up sheet lose the
        // dismiss/present race and silently never appear.
        .onDisappear {
            if let pendingValue {
                onScan(pendingValue)
            }
        }
    }

    private func accept(_ value: String) {
        guard pendingValue == nil else { return }
        pendingValue = value
        dismiss()
    }
}
