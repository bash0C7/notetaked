import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 文字列をQRコード画像化する（CoreImageのCIQRCodeGeneratorのみで完結、外部依存なし）
enum QRCodeGenerator {
    /// `text`をQRコード化した`NSImage`を返す。生成に失敗したらnil
    static func image(for text: String, scale: CGFloat = 10) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
