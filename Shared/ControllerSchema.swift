import Foundation

struct ControllerDocument: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let id: UUID
    let revision: Int
    let name: String
    let target: ControllerTarget
    let preferredOrientation: ControllerOrientation
    let layouts: ControllerLayouts
    let controls: [ControlDefinition]
    let bindings: [ControlBinding]

    var layout: ControllerLayout {
        layouts.layout(for: preferredOrientation)
    }

    func layout(for orientation: ControllerOrientation) -> ControllerLayout {
        layouts.layout(for: orientation)
    }

    func control(id: String) -> ControlDefinition? {
        controls.first { $0.id == id }
    }

    func binding(controlID: String, event: ControlEventKind) -> ControlBinding? {
        bindings.first { $0.controlID == controlID && $0.event == event }
    }
}

struct ControllerTarget: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
}

enum ControllerOrientation: String, Codable, CaseIterable, Equatable, Sendable {
    case portrait
    case landscape

    var displayName: String {
        rawValue.capitalized
    }
}

struct ControllerLayouts: Codable, Equatable, Sendable {
    let portrait: ControllerLayout
    let landscape: ControllerLayout

    func layout(for orientation: ControllerOrientation) -> ControllerLayout {
        switch orientation {
        case .portrait:
            portrait
        case .landscape:
            landscape
        }
    }

    func replacing(
        _ layout: ControllerLayout,
        for orientation: ControllerOrientation
    ) -> ControllerLayouts {
        switch orientation {
        case .portrait:
            ControllerLayouts(portrait: layout, landscape: landscape)
        case .landscape:
            ControllerLayouts(portrait: portrait, landscape: layout)
        }
    }
}

struct ControllerLayout: Codable, Equatable, Sendable {
    let columns: Int
    let items: [ControllerLayoutItem]
}

struct ControllerLayoutItem: Codable, Equatable, Sendable, Identifiable {
    var id: String { controlID }

    let controlID: String
    let columnSpan: Int
    let rowSpan: Int
}

enum ButtonVariant: String, Codable, Equatable, Sendable {
    case primary
    case secondary
    case destructive
}

enum ButtonFace: String, Codable, CaseIterable, Equatable, Sendable {
    case standard
    case a
    case b
    case x
    case y
}

enum ControlCapabilityID: String, Codable, CaseIterable, Equatable, Sendable {
    case button
    case joystick
    case motion
    case swipePad
    case pinchPad
    case rotationPad
}

struct ButtonControlConfiguration: Equatable, Sendable {
    let variant: ButtonVariant
    let hapticsEnabled: Bool
    let face: ButtonFace
}

extension ButtonControlConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case variant
        case hapticsEnabled
        case face
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        variant = try container.decode(ButtonVariant.self, forKey: .variant)
        hapticsEnabled = try container.decode(Bool.self, forKey: .hapticsEnabled)
        face = try container.decodeIfPresent(ButtonFace.self, forKey: .face) ?? .standard
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(variant, forKey: .variant)
        try container.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try container.encode(face, forKey: .face)
    }
}

struct JoystickControlConfiguration: Codable, Equatable, Sendable {
    let hapticsEnabled: Bool
}

struct SwipePadControlConfiguration: Codable, Equatable, Sendable {
    let hapticsEnabled: Bool
}

struct TwoFingerControlConfiguration: Codable, Equatable, Sendable {
    let hapticsEnabled: Bool
}

enum SwipeDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case left
    case right
    case up
    case down

    var event: ControlEventKind {
        switch self {
        case .left: .swipedLeft
        case .right: .swipedRight
        case .up: .swipedUp
        case .down: .swipedDown
        }
    }
}

enum PinchDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case inward
    case outward

    var event: ControlEventKind {
        switch self {
        case .inward: .pinchedIn
        case .outward: .pinchedOut
        }
    }
}

enum RotationDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case clockwise
    case counterclockwise

    var event: ControlEventKind {
        switch self {
        case .clockwise: .rotatedClockwise
        case .counterclockwise: .rotatedCounterclockwise
        }
    }
}

enum MotionSource: String, Codable, CaseIterable, Equatable, Sendable {
    case tilt
}

struct MotionControlConfiguration: Codable, Equatable, Sendable {
    let source: MotionSource
}

