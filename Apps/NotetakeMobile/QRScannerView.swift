import SwiftUI
import VisionKit

/// VisionKitのDataScannerViewControllerでQRコードだけを読み取り、6桁の数字文字列を
/// 検出したら`onDetect`を呼ぶ。実機・iOS 16+限定（`isSupported`がfalseの端末・
/// シミュレータでは呼び出し側がこの型を使わずfallbackのtext入力のみ出すこと）
struct QRScannerView: UIViewControllerRepresentable {
    let onDetect: (String) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDetect: onDetect)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onDetect: (String) -> Void

        init(onDetect: @escaping (String) -> Void) {
            self.onDetect = onDetect
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue
                else { continue }
                let digitsOnly = payload.filter(\.isNumber)
                guard digitsOnly.count == 6 else { continue }
                onDetect(digitsOnly)
                return
            }
        }
    }
}
