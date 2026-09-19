import Foundation

struct ControlCapabilityDescriptor: Codable, Equatable, Sendable {
    let id: ControlCapabilityID
    let outputKind: InputValueKind
    let events: [ControlEventKind]
}

struct ActionCapabilityDescriptor: Codable, Equatable, Sendable {
    let id: ActionCapabilityID
    let acceptedInputKinds: [InputValueKind]
}

struct ControllerCapabilityCatalog: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let controls: [ControlCapabilityDescriptor]
    let actions: [ActionCapabilityDescriptor]
    let buttonFaces: [ButtonFace]
    let motionSources: [MotionSource]

    static let current = ControllerCapabilityCatalog(
        schemaVersion: ControllerDocument.currentSchemaVersion,
        controls: [
            ControlCapabilityDescriptor(
                id: .button,
                outputKind: .none,
                events: [.triggered, .began, .ended]
            ),
            ControlCapabilityDescriptor(
                id: .joystick,
                outputKind: .vector2,
                events: [.changed]
            ),
            ControlCapabilityDescriptor(
                id: .motion,
                outputKind: .vector2,
                events: [.changed]
            ),
        ],
        actions: [
            ActionCapabilityDescriptor(
                id: .keyChord,
                acceptedInputKinds: [.none]
            ),
            ActionCapabilityDescriptor(
                id: .mouseMove,
                acceptedInputKinds: [.vector2]
            ),
        ],
        buttonFaces: ButtonFace.allCases,
        motionSources: MotionSource.allCases
    )
}

struct SchemaValidationError: LocalizedError, Equatable {
    let reason: String

    var errorDescription: String? {
        reason
    }
}

enum SchemaValidator {
    static let maximumControls = 32
    static let maximumBindings = 64
    static let maximumColumns = 4
    static let maximumSpan = 4

    static func validate(_ document: ControllerDocument) throws {
        guard document.schemaVersion == ControllerDocument.currentSchemaVersion else {
            throw error("Unsupported controller schema version \(document.schemaVersion).")
        }
        guard document.revision > 0 else {
            throw error("Controller revision must be positive.")
        }
        guard isValidDisplayText(document.name, maximumLength: 80) else {
            throw error("Controller name must contain between 1 and 80 characters.")
        }
        guard !document.target.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw error("Controller target bundle identifier is required.")
        }
        guard isValidDisplayText(document.target.displayName, maximumLength: 80) else {
            throw error("Controller target display name is invalid.")
        }
        guard (1...maximumControls).contains(document.controls.count) else {
            throw error("Controller must contain between 1 and \(maximumControls) controls.")
        }
        guard document.bindings.count <= maximumBindings else {
            throw error("Controller cannot contain more than \(maximumBindings) bindings.")
        }
        let controlIDs = document.controls.map(\.id)
        guard Set(controlIDs).count == controlIDs.count else {
            throw error("Control IDs must be unique.")
        }

        for control in document.controls {
            guard isValidIdentifier(control.id) else {
                throw error("Control ID '\(control.id)' is invalid.")
            }
            guard isValidDisplayText(control.label, maximumLength: 80) else {
                throw error("Control '\(control.id)' has an invalid label.")
            }
        }
        guard document.controls.filter({
            if case .motion = $0.kind { return true }
            return false
        }).count <= 1 else {
            throw error("Only one motion control is supported per controller.")
        }

        try validateLayout(
            document.layouts.portrait,
            orientation: .portrait,
            controlIDs: controlIDs
        )
        try validateLayout(
            document.layouts.landscape,
            orientation: .landscape,
            controlIDs: controlIDs
        )

        let bindingIDs = document.bindings.map(\.id)
        guard Set(bindingIDs).count == bindingIDs.count else {
            throw error("Binding IDs must be unique.")
        }
        guard Set(document.bindings.map(\.controlID)) == Set(controlIDs) else {
            throw error("Every control must have an action binding.")
        }

