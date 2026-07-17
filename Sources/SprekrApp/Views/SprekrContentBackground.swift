import SwiftUI

/// A calm, solid field behind every main section.
/// `SprekrPalette.canvas` is warm ivory in Light mode and deep green-charcoal
/// in Dark mode, keeping both appearances cohesive with the navigation shell.
struct SprekrContentBackground: View {
    var body: some View {
        SprekrPalette.canvas
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
