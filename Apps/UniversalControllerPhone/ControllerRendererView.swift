import CoreMotion
import SwiftUI
import UIKit

struct ControllerRendererView: View {
    let document: ControllerDocument
    let onEvent: (ControlDefinition, ControlEventKind, InputValue) -> Void

    var body: some View {
        GeometryReader { geometry in
            if orientationMatches(geometry.size) {
                ZStack(alignment: .topLeading) {
                    ForEach(document.layout.items) { item in
                        if let control = document.control(id: item.controlID) {
                            controlView(control)
                                .frame(
                                    width: geometry.size.width * item.frame.width,
                                    height: geometry.size.height * item.frame.height
                                )
                                .position(
                                    x: geometry.size.width * (item.frame.x + item.frame.width / 2),
                                    y: geometry.size.height * (item.frame.y + item.frame.height / 2)
                                )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: document.preferredOrientation == .landscape
                        ? "iphone.landscape"
                        : "iphone")
                        .font(.system(size: 46, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                    Text("Rotate to \(document.preferredOrientation.displayName)")
                        .font(.title3.bold())
                    Text("This controller was designed for \(document.preferredOrientation.rawValue).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func orientationMatches(_ size: CGSize) -> Bool {
        switch document.preferredOrientation {
        case .portrait:
            size.height >= size.width
        case .landscape:
            size.width > size.height
        }
    }

    @ViewBuilder
    private func controlView(_ control: ControlDefinition) -> some View {
        switch control.kind {
        case .button(let configuration):
            ButtonControlView(
                control: control,
                configuration: configuration,
                onPress: { onEvent(control, .began, .none) },
                onRelease: { onEvent(control, .ended, .none) }
            )
        case .joystick(let configuration):
            JoystickControlView(
                label: control.label,
                hapticsEnabled: configuration.hapticsEnabled
            ) { value in
                onEvent(control, .changed, .vector2(value))
            }
        case .motion(let configuration):
            TiltControlView(label: control.label, source: configuration.source) { value in
                onEvent(control, .changed, .vector2(value))
            }
        case .trackpad(let configuration):
            TrackpadControlView(
                label: control.label,
                hapticsEnabled: configuration.hapticsEnabled
            ) { event, value in
                onEvent(control, event, .vector2(value))
            }
        }
    }
}

private struct ButtonControlView: View {
    let control: ControlDefinition
    let configuration: ButtonControlConfiguration
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isPressed = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if configuration.face == .standard {
                standardButton
            } else {
                gamepadButton
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in press() }
                .onEnded { _ in release() }
        )
        .onDisappear { release() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { release() }
        }
    }

    private var standardButton: some View {
        Button {} label: {
            Text(control.label)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(tintColor)
                )
        }
        .buttonStyle(.plain)
    }

    private var gamepadButton: some View {
        Button {} label: {
            VStack(spacing: 7) {
                Text(configuration.face.rawValue.uppercased())
                    .font(.system(size: 29, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(
                        Circle().fill(
                            LinearGradient(
                                colors: [faceColor.opacity(0.9), faceColor.opacity(0.55)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2))
                    .shadow(color: faceColor.opacity(0.4), radius: 8, y: 4)
                Text(control.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(configuration.face.rawValue.uppercased()), \(control.label)")
    }

    private var tintColor: Color {
        Color(hex: configuration.tintHex) ?? .indigo
    }

    private var faceColor: Color {
        tintColor
    }

    private func press() {
        guard !isPressed else { return }
        isPressed = true
        if configuration.hapticsEnabled {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        onPress()
    }

    private func release() {
        guard isPressed else { return }
        isPressed = false
        onRelease()
    }
}

private struct TrackpadControlView: View {
    let label: String
    let hapticsEnabled: Bool
    let onEvent: (ControlEventKind, Vector2Value) -> Void
    @State private var lastTranslation: CGSize = .zero
    @State private var lastMagnification = 1.0
    @State private var isDragging = false
    @State private var isPinching = false

    private let zero = Vector2Value(x: 0, y: 0)

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
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .highPriorityGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { gesture in
                    guard !isPinching else { return }
                    if !isDragging {
                        isDragging = true
                        lastTranslation = .zero
                        if hapticsEnabled {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        onEvent(.began, zero)
                    }
                    let dx = gesture.translation.width - lastTranslation.width
                    let dy = gesture.translation.height - lastTranslation.height
                    lastTranslation = gesture.translation
                    onEvent(.changed, Vector2Value(
                        x: min(max(Double(dx / 20), -1), 1),
                        y: min(max(Double(dy / 20), -1), 1)
                    ))
                }
                .onEnded { _ in endDrag() }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { gesture in
                    if !isPinching {
                        endDrag()
                        isPinching = true
                        lastMagnification = 1
                    }
                    let magnification = max(gesture.magnification, 0.01)
                    let delta = log(magnification / lastMagnification) * 5
                    lastMagnification = magnification
                    if abs(delta) > 0.0001 {
                        onEvent(.pinchChanged, Vector2Value(
                            x: 0,
                            y: min(max(delta, -1), 1)
                        ))
                    }
                }
                .onEnded { gesture in
                    isPinching = false
                    lastMagnification = 1
                }
        )
        .onDisappear { endDrag() }
        .accessibilityLabel("\(label) drag pad")
        .accessibilityHint("Drag with one finger or pinch with two fingers")
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        lastTranslation = .zero
        onEvent(.ended, zero)
    }
}

private struct JoystickControlView: View {
    let label: String
    let hapticsEnabled: Bool
    let onChange: (Vector2Value) -> Void
    @State private var offset: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.35))
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 2))
                    .frame(width: 150, height: 150)
                Circle()
                    .fill(.linearGradient(
                        colors: [.white.opacity(0.9), .gray.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 2))
                    .frame(width: 66, height: 66)
                    .offset(offset)
            }
            .frame(width: 170, height: 170)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if !isDragging {
                        isDragging = true
                        if hapticsEnabled {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    let x = gesture.translation.width
                    let y = gesture.translation.height
                    let length = max(1, hypot(x, y))
                    let scale = min(1, 52 / length)
                    offset = CGSize(width: x * scale, height: y * scale)
                    onChange(Vector2Value(
                        x: Double(offset.width / 52),
                        y: Double(-offset.height / 52)
                    ))
                }
                .onEnded { _ in
                    offset = .zero
                    isDragging = false
                })
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(label) thumbstick")
    }
}

private struct TiltControlView: View {
    let label: String
    let source: MotionSource
    let onChange: (Vector2Value) -> Void
    @StateObject private var motion = MotionInputSource()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.title)
            Text(label)
                .font(.subheadline.weight(.semibold))
            Text(motion.isAvailable ? "Tilt to move · tap to recenter" : "Motion unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { motion.recenter() }
        .onAppear { if scenePhase == .active { motion.start(onChange: onChange) } }
        .onDisappear { motion.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { motion.start(onChange: onChange) }
            else { motion.stop() }
        }
    }
}

@MainActor
private final class MotionInputSource: ObservableObject {
    @Published private(set) var isAvailable = true
    private let manager = CMMotionManager()
    private var currentRaw: Vector2Value?
    private var neutral: Vector2Value?
    private var onChange: ((Vector2Value) -> Void)?

    func start(onChange: @escaping (Vector2Value) -> Void) {
        self.onChange = onChange
        guard !manager.isDeviceMotionActive else { return }
        guard manager.isDeviceMotionAvailable else {
            isAvailable = false
            return
        }
        isAvailable = true
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, error in
            if error != nil {
                Task { @MainActor [weak self] in self?.isAvailable = false }
                return
            }
            guard let gravity = data?.gravity else { return }
            let raw = Vector2Value(x: gravity.x, y: -gravity.y)
            Task { @MainActor [weak self] in self?.receive(raw) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        onChange = nil
        currentRaw = nil
        neutral = nil
    }

    func recenter() {
        neutral = currentRaw
    }

    private func receive(_ raw: Vector2Value) {
        currentRaw = raw
        if neutral == nil {
            neutral = raw
            return
        }
        guard let neutral else { return }
        let value = Vector2Value(
            x: min(1, max(-1, (raw.x - neutral.x) / 0.6)),
            y: min(1, max(-1, (raw.y - neutral.y) / 0.6))
        )
        onChange?(value)
    }
}

private extension Color {
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
