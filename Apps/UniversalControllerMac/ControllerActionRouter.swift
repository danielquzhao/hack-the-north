import AppKit

enum ControllerActionRoutingError: LocalizedError {
    case targetMismatch

    var errorDescription: String? {
        switch self {
        case .targetMismatch:
            "The captured app no longer matches this controller."
        }
    }
}

@MainActor
final class ControllerActionRouter {
    let document: ControllerDocument
    let application: NSRunningApplication
    private var heldKeys: [String: KeyChordAction] = [:]
    private var activeDrag: (controlID: String, action: MouseDragAction)?
    private var active = true

    init(document: ControllerDocument, application: NSRunningApplication) throws {
        try SchemaValidator.validate(document)
        self.document = document
        self.application = application
    }

    func handle(_ event: ControlEvent) async throws {
        guard active else { return }
        guard application.bundleIdentifier == document.target.bundleIdentifier else {
            throw ControllerActionRoutingError.targetMismatch
        }

        let binding = try SchemaValidator.binding(for: event, in: document)
        switch binding.action {
        case .keyChord(let action):
            let holdID = event.event.dpadBindingEvent.map { "\(event.controlID):\($0.rawValue)" }
                ?? event.controlID
            if event.event.isKeyPressStart {
                guard heldKeys[holdID] == nil else { return }
                if heldKeys.values.contains(action) {
                    heldKeys[holdID] = action
                    return
                }
                try await MacActionExecutor.pressKeyChord(action, to: application)
                if active {
                    heldKeys[holdID] = action
                } else {
                    MacActionExecutor.releaseKeyChord(action)
                }
            } else if event.event.isKeyPressEnd {
                guard let held = heldKeys.removeValue(forKey: holdID) else { return }
                if !heldKeys.values.contains(held) {
                    MacActionExecutor.releaseKeyChord(held)
                }
            } else if event.event == .triggered {
                try await MacActionExecutor.sendKeyChord(action, to: application)
            }
        case .mouseMove(let action):
            guard case .vector2(let value) = event.value else { return }
            try MacActionExecutor.sendMouseMove(action, value: value, to: application)
        case .directionalKeys(let action):
            guard case .vector2(let value) = event.value else { return }
            let activeDirections = action.activeDirections(for: value)
            for direction in JoystickDirection.allCases where !activeDirections.contains(direction) {
                let holdID = "\(event.controlID):joystick:\(direction.rawValue)"
                guard let held = heldKeys.removeValue(forKey: holdID) else { continue }
                if !heldKeys.values.contains(held) {
                    MacActionExecutor.releaseKeyChord(held)
                }
            }
            for direction in JoystickDirection.allCases where activeDirections.contains(direction) {
                let holdID = "\(event.controlID):joystick:\(direction.rawValue)"
                guard heldKeys[holdID] == nil else { continue }
                let chord = action.chord(for: direction)
                if !heldKeys.values.contains(chord) {
                    try await MacActionExecutor.pressKeyChord(chord, to: application)
                }
                if active {
                    heldKeys[holdID] = chord
                } else if !heldKeys.values.contains(chord) {
                    MacActionExecutor.releaseKeyChord(chord)
                }
            }
        case .axisKeys(let action):
            guard case .vector2(let value) = event.value else { return }
            try await updateAxisKeys(
                action,
                value: value,
                controlID: event.controlID
            )
        case .mouseDrag(let action):
            guard case .vector2(let value) = event.value else { return }
            switch event.event {
            case .began:
                if let activeDrag { MacActionExecutor.endMouseDrag(activeDrag.action) }
                activeDrag = nil
                try await MacActionExecutor.beginMouseDrag(action, to: application)
                if active {
                    activeDrag = (event.controlID, action)
                } else {
                    MacActionExecutor.endMouseDrag(action)
                }
            case .changed:
                guard activeDrag?.controlID == event.controlID else { return }
                try MacActionExecutor.moveMouseDrag(action, value: value, to: application)
            case .ended:
                guard activeDrag?.controlID == event.controlID else { return }
                activeDrag = nil
                MacActionExecutor.endMouseDrag(action)
            default:
                return
            }
        case .scroll(let action):
            guard case .vector2(let value) = event.value else { return }
            if let activeDrag {
                MacActionExecutor.endMouseDrag(activeDrag.action)
                self.activeDrag = nil
            }
            try await MacActionExecutor.sendScroll(action, value: value, to: application)
        }
    }

    func deactivate() {
        active = false
        for action in Set(heldKeys.values) {
            MacActionExecutor.releaseKeyChord(action)
        }
        heldKeys.removeAll()
        cancelActiveDrag()
    }

    func cancelActiveDrag() {
        if let activeDrag { MacActionExecutor.endMouseDrag(activeDrag.action) }
        activeDrag = nil
    }

    private func updateAxisKeys(
        _ action: AxisKeysAction,
        value: Vector2Value,
        controlID: String
    ) async throws {
        let leftID = "\(controlID):axisLeft"
        let rightID = "\(controlID):axisRight"
        let wantLeft = value.x < -action.deadZone
        let wantRight = value.x > action.deadZone

        if !wantLeft, let held = heldKeys.removeValue(forKey: leftID) {
            if !heldKeys.values.contains(held) {
                MacActionExecutor.releaseKeyChord(held)
            }
        }
        if !wantRight, let held = heldKeys.removeValue(forKey: rightID) {
            if !heldKeys.values.contains(held) {
                MacActionExecutor.releaseKeyChord(held)
            }
        }

        // Prefer the stronger lean if both somehow cross the threshold.
        if wantLeft && wantRight {
            if value.x < 0 {
                try await pressAxisKey(action.left, holdID: leftID)
            } else {
                try await pressAxisKey(action.right, holdID: rightID)
            }
            return
        }
        if wantLeft {
            try await pressAxisKey(action.left, holdID: leftID)
        }
        if wantRight {
            try await pressAxisKey(action.right, holdID: rightID)
        }
    }

    private func pressAxisKey(_ action: KeyChordAction, holdID: String) async throws {
        guard heldKeys[holdID] == nil else { return }
        if heldKeys.values.contains(action) {
            heldKeys[holdID] = action
            return
        }
        try await MacActionExecutor.pressKeyChord(action, to: application)
        if active {
            heldKeys[holdID] = action
        } else {
            MacActionExecutor.releaseKeyChord(action)
        }
    }
}
