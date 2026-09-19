import SwiftUI
import UIKit

struct ControllerRendererView: View {
    let document: ControllerDocument
    let onTrigger: (ControlDefinition) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(document.name)
                .font(.headline)

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(rows) { row in
                    GridRow {
                        ForEach(row.items) { item in
                            if let control = document.control(id: item.controlID) {
                                controlView(control)
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: CGFloat(item.rowSpan) * 72
                                    )
                                    .gridCellColumns(item.columnSpan)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var rows: [ControllerLayoutRow] {
        var groupedItems: [[ControllerLayoutItem]] = []
        var currentItems: [ControllerLayoutItem] = []
        var occupiedColumns = 0

        for item in document.layout.items {
            if occupiedColumns + item.columnSpan > document.layout.columns {
                groupedItems.append(currentItems)
                currentItems = []
                occupiedColumns = 0
            }

            currentItems.append(item)
            occupiedColumns += item.columnSpan

            if occupiedColumns == document.layout.columns {
                groupedItems.append(currentItems)
                currentItems = []
                occupiedColumns = 0
            }
        }

        if !currentItems.isEmpty {
            groupedItems.append(currentItems)
        }
        return groupedItems.enumerated().map {
            ControllerLayoutRow(id: $0.offset, items: $0.element)
        }
    }

    @ViewBuilder
    private func controlView(_ control: ControlDefinition) -> some View {
        switch control.kind {
        case .button(let configuration):
            ButtonControlView(
                control: control,
                configuration: configuration,
                onTrigger: { onTrigger(control) }
            )
        }
    }
}

private struct ControllerLayoutRow: Identifiable {
    let id: Int
    let items: [ControllerLayoutItem]
}

private struct ButtonControlView: View {
    let control: ControlDefinition
    let configuration: ButtonControlConfiguration
    let onTrigger: () -> Void

    var body: some View {
        Group {
            switch configuration.variant {
            case .primary:
                button
                    .buttonStyle(.borderedProminent)
            case .secondary:
                button
                    .buttonStyle(.bordered)
            case .destructive:
                button
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
    }

    private var button: some View {
        Button {
            if configuration.hapticsEnabled {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            onTrigger()
        } label: {
            Text(control.label)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 16)
        }
    }
}
