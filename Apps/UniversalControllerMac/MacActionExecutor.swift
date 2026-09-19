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
            "Allow Universal Controller to send keyboard events, then try again."
        case .activationFailed:
            "Couldn't bring Keynote to the front. No key was sent."
        case .eventUnavailable:
            "Couldn't create the Right Arrow key event."
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
        guard application.bundleIdentifier == "com.apple.iWork.Keynote" else {
            throw MacActionError.wrongTarget
        }
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
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 124, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 124, keyDown: false) else {
            throw MacActionError.eventUnavailable
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
