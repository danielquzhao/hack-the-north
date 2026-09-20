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

    func replacing(revision: Int? = nil, layouts: ControllerLayouts? = nil) -> ControllerDocument {
        ControllerDocument(
            schemaVersion: schemaVersion,
            id: id,
            revision: revision ?? self.revision,
            name: name,
            target: target,
            preferredOrientation: preferredOrientation,
            layouts: layouts ?? self.layouts,
            controls: controls,
            bindings: bindings
        )
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
    let items: [ControllerLayoutItem]
}

/// Normalized top-left origin frame in the phone canvas. Values are 0...1.
struct LayoutRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }

    func clamped(minimumSize: Double = 0.08) -> LayoutRect {
        let width = min(1, max(minimumSize, width))
        let height = min(1, max(minimumSize, height))
        let x = min(max(0, x), 1 - width)
        let y = min(max(0, y), 1 - height)
        return LayoutRect(x: x, y: y, width: width, height: height)
    }
}

struct ControllerLayoutItem: Codable, Equatable, Sendable, Identifiable {
    var id: String { controlID }

    let controlID: String
    let frame: LayoutRect
}

enum AbsoluteLayoutBuilder {
    /// Packs grid-style spans into normalized absolute frames for demos and AI conversion.
    static func fromGrid(
        columns: Int,
        specs: [(id: String, columnSpan: Int, rowSpan: Int)],
        gap: Double = 0.03
    ) -> ControllerLayout {
        let columns = max(1, columns)
        var cursorX = 0
        var cursorY = 0
        var rowHeight = 1
        var maxRow = 1
        var placed: [(String, Int, Int, Int, Int)] = []

        for spec in specs {
            let span = min(max(1, spec.columnSpan), columns)
            let height = max(1, spec.rowSpan)
            if cursorX + span > columns {
                cursorX = 0
                cursorY += rowHeight
                rowHeight = height
            }
            rowHeight = max(rowHeight, height)
            placed.append((spec.id, cursorX, cursorY, span, height))
            cursorX += span
            maxRow = max(maxRow, cursorY + height)
        }

        let cellWidth = (1 - gap * Double(columns + 1)) / Double(columns)
        let cellHeight = (1 - gap * Double(maxRow + 1)) / Double(max(maxRow, 1))
        let items = placed.map { id, column, row, span, height in
            ControllerLayoutItem(
                controlID: id,
                frame: LayoutRect(
                    x: gap + Double(column) * (cellWidth + gap),
                    y: gap + Double(row) * (cellHeight + gap),
                    width: Double(span) * cellWidth + Double(span - 1) * gap,
                    height: Double(height) * cellHeight + Double(height - 1) * gap
                ).clamped()
            )
        }
        return ControllerLayout(items: items)
    }
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
}

struct ButtonControlConfiguration: Equatable, Sendable {
    let variant: ButtonVariant
    let hapticsEnabled: Bool
    let face: ButtonFace
    /// RGB hex without `#`, e.g. `5856D6`. Used for standard (non-face) buttons.
    let tintHex: String

    static func defaultTintHex(for variant: ButtonVariant) -> String {
        switch variant {
        case .primary: "5856D6"
        case .secondary: "8E8E93"
        case .destructive: "FF3B30"
        }
    }

    static func defaultTintHex(for face: ButtonFace, variant: ButtonVariant = .primary) -> String {
        switch face {
        case .standard: defaultTintHex(for: variant)
        case .a: "34C759"
        case .b: "FF3B30"
        case .x: "007AFF"
        case .y: "FF9500"
        }
    }

    init(
        variant: ButtonVariant = .primary,
        hapticsEnabled: Bool = true,
        face: ButtonFace = .standard,
        tintHex: String? = nil
    ) {
        self.variant = variant
        self.hapticsEnabled = hapticsEnabled
        self.face = face
        self.tintHex = tintHex ?? Self.defaultTintHex(for: face, variant: variant)
    }
}

extension ButtonControlConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case variant
        case hapticsEnabled
        case face
        case tintHex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let variant = try container.decode(ButtonVariant.self, forKey: .variant)
        self.variant = variant
        hapticsEnabled = try container.decode(Bool.self, forKey: .hapticsEnabled)
        face = try container.decodeIfPresent(ButtonFace.self, forKey: .face) ?? .standard
        tintHex = try container.decodeIfPresent(String.self, forKey: .tintHex)
            ?? Self.defaultTintHex(for: face, variant: variant)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(variant, forKey: .variant)
        try container.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try container.encode(face, forKey: .face)
        try container.encode(tintHex, forKey: .tintHex)
    }
}

struct JoystickControlConfiguration: Codable, Equatable, Sendable {
    let hapticsEnabled: Bool
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

