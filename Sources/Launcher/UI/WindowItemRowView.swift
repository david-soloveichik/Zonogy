/// Renders a single window row (icon + title) including selected state styling

import SwiftUI

struct WindowItemRowView: View {
    let window: LauncherWindowItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Window icon glyph (visible when window is placed in a zone)
            WindowIndicatorGlyphView(isVisible: window.isInZone)

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
