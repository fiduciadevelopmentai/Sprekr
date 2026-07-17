import AppKit
import SwiftUI

enum SprekrPalette {
    /// Monochrome action color: ink in Light mode, warm white in Dark mode.
    static let accent = dynamic(
        light: .init(red: 0.105, green: 0.115, blue: 0.110, alpha: 1),
        dark: .init(red: 0.940, green: 0.940, blue: 0.910, alpha: 1)
    )
    /// Content drawn on top of the accent color.
    static let onAccent = dynamic(
        light: .init(red: 0.965, green: 0.960, blue: 0.940, alpha: 1),
        dark: .init(red: 0.095, green: 0.105, blue: 0.100, alpha: 1)
    )
    /// High-contrast monochrome icon color in both appearances.
    static let icon = accent
    static let canvas = dynamic(light: .init(red: 0.965, green: 0.953, blue: 0.925, alpha: 1), dark: .init(red: 0.105, green: 0.12, blue: 0.11, alpha: 1))
    static let surface = dynamic(light: .init(red: 0.992, green: 0.984, blue: 0.963, alpha: 1), dark: .init(red: 0.145, green: 0.16, blue: 0.15, alpha: 1))
    static let primaryText = dynamic(light: .init(red: 0.13, green: 0.15, blue: 0.14, alpha: 1), dark: .init(red: 0.94, green: 0.94, blue: 0.91, alpha: 1))
    static let secondaryText = dynamic(light: .init(red: 0.34, green: 0.38, blue: 0.35, alpha: 1), dark: .init(red: 0.70, green: 0.72, blue: 0.69, alpha: 1))
    static let line = dynamic(light: .init(red: 0.85, green: 0.84, blue: 0.80, alpha: 0.8), dark: .init(red: 0.30, green: 0.32, blue: 0.29, alpha: 0.9))
    static let navigationSurface = dynamic(
        // Keep the titlebar and sidebar visibly separate from the canvas without
        // falling back to sterile white or crushed black. Both neutrals carry a
        // minute eucalyptus tint so the shell still belongs to the brand.
        light: .init(red: 0.952, green: 0.955, blue: 0.949, alpha: 0.97),
        dark: .init(red: 0.090, green: 0.098, blue: 0.094, alpha: 0.97)
    )

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

enum SprekrTypography {
    static let bodyFamily = "Onest"
    static let bodyRegularPostScriptName = "Onest-Regular"
    static let bodyMediumPostScriptName = "Onest-Medium"
    static let bodyBoldPostScriptName = "Onest-Bold"
    static let headingFamily = "Crimson Text"

    static func body(
        _ size: CGFloat = 16,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> Font {
        let postScriptName: String
        if weight == .bold || weight == .heavy || weight == .black {
            postScriptName = bodyBoldPostScriptName
        } else if weight == .medium || weight == .semibold {
            postScriptName = bodyMediumPostScriptName
        } else {
            postScriptName = bodyRegularPostScriptName
        }
        return .custom(postScriptName, size: size, relativeTo: textStyle)
    }

    static func heading(
        _ size: CGFloat,
        relativeTo textStyle: Font.TextStyle = .title
    ) -> Font {
        .custom(headingFamily, size: size, relativeTo: textStyle)
            .weight(.regular)
    }
}

struct SprekrSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SprekrPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(SprekrPalette.line, lineWidth: 1))
    }
}

extension View {
    func sprekrSurface() -> some View { modifier(SprekrSurface()) }

    func sprekrHeading(_ size: CGFloat = 40) -> some View {
        font(SprekrTypography.heading(size))
            .tracking(-size * 0.025)
            .lineSpacing(size * 0.06)
            .foregroundStyle(SprekrPalette.primaryText)
    }

    func sprekrBody() -> some View {
        font(SprekrTypography.body())
            .lineSpacing(7)
            .foregroundStyle(SprekrPalette.secondaryText)
    }

    func sprekrSmall(
        _ size: CGFloat = 14,
        weight: Font.Weight = .regular,
        color: Color = SprekrPalette.secondaryText
    ) -> some View {
        font(SprekrTypography.body(size, weight: weight, relativeTo: .callout))
            .lineSpacing(size * 0.45)
            .foregroundStyle(color)
    }

    func sprekrLabel() -> some View {
        font(SprekrTypography.body(12, weight: .semibold, relativeTo: .caption))
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundStyle(SprekrPalette.secondaryText)
    }
}

struct SprekrPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SprekrPrimaryButtonBody(configuration: configuration)
    }
}

private struct SprekrPrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(SprekrTypography.body(14, weight: .semibold))
            .foregroundStyle(isEnabled ? SprekrPalette.onAccent : SprekrPalette.secondaryText.opacity(0.72))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                Capsule()
                    .fill(isEnabled ? SprekrPalette.accent : SprekrPalette.accent.opacity(0.22))
                    .overlay {
                        Capsule().fill(
                            SprekrPalette.onAccent.opacity(isEnabled
                                ? configuration.isPressed ? 0.16 : isHovered ? 0.10 : 0
                                : 0)
                        )
                    }
            }
            .contentShape(Capsule())
            .scaleEffect(isEnabled && configuration.isPressed ? 0.98 : 1)
            .onHover { isHovered = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
    }
}

/// Shared tactile feedback for quiet buttons and list rows. Using the dynamic
/// primary-text color makes the surface darken in Light mode and lift slightly
/// in Dark mode, preserving perceptual contrast in both appearances.
struct SprekrHoverButtonStyle: ButtonStyle {
    var baseFill: Color = .clear
    var cornerRadius: CGFloat = 10
    var hoverOpacity: Double = 0.065
    var pressedOpacity: Double = 0.11
    var pressedScale: CGFloat = 0.985

    func makeBody(configuration: Configuration) -> some View {
        SprekrHoverButtonBody(
            configuration: configuration,
            baseFill: baseFill,
            cornerRadius: cornerRadius,
            hoverOpacity: hoverOpacity,
            pressedOpacity: pressedOpacity,
            pressedScale: pressedScale
        )
    }
}

private struct SprekrHoverButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let baseFill: Color
    let cornerRadius: CGFloat
    let hoverOpacity: Double
    let pressedOpacity: Double
    let pressedScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .background {
                shape
                    .fill(baseFill)
                    .overlay {
                        shape.fill(SprekrPalette.primaryText.opacity(
                            configuration.isPressed ? pressedOpacity : isHovered ? hoverOpacity : 0
                        ))
                    }
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SprekrTypography.body(14, weight: .medium))
            .foregroundStyle(Color(red: 0.94, green: 0.94, blue: 0.91))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color(red: 0.12, green: 0.14, blue: 0.13)))
            .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 1))
            .accessibilityAddTraits(.isStaticText)
    }
}
