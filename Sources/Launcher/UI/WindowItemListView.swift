/// Displays the filtered window list with selection support and app header

import SwiftUI

struct WindowItemListView: View {
    let windows: [LauncherWindowItem]
    @Binding var selectedWindowId: UUID?
    let onOpenSelected: () -> Void
    let onOpenApp: () -> Void
    let appName: String
    let appIcon: NSImage?
    let onBeginDrag: (LauncherDragPayload) -> Void
    @State private var skipNextScrollToSelected = false

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
                        isSelected: isHeaderSelected
                    )
                    .overlay(
                        RowInteractionCaptureView(
                            onClick: {
                                skipNextScrollToSelected = true
                                selectedWindowId = nil
                                onOpenApp()
                            },
                            onMouseMove: {
                                guard selectedWindowId != nil else { return }
                                skipNextScrollToSelected = true
                                selectedWindowId = nil
                            }
                        )
                    )
                    .id(headerID)

                    ForEach(windows) { window in
                        WindowItemRowView(
                            window: window,
                            isSelected: window.id == selectedWindowId
                        )
                        .overlay(
                            RowInteractionCaptureView(
                                onClick: {
                                    skipNextScrollToSelected = true
                                    selectedWindowId = window.id
                                    onOpenSelected()
                                },
                                onMouseMove: {
                                    guard selectedWindowId != window.id else { return }
                                    skipNextScrollToSelected = true
                                    selectedWindowId = window.id
                                },
                                onDragStart: {
                                    skipNextScrollToSelected = true
                                    selectedWindowId = window.id
                                    // Window-list rows drag a specific window; no app-URL
                                    // context is attached (Option has no effect for these).
                                    onBeginDrag(.managedWindow(window, appURL: nil))
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
            .onChange(of: selectedWindowId) { _, newValue in
                if skipNextScrollToSelected {
                    skipNextScrollToSelected = false
                    return
                }
                withAnimation(.easeOut(duration: 0.12)) {
                    if let windowId = newValue {
                        proxy.scrollTo(windowId, anchor: nil)
                    } else {
                        proxy.scrollTo(headerID, anchor: nil)
                    }
                }
            }
        }
    }
}
