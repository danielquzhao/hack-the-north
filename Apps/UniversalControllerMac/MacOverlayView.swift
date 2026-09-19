import AppKit
import SwiftUI

struct MacOverlayView: View {
    let context: AppContext?
    let errorMessage: String?
    @ObservedObject var pairingHost: PairingSessionHost
    let onClose: () -> Void
    let onRequestPermission: () -> Void
    let onStartPairing: () -> Void
    let onNextSlide: () -> Void

    @State private var prompt = ""
    @State private var permissionStatus = MacActionExecutor.permissionStatus
    @State private var showKeyboardHelp = false
    @FocusState private var promptIsFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Universal Controller")
                            .font(.title2.weight(.semibold))
                        Text("Design a controller for the app you're using")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("CURRENT APP")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        if let icon = context?.application.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 32, height: 32)
                        } else {
                            Image(systemName: "macwindow")
                                .frame(width: 32, height: 32)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context?.displayName ?? "No app captured")
                                .fontWeight(.medium)
                            Text(context?.windowTitle ?? (context?.canReadWindowTitle == false
                                ? "Allow Accessibility access to read window titles"
                                : "Window title unavailable"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                }

                HStack(spacing: 12) {
                    Image(systemName: permissionStatus.canControl ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(permissionStatus.canControl ? .green : .orange)
                    Text(permissionStatus.canControl ? "Accessibility and keyboard control ready"
                        : permissionStatus.accessibility ? "Keyboard event access required" : "Accessibility access required")
                        .font(.subheadline)
                    Spacer()
                    if !permissionStatus.canControl {
                        Button(permissionStatus.accessibility ? "Request Keyboard Access" : "Grant Accessibility") {
                            onRequestPermission()
                            permissionStatus = MacActionExecutor.permissionStatus
                            showKeyboardHelp = permissionStatus.accessibility && !permissionStatus.keyboardControl
                        }
                    }
                }

                if showKeyboardHelp {
                    Text("If macOS shows no prompt, its keyboard event permission may need a reset. See README for the command.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("YOUR CONTROLLER")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("For example: Give me next slide, previous slide, and blackout buttons", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...5)
                        .focused($promptIsFocused)
                        .padding(14)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                }

                HStack {
                    if let context, MacActionExecutor.isKeynote(context.application) {
                        Button("Next Slide") { onNextSlide() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!permissionStatus.canControl)
                        Text("Sends Right Arrow to Keynote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Open Keynote to try the local Next Slide action")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                pairingSection

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Text("Controller generation follows device pairing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("esc to close")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(24)
        }
        .frame(width: 700, height: 650)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .onAppear { promptIsFocused = true }
        .task {
            while !Task.isCancelled {
                permissionStatus = MacActionExecutor.permissionStatus
                if permissionStatus.canControl { showKeyboardHelp = false }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IPHONE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            switch pairingHost.state {
            case .idle:
                HStack {
                    Label("No iPhone paired", systemImage: "iphone")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Pair iPhone") {
                        onStartPairing()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(14)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

            case .starting:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Starting a secure local pairing session…")
                    Spacer()
                    Button("Cancel") { pairingHost.stopSession() }
                }
                .padding(14)

            case .waiting, .authenticating:
                HStack(alignment: .top, spacing: 20) {
                    if let payload = pairingHost.descriptor?.qrPayload {
                        PairingQRCodeView(payload: payload)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        if case .authenticating(let deviceName) = pairingHost.state {
                            Label("Authenticating \(deviceName)…", systemImage: "lock.shield")
                                .font(.headline)
                        } else {
                            Text("Scan with Universal Controller")
                                .font(.headline)
                            Text("Open the iPhone app, tap Scan Mac QR, and point it at this code.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let expiresAt = pairingHost.descriptor?.expiresAt {
                            Text("Expires \(expiresAt, style: .relative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Cancel pairing") { pairingHost.stopSession() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .connected(let deviceName):
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected to \(deviceName)")
                            .font(.headline)
                        Text(pairingHost.lastPingAt == nil
                            ? "Waiting for connection test…"
                            : "Bidirectional connection verified")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if pairingHost.controller != nil {
                            Text("Next Slide is ready on your iPhone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Pair from Keynote to send the demo button")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Disconnect") { pairingHost.stopSession() }
                }
                .padding(14)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

            case .failed(let message):
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.subheadline)
                    Spacer()
                    Button("New QR") { onStartPairing() }
                }
                .padding(14)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
