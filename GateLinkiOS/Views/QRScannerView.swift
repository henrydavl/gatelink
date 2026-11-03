import SwiftUI
import VisionKit

/// Live camera view that reports the QR payloads it sees, once.
struct QRScannerView: UIViewControllerRepresentable {
    let found: ([String]) -> Void

    static var isSupported: Bool { DataScannerViewController.isSupported }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    // Scanning can only start once the view is on screen.
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: ([String]) -> Void
        private var reported = false

        init(found: @escaping ([String]) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            let payloads = allItems.compactMap { item -> String? in
                guard case .barcode(let code) = item else { return nil }
                return code.payloadStringValue
            }
            guard !reported, !payloads.isEmpty else { return }
            reported = true
            found(payloads)
        }
    }
}
