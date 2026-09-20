import AppKit
import CoreGraphics
import ScreenCaptureKit

enum TargetWindowScreenshotError: LocalizedError {
    case permissionRequired
    case noWindowForApp
    case ambiguousWindows
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            "Allow Screen Recording for aiClicker in System Settings, then quit and reopen the Mac app."
        case .noWindowForApp:
            "No on-screen window from the captured app is available. Bring its window to the front and reopen aiClicker."
        case .ambiguousWindows:
            "Several windows from the captured app are open, and the focused one could not be matched. Bring the desired window to the front and reopen aiClicker."
        case .imageEncodingFailed:
            "The app window could not be converted to an image. Try again."
        }
    }
}

@MainActor
enum TargetWindowScreenshot {
    static func captureJPEG(
        of application: NSRunningApplication,
        title: String?,
        frame: CGRect?
    ) async throws -> Data {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw TargetWindowScreenshotError.permissionRequired
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let windows = content.windows.filter { window in
            window.owningApplication?.processID == application.processIdentifier &&
            window.frame.width >= 120 && window.frame.height >= 80
        }
        guard !windows.isEmpty else { throw TargetWindowScreenshotError.noWindowForApp }
        let titleMatches = windows.filter { titleMatches($0.title, title) }
        let candidates = titleMatches.isEmpty ? windows : titleMatches
        let window = closestWindow(to: frame, among: candidates) ??
            (titleMatches.count == 1 ? titleMatches.first : nil) ??
            (windows.count == 1 ? windows.first : nil)
        guard let window else { throw TargetWindowScreenshotError.ambiguousWindows }

        let longestSide = max(window.frame.width, window.frame.height)
        let scale = min(2, 1_600 / longestSide)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpeg = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.78]
        ) else {
            throw TargetWindowScreenshotError.imageEncodingFailed
        }
        return jpeg
    }

    private static func titleMatches(_ screenCaptureTitle: String?, _ accessibilityTitle: String?) -> Bool {
        guard let screenCaptureTitle, let accessibilityTitle else { return false }
        let capture = screenCaptureTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let accessibility = accessibilityTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !capture.isEmpty, !accessibility.isEmpty else { return false }
        return capture == accessibility ||
            (min(capture.count, accessibility.count) >= 12 &&
             (capture.contains(accessibility) || accessibility.contains(capture)))
    }

    private static func closestWindow(to focusedFrame: CGRect?, among windows: [SCWindow]) -> SCWindow? {
        guard let focusedFrame else { return nil }
        let scored = windows.map { window in
            let frame = window.frame
            let difference = abs(frame.minX - focusedFrame.minX) +
                abs(frame.minY - focusedFrame.minY) +
                abs(frame.width - focusedFrame.width) +
                abs(frame.height - focusedFrame.height)
            return (window, difference)
        }
        guard let closest = scored.min(by: { $0.1 < $1.1 }), closest.1 <= 120 else {
            return nil
        }
        return closest.0
    }
}
