import SwiftUI
import VisionKit

struct ContentView: View {
    @StateObject private var pairingClient = PairingClient()
    @State private var showingScanner = false
    @State private var scanError: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.indigo.opacity(0.22), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if case .connected(let macName) = pairingClient.state {
                controllerSession(macName: macName)
            } else {
                pairingScreen
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showingScanner) {
            scanner
        }
        .alert(
            "Couldn’t scan QR code",
            isPresented: Binding(
                get: { scanError != nil },
                set: { if !$0 { scanError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scanError ?? "")
        }
    }

    private var pairingScreen: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: stateIcon)
                .font(.system(size: 58, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)

            VStack(spacing: 8) {
                Text(stateTitle)
                    .font(.largeTitle.bold())
                Text(stateMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            stateActions
                .frame(maxWidth: 340)

            Spacer()

            Text("Mac and iPhone communicate directly on your local network.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
    }

    private func controllerSession(macName: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(pairingClient.controller?.name ?? "Connected to \(macName)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    pairingClient.disconnect()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Disconnect from \(macName)")
            }
            .frame(height: 44)

            if let controller = pairingClient.controller {
                ControllerRendererView(
                    document: controller,
                    onEvent: pairingClient.sendEvent
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for a controller from the Mac")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var stateIcon: String {
        switch pairingClient.state {
        case .disconnected:
            "iphone.gen3.radiowaves.left.and.right"
        case .discovering, .connecting:
            "dot.radiowaves.left.and.right"
        case .authenticating:
            "lock.shield"
        case .connected:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var stateTitle: String {
        switch pairingClient.state {
        case .disconnected:
            "Universal Controller"
        case .discovering:
            "Finding your Mac"
        case .connecting:
            "Connecting"
        case .authenticating:
            "Pairing securely"
        case .connected:
            "Connected"
        case .failed:
            "Connection failed"
        }
    }

    private var stateMessage: String {
        switch pairingClient.state {
        case .disconnected:
            "Scan the QR code shown by the Universal Controller overlay on your Mac."
        case .discovering(let macName):
            "Looking for \(macName) on the local network…"
        case .connecting(let macName):
            "Opening a connection to \(macName)…"
        case .authenticating(let macName):
            "Confirming this phone scanned the QR from \(macName)…"
        case .connected(let macName):
            if let roundTripMilliseconds = pairingClient.roundTripMilliseconds {
                "Paired with \(macName). Round-trip test: \(roundTripMilliseconds) ms."
            } else {
                "Paired with \(macName). Testing the connection…"
            }
        case .failed(let message):
            message
        }
    }

    @ViewBuilder
    private var stateActions: some View {
        switch pairingClient.state {
        case .disconnected:
            Button {
                guard DataScannerViewController.isSupported,
                      DataScannerViewController.isAvailable else {
                    scanError = "QR scanning is unavailable on this device."
                    return
                }
                showingScanner = true
            } label: {
                Label("Scan Mac QR", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .discovering, .connecting, .authenticating:
            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                Button("Cancel", role: .cancel) {
                    pairingClient.disconnect()
                }
            }

        case .connected:
            EmptyView()

        case .failed:
            VStack(spacing: 12) {
                Button("Try Again") {
                    pairingClient.retry()
                }
                .buttonStyle(.borderedProminent)
                Button("Scan a New QR") {
                    pairingClient.disconnect()
                    showingScanner = true
                }
            }
        }
    }

    private var scanner: some View {
        ZStack(alignment: .topTrailing) {
            QRCodeScannerView(
                onScan: { payload in
                    do {
                        let descriptor = try PairingDescriptor.parse(qrPayload: payload)
                        showingScanner = false
                        pairingClient.connect(using: descriptor)
                    } catch {
                        showingScanner = false
                        scanError = error.localizedDescription
                    }
                },
                onError: { message in
                    showingScanner = false
                    scanError = message
                }
            )
            .ignoresSafeArea()

            Button {
                showingScanner = false
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(14)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel("Close scanner")
        }
    }
}
