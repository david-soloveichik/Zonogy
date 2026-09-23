/// Displays the filtered item list with selection support

import Foundation
import SwiftUI

struct LaunchItemListView: View {
    let items: [LaunchItem]
    @Binding var selectedItemURL: URL?
    let onOpenSelected: () -> Void
    var windowCountsByBundleIdentifier: [String: Int] = [:]
    var runningBundleIdentifiers: Set<String> = []
    var appsWithDefaultWindowInZoneBundleIdentifiers: Set<String> = []
    /// When true, application rows replace their `[count >]` chevron with a non-interactive
    /// "+" badge; clicking such a row opens a new window of the app instead of the default action.
    var isOptionHeld: Bool = false
    var onExpandApp: ((URL) -> Void)?
    let onBeginDrag: (LauncherDragPayload) -> Void
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
                        let isAppRow = item.kind == .application
                        let showsNewWindowAffordance = isOptionHeld && isAppRow
                        LaunchItemRowView(
                            item: item,
                            isSelected: item.url == selectedItemURL,
                            isRunning: isRunning,
                            hasDefaultWindowInZone: hasDefaultWindowInZone
                        )
                        .overlay(
                            RowInteractionCaptureView(
                                onClick: {
                                    skipNextScrollToSelected = true
                                    selectedItemURL = item.url
                                    onOpenSelected()
                                },
                                onMouseMove: {
                                    guard selectedItemURL != item.url else { return }
                                    skipNextScrollToSelected = true
                                    selectedItemURL = item.url
                                },
                                onDragStart: {
                                    skipNextScrollToSelected = true
                                    selectedItemURL = item.url
                                    switch item.kind {
                                    case .application:
                                        onBeginDrag(.application(item))
                                    case .directory, .file:
                                        onBeginDrag(.launchableItem(item))
                                    }
                                },
                                // In Option mode, the chevron is replaced by a non-interactive
                                // badge — the whole row is clickable, including the trailing region.
                                dragExclusionTrailingWidth: (isRunning && !showsNewWindowAffordance) ? 30 : 0
                            )
                        )
                        .overlay(alignment: .trailing) {
                            if showsNewWindowAffordance {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.green)
                                    .padding(.trailing, 10)
                                    .allowsHitTesting(false)
                                    .accessibilityLabel("New window")
                            } else if isRunning {
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
                                    }
                                    .buttonStyle(ChevronButtonStyle(isHovered: chevronHoveredURL == item.url))
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
                .background(OverlayScrollBars())
            }
            .scrollIndicators(.never)  // OverlayScrollBars supplies the scroll bar
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .onChange(of: selectedItemURL) { _, newValue in
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
