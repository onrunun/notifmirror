import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRCodeView: View {
    let payload: String
    var size: CGFloat = 280

    var body: some View {
        if let image = generate(payload: payload, size: size) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Failed to generate QR")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.red.opacity(0.2))
        }
    }

    private func generate(payload: String, size: CGFloat) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
