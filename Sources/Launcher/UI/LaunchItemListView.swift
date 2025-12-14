/// Displays the filtered item list with selection support

import SwiftUI

struct LaunchItemListView: View {
    let items: [LaunchItem]
    @Binding var selectedItemURL: URL?
    let onOpenSelected: () -> Void
    var windowCountForSelected: Int?
    var runningAppURLs: Set<URL> = []
    @State private var selectionChangeWasMouseDriven: Bool = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        LaunchItemRowView(
                            item: item,
                            isSelected: item.url == selectedItemURL,
                            windowCount: item.url == selectedItemURL ? windowCountForSelected : nil,
                            isRunning: runningAppURLs.contains(item.url)
                        )
                            .overlay(
                                MouseDownCaptureView { clickCount in
                                    selectionChangeWasMouseDriven = (selectedItemURL != item.url)
                                    selectedItemURL = item.url
                                    if clickCount >= 2 {
                                        onOpenSelected()
                                    }
                                }
                            )
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
                guard !selectionChangeWasMouseDriven else {
                    selectionChangeWasMouseDriven = false
                    return
                }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}
