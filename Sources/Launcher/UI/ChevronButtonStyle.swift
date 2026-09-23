/// Button style for the Launcher's drill-down and back chevrons: hit area, hover highlight, press feedback

import SwiftUI

struct ChevronButtonStyle: ButtonStyle {
    var isHovered: Bool

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
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
