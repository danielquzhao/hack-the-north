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
        case .motion:
            TiltArtwork(label: control.label, isAvailable: true)
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

enum DPadDirection: Equatable {
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
            let side = min(geometry.size.width, geometry.size.height * 0.82)
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
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.18, style: .continuous)
                .fill(Color(white: 0.20))
            RoundedRectangle(cornerRadius: side * 0.18, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 2)
            triangle(.up).position(x: side * 0.5, y: side * 0.21)
            triangle(.down).position(x: side * 0.5, y: side * 0.79)
            triangle(.left).position(x: side * 0.21, y: side * 0.5)
            triangle(.right).position(x: side * 0.79, y: side * 0.5)
            Circle().fill(Color(white: 0.12))
                .frame(width: side * 0.18, height: side * 0.18)
        }
    }

    private func triangle(_ direction: DPadDirection) -> some View {
        let angle: Double = switch direction {
        case .up: 0
        case .down: 180
        case .left: -90
        case .right: 90
        }
        return Image(systemName: "triangle.fill")
            .font(.system(size: side * 0.20, weight: .heavy))
            .rotationEffect(.degrees(angle))
            .foregroundStyle(activeDirection == direction ? .white : .white.opacity(0.65))
    }
}

struct JoystickArtwork: View {
    let label: String
    let offset: CGSize

    var body: some View {
        GeometryReader { geometry in
            let side = min(150, geometry.size.width, max(0, geometry.size.height - 24))
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

struct TiltArtwork: View {
    let label: String
    let isAvailable: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "gyroscope")
                .font(.title3.weight(.semibold))
            Text(label)
                .font(.caption.weight(.semibold))
            Text(isAvailable ? "Tilt · tap recenter" : "Unavailable")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
