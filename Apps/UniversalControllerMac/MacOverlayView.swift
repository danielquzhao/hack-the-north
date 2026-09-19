import AppKit
import SwiftUI

struct MacOverlayView: View {
    let context: AppContext?
    let onClose: () -> Void

    @State private var prompt = ""
    @FocusState private var promptIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
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
        .padding(28)
        .frame(width: 680, height: 430)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .onAppear { promptIsFocused = true }
    }
}
