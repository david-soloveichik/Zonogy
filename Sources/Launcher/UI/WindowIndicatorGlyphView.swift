/// Renders the Launcher "window is placed in zone" glyph with optional reserved space.

import SwiftUI

struct WindowIndicatorGlyphView: View {
    let isVisible: Bool
    var reserveSpaceWhenHidden: Bool = true

    var body: some View {
        if isVisible {
            Image(systemName: "macwindow")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        } else if reserveSpaceWhenHidden {
            Color.clear
                .frame(width: 22, height: 22)
        }
    }
}