enum ControlKind: Equatable, Sendable {
    case button(ButtonControlConfiguration)
    case joystick(JoystickControlConfiguration)
    case motion(MotionControlConfiguration)
    case swipePad(SwipePadControlConfiguration)
    case pinchPad(TwoFingerControlConfiguration)
    case rotationPad(TwoFingerControlConfiguration)

    var outputKind: InputValueKind {
        switch self {
        case .button, .swipePad, .pinchPad, .rotationPad:
            .none
        case .joystick, .motion:
            .vector2
        }
    }

    var capabilityID: ControlCapabilityID {
        switch self {
        case .button:
            .button
        case .joystick:
            .joystick
        case .motion:
            .motion
        case .swipePad:
            .swipePad
        case .pinchPad:
            .pinchPad
        case .rotationPad:
            .rotationPad
        }
    }

    var supportedEvents: Set<ControlEventKind> {
        switch self {
        case .button:
            [.triggered, .began, .ended]
        case .joystick, .motion:
            [.changed]
        case .swipePad:
            Set(SwipeDirection.allCases.map(\.event))
        case .pinchPad:
            Set(PinchDirection.allCases.map(\.event))
        case .rotationPad:
            Set(RotationDirection.allCases.map(\.event))
        }
    }
}

struct ControlDefinition: Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let kind: ControlKind

    static func button(
        id: String,
        label: String,
        variant: ButtonVariant = .primary,
        hapticsEnabled: Bool = true,
        face: ButtonFace = .standard
    ) -> ControlDefinition {
        ControlDefinition(
            id: id,
            label: label,
            kind: .button(ButtonControlConfiguration(
                variant: variant,
                hapticsEnabled: hapticsEnabled,
                face: face
            ))
        )
    }

    static func joystick(id: String, label: String) -> ControlDefinition {
        ControlDefinition(
            id: id,
            label: label,
            kind: .joystick(JoystickControlConfiguration(hapticsEnabled: true))
        )
    }

    static func tilt(id: String, label: String) -> ControlDefinition {
        ControlDefinition(
            id: id,
            label: label,
            kind: .motion(MotionControlConfiguration(source: .tilt))
        )
    }

    static func swipePad(id: String, label: String) -> ControlDefinition {
        ControlDefinition(
            id: id,
            label: label,
            kind: .swipePad(SwipePadControlConfiguration(hapticsEnabled: true))
        )
    }

    static func pinchPad(id: String, label: String) -> ControlDefinition {
        ControlDefinition(
            id: id,
            label: label,
            kind: .pinchPad(TwoFingerControlConfiguration(hapticsEnabled: true))
        )
    }

    static func rotationPad(id: String, label: String) -> ControlDefinition {
        ControlDefinition(
            id: id,
            label: label,
            kind: .rotationPad(TwoFingerControlConfiguration(hapticsEnabled: true))
        )
    }
}

extension ControlDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case type
        case configuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)

        switch try container.decode(ControlCapabilityID.self, forKey: .type) {
        case .button:
            kind = .button(try container.decode(
                ButtonControlConfiguration.self,
                forKey: .configuration
            ))
        case .joystick:
            kind = .joystick(try container.decode(
                JoystickControlConfiguration.self,
                forKey: .configuration
            ))
        case .motion:
            kind = .motion(try container.decode(
                MotionControlConfiguration.self,
                forKey: .configuration
            ))
        case .swipePad:
            kind = .swipePad(try container.decode(
                SwipePadControlConfiguration.self,
                forKey: .configuration
            ))
        case .pinchPad:
            kind = .pinchPad(try container.decode(
                TwoFingerControlConfiguration.self,
                forKey: .configuration
            ))
        case .rotationPad:
            kind = .rotationPad(try container.decode(
                TwoFingerControlConfiguration.self,
                forKey: .configuration
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)

        switch kind {
        case .button(let configuration):
            try container.encode(ControlCapabilityID.button, forKey: .type)
            try container.encode(configuration, forKey: .configuration)
        case .joystick(let configuration):
            try container.encode(ControlCapabilityID.joystick, forKey: .type)
            try container.encode(configuration, forKey: .configuration)
        case .motion(let configuration):
            try container.encode(ControlCapabilityID.motion, forKey: .type)
            try container.encode(configuration, forKey: .configuration)
        case .swipePad(let configuration):
            try container.encode(ControlCapabilityID.swipePad, forKey: .type)
            try container.encode(configuration, forKey: .configuration)
        case .pinchPad(let configuration):
            try container.encode(ControlCapabilityID.pinchPad, forKey: .type)
            try container.encode(configuration, forKey: .configuration)
        case .rotationPad(let configuration):
            try container.encode(ControlCapabilityID.rotationPad, forKey: .type)
            try container.encode(configuration, forKey: .configuration)
        }
    }
}

