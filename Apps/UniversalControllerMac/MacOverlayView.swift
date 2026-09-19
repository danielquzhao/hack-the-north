import AppKit
import SwiftUI

struct MacOverlayView: View {
    let context: AppContext?
    let errorMessage: String?
    let onClose: () -> Void
    let onRequestPermission: () -> Void
    let onNextSlide: () -> Void

    @State private var prompt = ""
    @State private var permissionStatus = MacActionExecutor.permissionStatus
    @FocusState private var promptIsFocused: Bool

    var body: some View {
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
                    : permissionStatus.accessibility ? "Keyboard control access required" : "Accessibility access required")
                    .font(.subheadline)
                Spacer()
                if !permissionStatus.canControl {
                    Button(permissionStatus.accessibility ? "Allow Keyboard Control" : "Grant Accessibility") {
                        onRequestPermission()
                        permissionStatus = MacActionExecutor.permissionStatus
                    }
                }
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
                if context?.application.bundleIdentifier == "com.apple.iWork.Keynote" {
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

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Text("Controller generation is the next build step")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("esc to close")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .frame(width: 680, height: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .onAppear { promptIsFocused = true }
        .task {
            while !Task.isCancelled {
                permissionStatus = MacActionExecutor.permissionStatus
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
