import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Apps/AppIcons.xcassets")
let macIcon = assets.appendingPathComponent("AppIconMac.appiconset")
let phoneIcon = assets.appendingPathComponent("AppIconPhone.appiconset")

func renderIcon(size: Int, roundedBackground: Bool, destination: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create icon bitmap")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    graphicsContext.imageInterpolation = .high

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = roundedBackground ? CGFloat(size) * 0.025 : 0
    let background = canvas.insetBy(dx: inset, dy: inset)
    let radius = roundedBackground ? CGFloat(size) * 0.205 : 0
    let backgroundPath = NSBezierPath(roundedRect: background, xRadius: radius, yRadius: radius)
    NSColor(calibratedRed: 0.16, green: 0.29, blue: 0.48, alpha: 1).setFill()
    backgroundPath.fill()

    let pointSize = CGFloat(size) * 0.59
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else {
        fatalError("The gamecontroller.fill symbol is unavailable")
    }
    let symbolWidth = CGFloat(size) * 0.72
    let symbolHeight = symbolWidth * symbol.size.height / symbol.size.width
    symbol.draw(
        in: CGRect(
            x: (CGFloat(size) - symbolWidth) / 2,
            y: (CGFloat(size) - symbolHeight) / 2,
            width: symbolWidth,
            height: symbolHeight
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )

    graphicsContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon PNG")
    }
    try png.write(to: destination)
}

try FileManager.default.createDirectory(at: macIcon, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: phoneIcon, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try renderIcon(size: size, roundedBackground: true, destination: macIcon.appendingPathComponent("icon-\(size).png"))
}
try renderIcon(size: 1024, roundedBackground: false, destination: phoneIcon.appendingPathComponent("icon-1024.png"))
