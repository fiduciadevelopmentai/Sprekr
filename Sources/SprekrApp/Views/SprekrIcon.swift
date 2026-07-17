import SwiftUI

/// A deliberately small subset of Lucide's consistent 24 pt outline set.
/// The bundled font contains only these glyphs, not the complete icon library.
enum SprekrIcon: UInt32 {
    case audioWaveform = 0xE55B
    case layoutGrid = 0xE0FF
    case chartColumns = 0xE06A
    case notebookTabs = 0xE597
    case slidersHorizontal = 0xE29A
    case panelLeftClose = 0xE21C
    case panelLeftOpen = 0xE21D
    case circleStop = 0xE083
}

struct SprekrIconView: View {
    let icon: SprekrIcon
    var size: CGFloat = 20

    var body: some View {
        Text(String(UnicodeScalar(icon.rawValue)!))
            .font(.custom("lucide", fixedSize: size))
            .foregroundStyle(SprekrPalette.icon)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension AppSection {
    var icon: SprekrIcon {
        switch self {
        case .home: .layoutGrid
        case .insights: .chartColumns
        case .dictionary: .notebookTabs
        case .settings: .slidersHorizontal
        }
    }
}
