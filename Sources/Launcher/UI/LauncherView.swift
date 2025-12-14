/// Main SwiftUI UI for the launcher - searching, selecting, and launching items

import AppKit
import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let onDismiss: () -> Void
    let onLaunchApp: (URL) -> Void
    let onSelectWindow: (LauncherWindowItem) -> Void
    let onActivateApp: (String) -> Void

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(searchPlaceholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))
                    .focused($isSearchFocused)
                    .frame(maxWidth: .infinity)

                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )

            // Content based on mode
            Group {
                switch model.mode {
                case .appList:
                    if model.filteredItems.isEmpty {
                        EmptyStateView(title: "No matches", systemImageName: "magnifyingglass")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        LaunchItemListView(
                            items: model.filteredItems,
                            selectedItemURL: $model.selectedItemURL,
                            onOpenSelected: handleAppLaunch,
                            windowCountForSelected: model.cachedWindowCount,
                            runningAppURLs: model.runningAppURLs
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .windowList(_, let appName):
                    WindowItemListView(
                        windows: model.filteredWindowItems,
                        selectedWindowId: $model.selectedWindowId,
                        onOpenSelected: handleWindowSelection,
                        onOpenApp: handleAppActivation,
                        appName: appName,
                        appIcon: model.windowModeAppIcon
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
    }

    private var searchPlaceholder: String {
        switch model.mode {
        case .appList:
            return "Search..."
        case .windowList(_, let appName):
            return "Search \(appName) windows..."
        }
    }

    private func handleAppLaunch() {
        if let url = model.recordAndGetSelectedItem() {
            onLaunchApp(url)
        }
    }

    private func handleWindowSelection() {
        if let window = model.selectedWindowItem() {
            onSelectWindow(window)
        }
    }

    private func handleAppActivation() {
        if let bundleId = model.windowModeBundleIdentifier() {
            onActivateApp(bundleId)
        }
    }
}
