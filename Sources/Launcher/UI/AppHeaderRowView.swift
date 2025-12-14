/// Renders the app header row in window list mode with distinct styling

import SwiftUI

struct AppHeaderRowView: View {
    let appName: String
    let appIcon: NSImage?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .cornerRadius(5)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 24, height: 24)
                }

                Text(appName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
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

            Divider()
                .padding(.horizontal, 8)
                .padding(.top, 4)
        }
    }
}
