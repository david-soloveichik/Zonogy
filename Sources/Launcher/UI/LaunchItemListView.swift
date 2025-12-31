/// Displays the filtered item list with selection support

import SwiftUI

/// Button style that scales down when pressed for visual feedback
private struct ChevronPressStyle: ButtonStyle {
    var isHovered: Bool

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .scaleEffect(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct LaunchItemListView: View {
    let items: [LaunchItem]
    @Binding var selectedItemURL: URL?
    let onOpenSelected: () -> Void
    var windowCountForSelected: Int?
    var runningAppURLs: Set<URL> = []
    var onExpandApp: ((URL) -> Void)?
    @State private var hoveredItemURL: URL?
    @State private var chevronHoveredURL: URL?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        let isRunning = runningAppURLs.contains(item.url)
                        LaunchItemRowView(
                            item: item,
                            isSelected: item.url == selectedItemURL,
                            windowCount: item.url == selectedItemURL ? windowCountForSelected : nil,
                            isRunning: isRunning,
                            isHovered: item.url == hoveredItemURL
                        )
                        .overlay(
                            MouseClickCaptureView(
                                onClick: {
                                    selectedItemURL = item.url
                                    onOpenSelected()
                                },
                                onHover: { hovering in
                                    if hovering {
                                        hoveredItemURL = item.url
                                    } else if hoveredItemURL == item.url {
                                        hoveredItemURL = nil
                                    }
                                }
                            )
                        )
                        .overlay(alignment: .trailing) {
                            if isRunning {
                                Button {
                                    selectedItemURL = item.url
                                    onExpandApp?(item.url)
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(ChevronPressStyle(isHovered: chevronHoveredURL == item.url))
                                .padding(.trailing, 6)
                                .onHover { hovering in
                                    if hovering {
                                        chevronHoveredURL = item.url
                                    } else if chevronHoveredURL == item.url {
                                        chevronHoveredURL = nil
                                    }
                                }
                            }
                        }
                        .id(item.url)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
            .background(ScrollViewScrollerStyler())
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .onChange(of: selectedItemURL) { newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}
