/// SwiftUI view for DockMenu content (app header + window list).

import SwiftUI

/// View model for DockMenuView.
final class DockMenuViewModel: ObservableObject {
    @Published var appName: String = ""
    @Published var appIcon: NSImage?
    @Published var windows: [LauncherWindowItem] = []
    @Published var hoveredWindowId: UUID?
    @Published var isHoveringHeader: Bool = false

    var onWindowSelected: ((LauncherWindowItem) -> Void)?
    var onAppHeaderSelected: (() -> Void)?
    var onWindowDragStart: ((LauncherWindowItem) -> Void)?
}

struct DockMenuView: View {
    @ObservedObject var viewModel: DockMenuViewModel

    var body: some View {
        VStack(spacing: 0) {
            DockMenuAppHeaderView(
                appName: viewModel.appName,
                appIcon: viewModel.appIcon,
                isHovered: viewModel.isHoveringHeader,
                onHover: { hovering in
                    viewModel.isHoveringHeader = hovering
                },
                onTap: {
                    viewModel.onAppHeaderSelected?()
                }
            )

            if !viewModel.windows.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(viewModel.windows) { window in
                            DockMenuWindowRowView(
                                window: window,
                                isHovered: viewModel.hoveredWindowId == window.id
                            )
                            .overlay(
                                RowInteractionCaptureView(
                                    onClick: {
                                        viewModel.hoveredWindowId = window.id
                                        viewModel.onWindowSelected?(window)
                                    },
                                    onHover: { hovering in
                                        viewModel.hoveredWindowId = hovering ? window.id : nil
                                    },
                                    onMouseMove: {
                                        guard viewModel.hoveredWindowId != window.id else { return }
                                        viewModel.hoveredWindowId = window.id
                                    },
                                    onDragStart: {
                                        viewModel.hoveredWindowId = window.id
                                        viewModel.onWindowDragStart?(window)
                                    }
                                )
                            )
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.top, 6)
        .frame(width: 300)
    }
}

/// App header row for DockMenu.
struct DockMenuAppHeaderView: View {
    let appName: String
    let appIcon: NSImage?
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .cornerRadius(4)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 22, height: 22)
                }

                Text(appName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Text("Menu Bar")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                        )
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                onHover(hovering)
            }
            .onTapGesture {
                onTap()
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.top, 2)
        }
    }
}

/// Window row for DockMenu with hover styling; interaction is provided by the overlay capture view.
struct DockMenuWindowRowView: View {
    let window: LauncherWindowItem
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 8) {
            if window.isPlacedInZone {
                Image(systemName: "macwindow")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            } else {
                Color.clear
                    .frame(width: 20, height: 20)
            }

            Text(window.title)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                    )
            }
        }
    }
}
