import AppKit
import ApplicationServices
import CoreGraphics

enum MacActionError: LocalizedError {
    case wrongTarget
    case targetQuit
    case accessibilityRequired
    case keyboardControlRequired
    case activationFailed
    case eventUnavailable

    var errorDescription: String? {
        switch self {
        case .wrongTarget:
            "Open Keynote before using the Next Slide test button."
        case .targetQuit:
            "The target app has quit. Open it and try again."
        case .accessibilityRequired:
            "Allow aiClicker in Accessibility settings, then try again."
        case .keyboardControlRequired:
            "Keyboard event access is still unavailable. No key was sent."
        case .activationFailed:
            "Couldn't bring the target app to the front. No key was sent."
        case .eventUnavailable:
            "Couldn't create the requested keyboard event."
        }
    }
}

struct MacPermissionStatus {
    let accessibility: Bool
    let keyboardControl: Bool

    var canControl: Bool { accessibility && keyboardControl }
}

@MainActor
enum MacActionExecutor {
    static func isKeynote(_ application: NSRunningApplication) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        return bundleIdentifier == "com.apple.Keynote" || bundleIdentifier == "com.apple.iWork.Keynote"
    }

    static var permissionStatus: MacPermissionStatus {
        MacPermissionStatus(
            accessibility: AXIsProcessTrusted(),
            keyboardControl: CGPreflightPostEventAccess()
        )
    }

    static func requestNextPermission() {
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        } else if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }
    }

    static func sendNextSlide(to application: NSRunningApplication) async throws {
        guard isKeynote(application) else {
            throw MacActionError.wrongTarget
        }
        try await sendKeyChord(
            KeyChordAction(key: .rightArrow, modifiers: []),
            to: application
        )
    }

    static func sendKeyChord(
        _ action: KeyChordAction,
        to application: NSRunningApplication
    ) async throws {
        try await prepareKeyTarget(application)
        try postKeyChord(action, down: true)
        try postKeyChord(action, down: false)
    }

    static func pressKeyChord(
        _ action: KeyChordAction,
        to application: NSRunningApplication
    ) async throws {
        try await prepareKeyTarget(application)
        try postKeyChord(action, down: true)
    }

    static func releaseKeyChord(_ action: KeyChordAction) {
        // Always release, even after focus or permissions change, to avoid a stuck key.
        try? postKeyChord(action, down: false)
    }

    private static func prepareKeyTarget(_ application: NSRunningApplication) async throws {
        guard !application.isTerminated else {
            throw MacActionError.targetQuit
        }
        guard AXIsProcessTrusted() else {
            throw MacActionError.accessibilityRequired
        }
        guard CGPreflightPostEventAccess() else {
            throw MacActionError.keyboardControlRequired
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
            return
        }
        guard application.activate() else {
            throw MacActionError.activationFailed
        }

        // Activation is asynchronous. Never post the shortcut while another app is frontmost.
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                break
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            throw MacActionError.activationFailed
        }

        // Give the target window time to become key after the overlay disappears.
        try await Task.sleep(for: .milliseconds(100))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            throw MacActionError.activationFailed
        }

    }

    private static func postKeyChord(_ action: KeyChordAction, down: Bool) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = keyCode(for: action.key)
        let flags = eventFlags(for: action.modifiers)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else {
            throw MacActionError.eventUnavailable
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func sendMouseMove(
        _ action: MouseMoveAction,
        value: Vector2Value,
        to application: NSRunningApplication
    ) throws {
        guard !application.isTerminated else { throw MacActionError.targetQuit }
        guard AXIsProcessTrusted() else { throw MacActionError.accessibilityRequired }
        guard CGPreflightPostEventAccess() else { throw MacActionError.keyboardControlRequired }

        func distance(_ component: Double) -> Double {
            let magnitude = abs(component)
            guard magnitude > action.deadZone else { return 0 }
            return (component < 0 ? -1 : 1) *
                (magnitude - action.deadZone) / (1 - action.deadZone) * action.gain
        }

        let dx = distance(value.x)
        let dy = distance(value.y)
        guard dx != 0 || dy != 0 else { return }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
            guard application.activate() else { throw MacActionError.activationFailed }
        }
        guard let current = CGEvent(source: nil)?.location,
              let event = CGEvent(
                mouseEventSource: CGEventSource(stateID: .hidSystemState),
                mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: current.x + dx, y: current.y - dy),
                mouseButton: .left
              ) else {
            throw MacActionError.eventUnavailable
        }
        event.post(tap: .cghidEventTap)
    }

    static func beginMouseDrag(
        _ action: MouseDragAction,
        to application: NSRunningApplication
    ) async throws {
        try await preparePointerTarget(application)
        try postMouseDrag(action, phase: .began, value: .init(x: 0, y: 0))
    }

    static func moveMouseDrag(
        _ action: MouseDragAction,
        value: Vector2Value,
        to application: NSRunningApplication
    ) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            throw MacActionError.activationFailed
        }
        try postMouseDrag(action, phase: .changed, value: value)
    }

    static func endMouseDrag(_ action: MouseDragAction) {
        try? postMouseDrag(action, phase: .ended, value: .init(x: 0, y: 0))
    }

    static func sendScroll(
        _ action: ScrollAction,
        value: Vector2Value,
        to application: NSRunningApplication
    ) async throws {
        try await preparePointerTarget(application)
        let pixels = Int32((value.y * action.gain * 20).rounded())
        guard pixels != 0,
              let event = CGEvent(
                  scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
                  units: .pixel,
                  wheelCount: 1,
                  wheel1: pixels,
                  wheel2: 0,
                  wheel3: 0
              ) else { return }
        if let current = CGEvent(source: nil)?.location {
            event.location = current
        }
        event.post(tap: .cghidEventTap)
    }

    private enum DragPhase { case began, changed, ended }

    private static func postMouseDrag(
        _ action: MouseDragAction,
        phase: DragPhase,
        value: Vector2Value
    ) throws {
        guard let current = CGEvent(source: nil)?.location else {
            throw MacActionError.eventUnavailable
        }
        func distance(_ component: Double) -> Double {
            let magnitude = abs(component)
            guard magnitude > action.deadZone else { return 0 }
            return (component < 0 ? -1 : 1) *
                (magnitude - action.deadZone) / (1 - action.deadZone) * action.gain
        }
        let position = CGPoint(
            x: current.x + distance(value.x),
            y: current.y + distance(value.y)
        )
        let type: CGEventType
        let button: CGMouseButton
        switch action.button {
        case .left:
            button = .left
            type = switch phase {
            case .began: .leftMouseDown
            case .changed: .leftMouseDragged
            case .ended: .leftMouseUp
            }
        case .right:
            button = .right
            type = switch phase {
            case .began: .rightMouseDown
            case .changed: .rightMouseDragged
            case .ended: .rightMouseUp
            }
        case .middle:
            button = .center
            type = switch phase {
            case .began: .otherMouseDown
            case .changed: .otherMouseDragged
            case .ended: .otherMouseUp
            }
        }
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: position,
            mouseButton: button
        ) else { throw MacActionError.eventUnavailable }
        event.flags = eventFlags(for: action.modifiers)
        event.post(tap: .cghidEventTap)
    }

    private static func preparePointerTarget(_ application: NSRunningApplication) async throws {
        guard !application.isTerminated else { throw MacActionError.targetQuit }
        guard AXIsProcessTrusted() else { throw MacActionError.accessibilityRequired }
        guard CGPreflightPostEventAccess() else { throw MacActionError.keyboardControlRequired }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
            return
        }
        guard application.activate() else { throw MacActionError.activationFailed }
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                return
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        throw MacActionError.activationFailed
    }

    private static func keyCode(for key: SemanticKey) -> CGKeyCode {
        switch key {
        case .letterA: 0
        case .letterS: 1
        case .letterD: 2
        case .letterF: 3
        case .letterH: 4
        case .letterG: 5
        case .letterZ: 6
        case .letterX: 7
        case .letterC: 8
        case .letterV: 9
        case .letterB: 11
        case .letterQ: 12
        case .letterW: 13
        case .letterE: 14
        case .letterR: 15
        case .letterY: 16
        case .letterT: 17
        case .digit1: 18
        case .digit2: 19
        case .digit3: 20
        case .digit4: 21
        case .digit6: 22
        case .digit5: 23
        case .equal: 24
        case .digit9: 25
        case .digit7: 26
        case .minus: 27
        case .digit8: 28
        case .digit0: 29
        case .rightBracket: 30
        case .letterO: 31
        case .letterU: 32
        case .leftBracket: 33
        case .letterI: 34
        case .letterP: 35
        case .enter: 36
        case .letterL: 37
        case .letterJ: 38
        case .quote: 39
        case .letterK: 40
        case .semicolon: 41
        case .backslash: 42
        case .comma: 43
        case .slash: 44
        case .letterN: 45
        case .letterM: 46
        case .period: 47
        case .tab: 48
        case .space: 49
        case .grave: 50
        case .delete: 51
        case .escape: 53
        case .leftArrow: 123
        case .rightArrow: 124
        case .downArrow: 125
        case .upArrow: 126
        }
    }

    private static func eventFlags(for modifiers: [KeyModifier]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { flags, modifier in
            switch modifier {
            case .command:
                flags.insert(.maskCommand)
            case .shift:
                flags.insert(.maskShift)
            case .option:
                flags.insert(.maskAlternate)
            case .control:
                flags.insert(.maskControl)
            }
        }
    }
}
