import AppKit
import SwiftUI

@main
struct UniversalControllerMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private let contextMonitor = AppContextMonitor()
    private var overlayController: OverlayPanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        contextMonitor.start()
        overlayController = OverlayPanelController(contextMonitor: contextMonitor)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "Universal Controller")
            button.toolTip = "Universal Controller"
            button.target = self
            button.action = #selector(toggleOverlay)
        }
        statusItem = item
    }

    @objc private func toggleOverlay() {
        overlayController?.toggle()
    }
}
