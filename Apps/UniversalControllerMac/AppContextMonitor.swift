import AppKit
import ApplicationServices

struct AppContext {
    let application: NSRunningApplication
    let windowTitle: String?
    let windowFrame: CGRect?
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
        let focusedWindow = canReadWindowTitle ? focusedWindow(for: application) : nil
        return AppContext(
            application: application,
            windowTitle: focusedWindow.flatMap(windowTitle),
            windowFrame: focusedWindow.flatMap(windowFrame),
            canReadWindowTitle: canReadWindowTitle
        )
    }

    private func remember(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApplication = application
    }

    private func focusedWindow(for application: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }

        return unsafeDowncast(windowValue, to: AXUIElement.self)
    }

    private func windowTitle(of window: AXUIElement) -> String? {
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String,
              !title.isEmpty else { return nil }
        return title
    }

    private func windowFrame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }
}
