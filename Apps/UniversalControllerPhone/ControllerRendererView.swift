import CoreMotion
import SwiftUI
import UIKit

struct ControllerRendererView: View {
    let document: ControllerDocument
    let onEvent: (ControlDefinition, ControlEventKind, InputValue) -> Void

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 12
            let heightUnits = rows.reduce(0) { $0 + $1.heightUnits }
            let availableHeight = max(
                0,
                geometry.size.height - CGFloat(max(rows.count - 1, 0)) * spacing
            )
            let contentHeight = max(availableHeight, CGFloat(heightUnits) * 112)

            ScrollView {
                Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                    ForEach(rows) { row in
                        GridRow {
                            ForEach(row.items) { item in
                                if let control = document.control(id: item.controlID) {
                                    controlView(control)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .gridCellColumns(item.columnSpan)
                                }
                            }
                        }
                        .frame(height: contentHeight * CGFloat(row.heightUnits) / CGFloat(max(heightUnits, 1)))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var rows: [ControllerLayoutRow] {
        var groupedItems: [[ControllerLayoutItem]] = []
        var currentItems: [ControllerLayoutItem] = []
        var occupiedColumns = 0

        for item in document.layout.items {
            if occupiedColumns + item.columnSpan > document.layout.columns {
                groupedItems.append(currentItems)
                currentItems = []
                occupiedColumns = 0
            }

            currentItems.append(item)
            occupiedColumns += item.columnSpan

            if occupiedColumns == document.layout.columns {
                groupedItems.append(currentItems)
                currentItems = []
                occupiedColumns = 0
            }
        }

        if !currentItems.isEmpty {
            groupedItems.append(currentItems)
        }
        return groupedItems.enumerated().map {
            ControllerLayoutRow(id: $0.offset, items: $0.element)
        }
    }

    @ViewBuilder
    private func controlView(_ control: ControlDefinition) -> some View {
        switch control.kind {
        case .button(let configuration):
            ButtonControlView(
                control: control,
                configuration: configuration,
                onTrigger: { onEvent(control, .triggered, .none) }
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
        }
    }
}

private struct ControllerLayoutRow: Identifiable {
    let id: Int
    let items: [ControllerLayoutItem]

    var heightUnits: Int {
        max(items.map(\.rowSpan).max() ?? 1, 1)
    }
}

private struct ButtonControlView: View {
    let control: ControlDefinition
    let configuration: ButtonControlConfiguration
    let onTrigger: () -> Void

    var body: some View {
        Group {
            if configuration.face == .standard {
                switch configuration.variant {
                case .primary:
                    button.buttonStyle(.borderedProminent)
                case .secondary:
                    button.buttonStyle(.bordered)
                case .destructive:
                    button.buttonStyle(.borderedProminent).tint(.red)
                }
            } else {
                gamepadButton
            }
        }
    }

    private var button: some View {
        Button {
            if configuration.hapticsEnabled {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            onTrigger()
        } label: {
            Text(control.label)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 16)
        }
    }

    private var gamepadButton: some View {
        Button {
            if configuration.hapticsEnabled {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            onTrigger()
        } label: {
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

    private var faceColor: Color {
        switch configuration.face {
        case .standard: .indigo
        case .a: .green
        case .b: .red
        case .x: .blue
        case .y: .orange
        }
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
