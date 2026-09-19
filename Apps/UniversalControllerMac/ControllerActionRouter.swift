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
struct ControllerActionRouter {
    let document: ControllerDocument
    let application: NSRunningApplication

    init(document: ControllerDocument, application: NSRunningApplication) throws {
        try SchemaValidator.validate(document)
        self.document = document
        self.application = application
    }

    func handle(_ event: ControlEvent) async throws {
        guard application.bundleIdentifier == document.target.bundleIdentifier else {
            throw ControllerActionRoutingError.targetMismatch
        }

        let binding = try SchemaValidator.binding(for: event, in: document)
        switch binding.action {
        case .keyChord(let action):
            try await MacActionExecutor.sendKeyChord(action, to: application)
        case .mouseMove(let action):
            guard case .vector2(let value) = event.value else { return }
            try MacActionExecutor.sendMouseMove(action, value: value, to: application)
        }
    }
}
