import CoreImage.CIFilterBuiltins
import SwiftUI

struct PairingQRCodeView: View {
    let payload: String

    var body: some View {
        Group {
            if let image = makeQRCode() {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                ContentUnavailableView(
                    "QR unavailable",
                    systemImage: "qrcode",
                    description: Text("Create a new pairing session.")
                )
            }
        }
        .frame(width: 176, height: 176)
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Pairing QR code")
    }

    private func makeQRCode() -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 8, y: 8)
        ) else {
            return nil
        }

        let context = CIContext()
        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 176, height: 176))
    }
}