        var boundEvents = Set<String>()
        for binding in document.bindings {
            guard isValidIdentifier(binding.id) else {
                throw error("Binding ID '\(binding.id)' is invalid.")
            }
            guard let control = document.control(id: binding.controlID) else {
                throw error("Binding '\(binding.id)' references an unknown control.")
            }
            guard control.kind.supportedEvents.contains(binding.event) else {
                throw error("Control '\(control.id)' does not emit '\(binding.event.rawValue)'.")
            }
            guard binding.action.acceptedInputKinds.contains(control.kind.outputKind) else {
                throw error(
                    "Action '\(binding.action.capabilityID.rawValue)' cannot accept " +
                    "'\(control.kind.outputKind.rawValue)' input."
                )
            }

            let eventKey = "\(binding.controlID):\(binding.event.rawValue)"
            guard boundEvents.insert(eventKey).inserted else {
                throw error(
                    "A control event may have only one binding in schema version " +
                    "\(ControllerDocument.currentSchemaVersion)."
                )
            }

            if case .keyChord(let action) = binding.action,
               Set(action.modifiers).count != action.modifiers.count {
                throw error("Keyboard shortcut modifiers cannot contain duplicates.")
            }
            if case .mouseMove(let action) = binding.action,
               (!action.gain.isFinite || !(1...40).contains(action.gain) ||
                !action.deadZone.isFinite || !(0...0.5).contains(action.deadZone)) {
                throw error("Mouse movement gain or dead zone is out of range.")
            }
        }
    }

    private static func validateLayout(
        _ layout: ControllerLayout,
        orientation: ControllerOrientation,
        controlIDs: [String]
    ) throws {
        guard (1...maximumColumns).contains(layout.columns) else {
            throw error(
                "\(orientation.displayName) layout column count must be between 1 and \(maximumColumns)."
            )
        }

        let layoutIDs = layout.items.map(\.controlID)
        guard Set(layoutIDs).count == layoutIDs.count else {
            throw error("Each control may appear only once in the \(orientation.rawValue) layout.")
        }
        guard Set(layoutIDs) == Set(controlIDs) else {
            throw error(
                "\(orientation.displayName) layout must contain every controller control exactly once."
            )
        }

        for item in layout.items {
            guard (1...layout.columns).contains(item.columnSpan) else {
                throw error(
                    "Control '\(item.controlID)' has an invalid \(orientation.rawValue) column span."
                )
            }
            guard (1...maximumSpan).contains(item.rowSpan) else {
                throw error(
                    "Control '\(item.controlID)' has an invalid \(orientation.rawValue) row span."
                )
            }
        }
    }

    static func binding(
        for event: ControlEvent,
        in document: ControllerDocument
    ) throws -> ControlBinding {
        guard event.controllerID == document.id else {
            throw error("Control event belongs to another controller.")
        }
        guard event.revision == document.revision else {
            throw error("Control event uses a stale controller revision.")
        }
        guard let control = document.control(id: event.controlID) else {
            throw error("Control event references an unknown control.")
        }
        guard control.kind.supportedEvents.contains(event.event) else {
            throw error("Control does not emit this event.")
        }
        guard event.value.kind == control.kind.outputKind else {
            throw error("Control event contains the wrong value type.")
        }
        if case .vector2(let value) = event.value,
           (!value.x.isFinite || !value.y.isFinite ||
            abs(value.x) > 1 || abs(value.y) > 1) {
            throw error("Control event vector must be between -1 and 1.")
        }
        let binding = document.binding(controlID: event.controlID, event: event.event)
            ?? (event.event == .began || event.event == .ended
                ? document.binding(controlID: event.controlID, event: .triggered)
                : nil)
        guard let binding else {
            throw error("Control event has no action binding.")
        }
        return binding
    }

    private static func isValidIdentifier(_ identifier: String) -> Bool {
        guard (1...64).contains(identifier.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return identifier.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isValidDisplayText(_ text: String, maximumLength: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximumLength
    }

    private static func error(_ reason: String) -> SchemaValidationError {
        SchemaValidationError(reason: reason)
    }
}
