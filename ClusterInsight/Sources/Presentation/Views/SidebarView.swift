import SwiftUI

// Cluster color palette shared across all views.
enum ClusterColors {
    static let palette: [Color] = [
        .blue, .red, .green, .orange, .purple,
        .pink, .teal, .indigo, .mint, .brown,
        .cyan, .yellow, .gray, .primary, .secondary,
        .blue.opacity(0.6), .red.opacity(0.6), .green.opacity(0.6),
        .orange.opacity(0.6), .purple.opacity(0.6)
    ]

    static func color(for label: Int) -> Color {
        if label < 0 { return .gray.opacity(0.3) }
        return palette[label % palette.count]
    }
}
