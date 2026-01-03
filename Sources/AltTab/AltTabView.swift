/// SwiftUI view for the AltTab window switcher - displays a clickable window list without search

import AppKit
import SwiftUI

struct AltTabView: View {
    @ObservedObject var model: AltTabModel
    let onActivateSelected: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Header
            Text("Switch Windows")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            // Window list
            if model.windows.isEmpty {
                EmptyStateView(title: "No windows", systemImageName: "macwindow")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                                AltTabRowView(
                                    window: window,
                                    isSelected: index == model.selectedIndex
                                )
                                .overlay(
                                    MouseClickCaptureView(
                                        onClick: {
                                            model.selectedIndex = index
                                            onActivateSelected()
                                        },
                                        onMouseMove: {
                                            guard model.selectedIndex != index else { return }
                                            model.selectedIndex = index
                                        }
                                    )
                                )
                                .id(index)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: model.selectedIndex) { newIndex in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Row view for a single window in AltTab
struct AltTabRowView: View {
    let window: LauncherWindowItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // App icon
            if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }

            // Window title
            Text(window.title)
                .font(.system(size: 14, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                    )
            }
        }
    }
}
