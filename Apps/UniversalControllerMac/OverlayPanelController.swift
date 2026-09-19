import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController {
    private let contextMonitor: AppContextMonitor
    private var panel: OverlayPanel?
    private var outsideClickMonitor: Any?
    private var localEventMonitor: Any?

    init(contextMonitor: AppContextMonitor) {
        self.contextMonitor = contextMonitor
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            open()
        }
    }

    private func open() {
        let context = contextMonitor.capture()
        let panel = makePanel(context: context)
        self.panel = panel
        center(panel)
        panel.makeKeyAndOrderFront(nil)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            return event
        }
    }

    func close() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel(context: AppContext?) -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 430),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: MacOverlayView(context: context) { [weak self] in
            self?.close()
        })
        return panel
    }

    private func center(_ panel: NSPanel) {
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.midY - panel.frame.height / 2
        ))
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
