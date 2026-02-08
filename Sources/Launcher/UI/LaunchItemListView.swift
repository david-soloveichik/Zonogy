/// Displays the filtered item list with selection support

import Foundation
import SwiftUI

/// Button style that scales down when pressed for visual feedback
private struct ChevronPressStyle: ButtonStyle {
    var isHovered: Bool

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background {
                Circle()
                    .fill(Color.primary.opacity(isHovered ? 0.12 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isHovered)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct LaunchItemListView: View {
    let items: [LaunchItem]
    @Binding var selectedItemURL: URL?
    let onOpenSelected: () -> Void
    var windowCountsByBundleIdentifier: [String: Int] = [:]
    var runningBundleIdentifiers: Set<String> = []
    var appsWithDefaultWindowInZoneBundleIdentifiers: Set<String> = []
    var onExpandApp: ((URL) -> Void)?
    @State private var chevronHoveredURL: URL?
    @State private var skipNextScrollToSelected = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        let bundleId = ApplicationIdentity.bundleIdentifier(forApplicationURL: item.url)
                        let isRunning = bundleId.map { runningBundleIdentifiers.contains($0) } ?? false
                        let hasDefaultWindowInZone = bundleId.map { appsWithDefaultWindowInZoneBundleIdentifiers.contains($0) } ?? false
                        LaunchItemRowView(
                            item: item,
                            isSelected: item.url == selectedItemURL,
                            isRunning: isRunning,
                            hasDefaultWindowInZone: hasDefaultWindowInZone
                        )
                        .overlay(
                            MouseClickCaptureView(
                                onClick: {
                                    skipNextScrollToSelected = true
                                    selectedItemURL = item.url
                                    onOpenSelected()
                                },
                                onMouseMove: {
                                    guard selectedItemURL != item.url else { return }
                                    skipNextScrollToSelected = true
                                    selectedItemURL = item.url
                                }
                            )
                        )
                        .overlay(alignment: .trailing) {
                            if isRunning {
                                HStack(spacing: 2) {
                                    if let bundleId,
                                       let count = windowCountsByBundleIdentifier[bundleId],
                                       count > 0 {
                                        Text("\(count)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
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
                                }
                                .padding(.trailing, 6)
                                .onHover { hovering in
                                    if hovering {
                                        chevronHoveredURL = item.url
                                        if selectedItemURL != item.url {
                                            skipNextScrollToSelected = true
                                            selectedItemURL = item.url
                                        }
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
                if skipNextScrollToSelected {
                    skipNextScrollToSelected = false
                    return
                }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: nil)
                }
            }
        }
    }
}
