/// Displays the filtered window list with selection support and app header

import SwiftUI

struct WindowItemListView: View {
    let windows: [LauncherWindowItem]
    @Binding var selectedWindowId: UUID?
    let onOpenSelected: () -> Void
    let onOpenApp: () -> Void
    let appName: String
    let appIcon: NSImage?
    @State private var selectionChangeWasMouseDriven: Bool = false

    private let headerID = "appHeader"

    private var isHeaderSelected: Bool {
        selectedWindowId == nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    AppHeaderRowView(appName: appName, appIcon: appIcon, isSelected: isHeaderSelected)
                        .overlay(
                            MouseDownCaptureView { clickCount in
                                selectionChangeWasMouseDriven = (selectedWindowId != nil)
                                selectedWindowId = nil
                                if clickCount >= 2 {
                                    onOpenApp()
                                }
                            }
                        )
                        .id(headerID)

                    ForEach(windows) { window in
                        WindowItemRowView(window: window, isSelected: window.id == selectedWindowId)
                            .overlay(
                                MouseDownCaptureView { clickCount in
                                    selectionChangeWasMouseDriven = (selectedWindowId != window.id)
                                    selectedWindowId = window.id
                                    if clickCount >= 2 {
                                        onOpenSelected()
                                    }
                                }
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
                guard !selectionChangeWasMouseDriven else {
                    selectionChangeWasMouseDriven = false
                    return
                }
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
