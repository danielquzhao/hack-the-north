import Foundation

struct ControllerDocument: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let revision: Int
    let name: String
    let target: ControllerTarget
    let layout: ControllerLayout
    let controls: [ControlDefinition]
    let bindings: [ControlBinding]

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

enum ControlCapabilityID: String, Codable, CaseIterable, Equatable, Sendable {
    case button
}

struct ButtonControlConfiguration: Codable, Equatable, Sendable {
    let variant: ButtonVariant
    let hapticsEnabled: Bool
}

enum ControlKind: Equatable, Sendable {
    case button(ButtonControlConfiguration)

    var outputKind: InputValueKind {
        switch self {
        case .button:
            .none
        }
    }

    var capabilityID: ControlCapabilityID {
        switch self {
        case .button:
            .button
        }
    }

    var supportedEvents: Set<ControlEventKind> {
        switch self {
        case .button:
            [.triggered]
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
        hapticsEnabled: Bool = true
    ) -> ControlDefinition {
        ControlDefinition(
            id: id,
            label: label,
            kind: .button(ButtonControlConfiguration(
                variant: variant,
                hapticsEnabled: hapticsEnabled
            ))
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
        }
    }
}

enum ControlEventKind: String, Codable, Equatable, Hashable, Sendable {
    case triggered
    case began
    case changed
    case ended
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

enum SemanticKey: String, Codable, CaseIterable, Equatable, Sendable {
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

struct KeyChordAction: Codable, Equatable, Sendable {
    let key: SemanticKey
    let modifiers: [KeyModifier]
}

enum ActionCapabilityID: String, Codable, CaseIterable, Equatable, Sendable {
    case keyChord
}

enum ActionDefinition: Equatable, Sendable {
    case keyChord(KeyChordAction)

    var acceptedInputKinds: Set<InputValueKind> {
        switch self {
        case .keyChord:
            [.none]
        }
    }

    var capabilityID: ActionCapabilityID {
        switch self {
        case .keyChord:
            .keyChord
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
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keyChord(let configuration):
            try container.encode(ActionCapabilityID.keyChord, forKey: .type)
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
