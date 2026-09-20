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
            switch event.event {
            case .began:
                guard heldKeys[event.controlID] == nil else { return }
                if heldKeys.values.contains(action) {
                    heldKeys[event.controlID] = action
                    return
                }
                try await MacActionExecutor.pressKeyChord(action, to: application)
                if active {
                    heldKeys[event.controlID] = action
                } else {
                    MacActionExecutor.releaseKeyChord(action)
                }
            case .ended:
                guard let held = heldKeys.removeValue(forKey: event.controlID) else { return }
                if !heldKeys.values.contains(held) {
                    MacActionExecutor.releaseKeyChord(held)
                }
            case .triggered, .pinchedIn, .pinchedOut,
                 .rotatedClockwise, .rotatedCounterclockwise:
                try await MacActionExecutor.sendKeyChord(action, to: application)
            case .changed, .pinchChanged:
                return
            }
        case .mouseMove(let action):
            guard case .vector2(let value) = event.value else { return }
            try MacActionExecutor.sendMouseMove(action, value: value, to: application)
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
}
