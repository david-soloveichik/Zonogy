/// Renders a single item row (icon + name) including selected state styling

import AppKit
import SwiftUI

struct LaunchItemRowView: View {
    let item: LaunchItem
    let isSelected: Bool
    var isRunning: Bool = false
    var hasDefaultWindowInZone: Bool = false
    var onChevronTap: (() -> Void)?

    @State private var loadedIcon: NSImage?

    private var displayIcon: NSImage? {
        loadedIcon ?? item.icon
    }

    var body: some View {
        HStack(spacing: 8) {
            // Running indicator dot
            Circle()
                .fill(Color.secondary)
                .frame(width: 4, height: 4)
                .opacity(isRunning ? 1 : 0)

            if let icon = displayIcon {
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

            Text(item.displayName)
                .font(.system(size: 14, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            if hasDefaultWindowInZone {
                WindowIndicatorGlyphView(isVisible: true)
            }

            Spacer(minLength: 0)

            if isRunning, let onChevronTap {
                Button {
                    onChevronTap()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
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
        .onAppear {
            if loadedIcon == nil && item.icon == nil {
                loadedIcon = LauncherAppCache.shared.icon(for: item.url)
            }
        }
    }
}
