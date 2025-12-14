/// Lightweight empty state UI when no matches found

import SwiftUI

struct EmptyStateView: View {
    let title: String
    let systemImageName: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImageName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