enum ControlEventKind: String, Codable, Equatable, Hashable, Sendable {
    case triggered
    case began
    case changed
    case ended
    case swipedLeft
    case swipedRight
    case swipedUp
    case swipedDown
    case pinchedIn
    case pinchedOut
    case rotatedClockwise
    case rotatedCounterclockwise
}

enum InputValueKind: String, Codable, Equatable, Sendable {
    case none
    case scalar
    case vector2
    case vector3
}

struct Vector2Value: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct Vector3Value: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let z: Double
}

enum InputValue: Equatable, Sendable {
    case none
    case scalar(Double)
    case vector2(Vector2Value)
    case vector3(Vector3Value)

    var kind: InputValueKind {
        switch self {
        case .none:
            .none
        case .scalar:
            .scalar
        case .vector2:
            .vector2
        case .vector3:
            .vector3
        }
    }
}

extension InputValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case scalar
        case vector2
        case vector3
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(InputValueKind.self, forKey: .type) {
        case .none:
            self = .none
        case .scalar:
            self = .scalar(try container.decode(Double.self, forKey: .scalar))
        case .vector2:
            self = .vector2(try container.decode(Vector2Value.self, forKey: .vector2))
        case .vector3:
            self = .vector3(try container.decode(Vector3Value.self, forKey: .vector3))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)

        switch self {
        case .none:
            break
        case .scalar(let value):
            try container.encode(value, forKey: .scalar)
        case .vector2(let value):
            try container.encode(value, forKey: .vector2)
        case .vector3(let value):
            try container.encode(value, forKey: .vector3)
        }
    }
}

struct ControlEvent: Codable, Equatable, Sendable {
    let controllerID: UUID
    let revision: Int
    let controlID: String
    let event: ControlEventKind
    let sequence: UInt64
    let timestamp: Date
    let value: InputValue
}

enum SemanticKey: String, Codable, CaseIterable, Hashable, Sendable {
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case space
    case letterB
    case escape
    case enter
}

enum KeyModifier: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case command
    case shift
    case option
    case control
}

struct KeyChordAction: Codable, Hashable, Sendable {
    let key: SemanticKey
    let modifiers: [KeyModifier]
}

struct MouseMoveAction: Codable, Equatable, Sendable {
    let gain: Double
    let deadZone: Double
}

enum ActionCapabilityID: String, Codable, CaseIterable, Equatable, Sendable {
    case keyChord
    case mouseMove
}

enum ActionDefinition: Equatable, Sendable {
    case keyChord(KeyChordAction)
    case mouseMove(MouseMoveAction)

    var acceptedInputKinds: Set<InputValueKind> {
        switch self {
        case .keyChord:
            [.none]
        case .mouseMove:
            [.vector2]
        }
    }

    var capabilityID: ActionCapabilityID {
        switch self {
        case .keyChord:
            .keyChord
        case .mouseMove:
            .mouseMove
        }
    }
}

extension ActionDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case configuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ActionCapabilityID.self, forKey: .type) {
        case .keyChord:
            self = .keyChord(try container.decode(KeyChordAction.self, forKey: .configuration))
        case .mouseMove:
            self = .mouseMove(try container.decode(MouseMoveAction.self, forKey: .configuration))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keyChord(let configuration):
            try container.encode(ActionCapabilityID.keyChord, forKey: .type)
            try container.encode(configuration, forKey: .configuration)
        case .mouseMove(let configuration):
            try container.encode(ActionCapabilityID.mouseMove, forKey: .type)
            try container.encode(configuration, forKey: .configuration)
        }
    }
}

struct ControlBinding: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let controlID: String
    let event: ControlEventKind
    let action: ActionDefinition
}