    var outputKind: InputValueKind {
        switch self {
        case .button:
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
        }
    }

    var supportedEvents: Set<ControlEventKind> {
        switch self {
        case .button:
            [.triggered, .began, .ended]
        case .joystick, .motion:
            [.changed]
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
        face: ButtonFace = .standard,
        tintHex: String? = nil
    ) -> ControlDefinition {
        ControlDefinition(
            id: id,
            label: label,
            kind: .button(ButtonControlConfiguration(
                variant: variant,
                hapticsEnabled: hapticsEnabled,
                face: face,
                tintHex: tintHex
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

enum SemanticKey: String, Codable, CaseIterable, Hashable, Sendable {
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case space
    case letterB
    case escape
    case enter
    case tab
    case delete
    case letterA, letterC, letterD, letterE, letterF, letterG, letterH, letterI
    case letterJ, letterK, letterL, letterM, letterN, letterO, letterP, letterQ
    case letterR, letterS, letterT, letterU, letterV, letterW, letterX, letterY, letterZ
    case digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9
    case period
    case comma
    case slash
    case semicolon
    case quote
    case leftBracket
    case rightBracket
    case backslash
    case grave
    case minus
    case equal

    var displayName: String {
        switch self {
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .space: "Space"
        case .escape: "Esc"
        case .enter: "Return"
        case .tab: "Tab"
        case .delete: "Delete"
        case .letterA: "A"
        case .letterB: "B"
        case .letterC: "C"
        case .letterD: "D"
        case .letterE: "E"
        case .letterF: "F"
        case .letterG: "G"
        case .letterH: "H"
        case .letterI: "I"
        case .letterJ: "J"
        case .letterK: "K"
        case .letterL: "L"
        case .letterM: "M"
        case .letterN: "N"
        case .letterO: "O"
        case .letterP: "P"
        case .letterQ: "Q"
        case .letterR: "R"
        case .letterS: "S"
        case .letterT: "T"
        case .letterU: "U"
        case .letterV: "V"
        case .letterW: "W"
        case .letterX: "X"
        case .letterY: "Y"
        case .letterZ: "Z"
        case .digit0: "0"
        case .digit1: "1"
        case .digit2: "2"
        case .digit3: "3"
        case .digit4: "4"
        case .digit5: "5"
        case .digit6: "6"
        case .digit7: "7"
        case .digit8: "8"
        case .digit9: "9"
        case .period: "."
        case .comma: ","
        case .slash: "/"
        case .semicolon: ";"
        case .quote: "'"
        case .leftBracket: "["
        case .rightBracket: "]"
        case .backslash: "\\"
        case .grave: "`"
        case .minus: "-"
        case .equal: "="
        }
    }

    static func from(keyCode: UInt16) -> SemanticKey? {
        switch keyCode {
        case 0: .letterA
        case 1: .letterS
        case 2: .letterD
        case 3: .letterF
        case 4: .letterH
        case 5: .letterG
        case 6: .letterZ
        case 7: .letterX
        case 8: .letterC
        case 9: .letterV
        case 11: .letterB
        case 12: .letterQ
        case 13: .letterW
        case 14: .letterE
        case 15: .letterR
        case 16: .letterY
        case 17: .letterT
        case 18: .digit1
        case 19: .digit2
        case 20: .digit3
        case 21: .digit4
        case 22: .digit6
        case 23: .digit5
        case 24: .equal
        case 25: .digit9
        case 26: .digit7
        case 27: .minus
        case 28: .digit8
        case 29: .digit0
        case 30: .rightBracket
        case 31: .letterO
        case 32: .letterU
        case 33: .leftBracket
        case 34: .letterI
        case 35: .letterP
        case 36: .enter
        case 37: .letterL
        case 38: .letterJ
        case 39: .quote
        case 40: .letterK
        case 41: .semicolon
        case 42: .backslash
        case 43: .comma
        case 44: .slash
        case 45: .letterN
        case 46: .letterM
        case 47: .period
        case 48: .tab
        case 49: .space
        case 50: .grave
        case 51: .delete
        case 53: .escape
        case 123: .leftArrow
        case 124: .rightArrow
        case 125: .downArrow
        case 126: .upArrow
        default: nil
        }
    }
}

enum KeyModifier: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case command
    case shift
    case option
    case control

    var displayName: String {
        switch self {
        case .command: "cmd"
        case .shift: "shift"
        case .option: "option"
        case .control: "ctrl"
        }
    }
}

struct KeyChordAction: Codable, Hashable, Sendable {
    let key: SemanticKey
    let modifiers: [KeyModifier]

    var displayString: String {
        let parts = modifiers.map(\.displayName) + [key.displayName]
        return parts.joined(separator: " + ")
    }
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
