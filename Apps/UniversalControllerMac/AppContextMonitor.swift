import AppKit
import ApplicationServices

struct AppContext {
    let application: NSRunningApplication
    let windowTitle: String?
    let canReadWindowTitle: Bool

    var displayName: String {
        application.localizedName ?? "Unknown app"
    }
}

@MainActor
final class AppContextMonitor {
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    func start() {
        remember(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                self?.remember(application)
            }
        }
    }

    func capture() -> AppContext? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = frontmost
        }
        guard let application = lastExternalApplication else { return nil }
        let canReadWindowTitle = AXIsProcessTrusted()
        return AppContext(
            application: application,
            windowTitle: canReadWindowTitle ? focusedWindowTitle(for: application) : nil,
            canReadWindowTitle: canReadWindowTitle
        )
    }

    private func remember(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApplication = application
    }

    private func focusedWindowTitle(for application: NSRunningApplication) -> String? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }

        let windowElement = unsafeDowncast(windowValue, to: AXUIElement.self)
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String,
              !title.isEmpty else { return nil }
        return title
    }
}
