import SwiftUI

/// The same non-interactive artwork is used by the iPhone controls and Mac editor.
struct ControlArtwork: View {
    let control: ControlDefinition

    var body: some View {
        switch control.kind {
        case .button(let configuration):
            ButtonArtwork(control: control, configuration: configuration)
        case .dpad:
            DPadArtwork(label: control.label, activeDirection: nil)
        case .joystick:
            JoystickArtwork(label: control.label, offset: .zero)
        case .trackpad:
            TrackpadArtwork(label: control.label)
        }
    }
}

struct ButtonArtwork: View {
    let control: ControlDefinition
    let configuration: ButtonControlConfiguration

    var body: some View {
        Group {
            if configuration.face == .standard {
                Text(control.label)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(tintColor)
                    )
            } else {
                VStack(spacing: 7) {
                    Text(configuration.face.rawValue.uppercased())
                        .font(.system(size: 29, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(
                            Circle().fill(
                                LinearGradient(
                                    colors: [tintColor.opacity(0.9), tintColor.opacity(0.55)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        )
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2))
                        .shadow(color: tintColor.opacity(0.4), radius: 8, y: 4)
                    Text(control.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var tintColor: Color {
        ControlArtworkColor.fromHex(configuration.tintHex) ?? .indigo
    }
}

enum DPadDirection: Hashable {
    case up, down, left, right

    var began: ControlEventKind {
        switch self {
        case .up: .upBegan
        case .down: .downBegan
        case .left: .leftBegan
        case .right: .rightBegan
        }
    }

    var ended: ControlEventKind {
        switch self {
        case .up: .upEnded
        case .down: .downEnded
        case .left: .leftEnded
        case .right: .rightEnded
        }
    }
}

struct DPadArtwork: View {
    let label: String
    let activeDirection: DPadDirection?

    var body: some View {
        GeometryReader { geometry in
            let side = max(0, min(geometry.size.width, geometry.size.height - 24))
            VStack(spacing: 6) {
                DPadFaceArtwork(side: side, activeDirection: activeDirection)
                    .frame(width: side, height: side)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DPadFaceArtwork: View {
    let side: CGFloat
    let activeDirection: DPadDirection?

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: side * 0.19, style: .continuous)
        ZStack {
            outline.fill(
                LinearGradient(
                    colors: [Color(red: 0.61, green: 0.55, blue: 0.65),
                             Color(red: 0.48, green: 0.42, blue: 0.53)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            if let activeDirection {
                sector(activeDirection)
                    .fill(.white.opacity(0.18))
            }
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: side, y: side))
                path.move(to: CGPoint(x: side, y: 0))
                path.addLine(to: CGPoint(x: 0, y: side))
            }
            .stroke(.black.opacity(0.30), lineWidth: max(1, side * 0.005))
            ForEach([DPadDirection.up, .down, .left, .right], id: \.self) { direction in
                arrow(direction)
                    .stroke(
                        .white.opacity(activeDirection == direction ? 1 : 0.88),
                        style: StrokeStyle(
                            lineWidth: max(2, side * 0.018),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }
        }
        .frame(width: side, height: side)
        .clipShape(outline)
        .overlay(outline.strokeBorder(.white.opacity(0.16), lineWidth: 1.5))
    }

    private func sector(_ direction: DPadDirection) -> Path {
        let center = CGPoint(x: side / 2, y: side / 2)
        let corners: (CGPoint, CGPoint) = switch direction {
        case .up: (CGPoint(x: 0, y: 0), CGPoint(x: side, y: 0))
        case .down: (CGPoint(x: side, y: side), CGPoint(x: 0, y: side))
        case .left: (CGPoint(x: 0, y: side), CGPoint(x: 0, y: 0))
        case .right: (CGPoint(x: side, y: 0), CGPoint(x: side, y: side))
        }
        var path = Path()
        path.move(to: corners.0)
        path.addLine(to: corners.1)
        path.addLine(to: center)
        path.closeSubpath()
        return path
    }

    private func arrow(_ direction: DPadDirection) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let rotated: (CGFloat, CGFloat) = switch direction {
            case .up: (x, y)
            case .down: (1 - x, 1 - y)
            case .left: (y, 1 - x)
            case .right: (1 - y, x)
            }
            return CGPoint(x: rotated.0 * side, y: rotated.1 * side)
        }
        var path = Path()
        path.move(to: point(0.5, 0.34))
        path.addLine(to: point(0.5, 0.23))
        path.move(to: point(0.455, 0.275))
        path.addLine(to: point(0.5, 0.23))
        path.addLine(to: point(0.545, 0.275))
        return path
    }
}

struct JoystickArtwork: View {
    let label: String
    let offset: CGSize

    var body: some View {
        GeometryReader { geometry in
            let side = max(0, min(geometry.size.width, geometry.size.height - 24))
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.35))
                        .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 2))
                        .frame(width: side, height: side)
                    Circle()
                        .fill(.linearGradient(
                            colors: [.white.opacity(0.9), .gray.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 2))
                        .frame(width: side * 0.44, height: side * 0.44)
                        .offset(offset)
                }
                .frame(width: side, height: side)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct TrackpadArtwork: View {
    let label: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.draw")
                .font(.largeTitle)
            Text(label)
                .font(.subheadline.weight(.semibold))
            Text("Drag to move · Pinch to zoom")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }
}

private enum ControlArtworkColor {
    static func fromHex(_ hex: String) -> Color? {
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
