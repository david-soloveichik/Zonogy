/// Displays the filtered window list with selection support and app header

import SwiftUI

struct WindowItemListView: View {
    let windows: [LauncherWindowItem]
    @Binding var selectedWindowId: UUID?
    let onOpenSelected: () -> Void
    let onOpenApp: () -> Void
    let appName: String
    let appIcon: NSImage?
    @State private var hoveredWindowId: UUID?
    @State private var isHeaderHovered: Bool = false

    private let headerID = "appHeader"

    private var isHeaderSelected: Bool {
        selectedWindowId == nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    AppHeaderRowView(
                        appName: appName,
                        appIcon: appIcon,
                        isSelected: isHeaderSelected,
                        isHovered: isHeaderHovered
                    )
                    .overlay(
                        MouseClickCaptureView(
                            onClick: {
                                selectedWindowId = nil
                                onOpenApp()
                            },
                            onHover: { hovering in
                                isHeaderHovered = hovering
                            }
                        )
                    )
                    .id(headerID)

                    ForEach(windows) { window in
                        WindowItemRowView(
                            window: window,
                            isSelected: window.id == selectedWindowId,
                            isHovered: window.id == hoveredWindowId
                        )
                        .overlay(
                            MouseClickCaptureView(
                                onClick: {
                                    selectedWindowId = window.id
                                    onOpenSelected()
                                },
                                onHover: { hovering in
                                    if hovering {
                                        hoveredWindowId = window.id
                                    } else if hoveredWindowId == window.id {
                                        hoveredWindowId = nil
                                    }
                                }
                            )
                        )
                        .id(window.id)
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
            .onChange(of: selectedWindowId) { newValue in
                withAnimation(.easeOut(duration: 0.12)) {
                    if let windowId = newValue {
                        proxy.scrollTo(windowId, anchor: .center)
                    } else {
                        proxy.scrollTo(headerID, anchor: .center)
                    }
                }
            }
        }
    }
}
