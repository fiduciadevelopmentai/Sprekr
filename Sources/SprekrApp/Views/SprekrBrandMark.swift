import AppKit
import SwiftUI

/// The transparent, tightly cropped brand mark supplied with Sprekr.
/// The fallback keeps development/test hosts usable when they are not running
/// from the assembled `.app` bundle.
struct SprekrBrandMarkView: View {
    let width: CGFloat
    let height: CGFloat

    private var bundledImage: NSImage? {
        guard let url = Bundle.main.url(
            forResource: "SprekrMark-transparent",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        Group {
            if let bundledImage {
                Image(nsImage: bundledImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
            } else {
                SprekrIconView(icon: .audioWaveform, size: min(width, height))
                    .foregroundStyle(SprekrPalette.icon)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// Fiducia Development's supplied mark for surfaces owned by Fiducia rather
/// than Sprekr, such as the project information panel.
struct FiduciaBrandMarkView: View {
    let width: CGFloat
    let height: CGFloat

    private var bundledImage: NSImage? {
        guard let url = Bundle.main.url(
            forResource: "FiduciaLogoColored3D",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        Group {
            if let bundledImage {
                Image(nsImage: bundledImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
            } else {
                Image(systemName: "building.2")
                    .font(.system(size: min(width, height) * 0.72, weight: .medium))
                    .foregroundStyle(SprekrPalette.icon)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}
