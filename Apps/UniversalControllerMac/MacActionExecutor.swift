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
            "Keynote has quit. Open it and try again."
        case .accessibilityRequired:
            "Allow Universal Controller in Accessibility settings, then try again."
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
        guard !application.isTerminated else {
            throw MacActionError.targetQuit
        }
        guard AXIsProcessTrusted() else {
            throw MacActionError.accessibilityRequired
        }
        guard CGPreflightPostEventAccess() else {
            throw MacActionError.keyboardControlRequired
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

        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = keyCode(for: action.key)
        let flags = eventFlags(for: action.modifiers)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw MacActionError.eventUnavailable
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func keyCode(for key: SemanticKey) -> CGKeyCode {
        switch key {
        case .leftArrow:
            123
        case .rightArrow:
            124
        case .downArrow:
            125
        case .upArrow:
            126
        case .space:
            49
        case .letterB:
            11
        case .escape:
            53
        case .enter:
            36
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
