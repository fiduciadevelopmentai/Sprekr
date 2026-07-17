import SwiftUI

struct MainShellView: View {
    @ObservedObject var controller: SprekrAppController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The quiet icon rail is the deliberate launch state. Expanding it is a
    // session choice, so every newly opened app window starts compact again.
    @State private var sidebarCollapsed = true

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                SprekrPalette.canvas
                SprekrContentBackground()
                    .opacity(0.20)
                SprekrPalette.navigationSurface
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                SprekrWindowChrome(isCollapsed: $sidebarCollapsed)

                HStack(spacing: 0) {
                    SprekrSidebar(
                        controller: controller,
                        isCollapsed: $sidebarCollapsed
                    )
                    .zIndex(2)

                    ZStack {
                        SprekrContentBackground()

                        detail
                            .id(controller.section)
                            .transition(detailTransition)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(SprekrPalette.line.opacity(0.58), lineWidth: 1)
                    }
                    .clipped()
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                    .animation(detailAnimation, value: controller.section)
                    .zIndex(0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(sidebarAnimation, value: sidebarCollapsed)

            if let toast = controller.toast {
                ToastView(text: toast).padding(.bottom, 22)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.30)
    }

    private var detailAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    private var detailTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 8)),
            removal: .opacity
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch controller.section {
        case .home: HomeView(controller: controller)
        case .insights: InsightsView(controller: controller)
        case .dictionary: DictionaryView(controller: controller)
        case .settings: SettingsView(controller: controller)
        }
    }
}

private struct SprekrWindowChrome: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isCollapsed: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Native traffic lights occupy the first 76 points. Leaving this
            // region empty makes the transparent title bar feel intentional.
            Color.clear
                .frame(width: 76)
                .allowsHitTesting(false)

            Button {
                withAnimation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.30)) {
                    isCollapsed.toggle()
                }
            } label: {
                SprekrIconView(
                    icon: isCollapsed ? .panelLeftOpen : .panelLeftClose,
                    size: 18
                )
                .foregroundStyle(SprekrPalette.secondaryText)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(SprekrChromeButtonStyle())
            .help(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
            .accessibilityLabel(isCollapsed ? "Expand sidebar" : "Collapse sidebar")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 62)
        .contentShape(Rectangle())
    }
}

private struct SprekrChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SprekrChromeButtonBody(configuration: configuration)
    }
}

private struct SprekrChromeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(
                Circle()
                    .fill(SprekrPalette.surface.opacity(configuration.isPressed ? 0.92 : 0.62))
                    .overlay {
                        Circle().fill(SprekrPalette.primaryText.opacity(isHovered ? 0.065 : 0))
                    }
            )
            .overlay {
                Circle()
                    .stroke(
                        isHovered ? SprekrPalette.accent.opacity(0.48) : SprekrPalette.line.opacity(0.52),
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
    }
}

private struct SprekrSidebar: View {
    @ObservedObject var controller: SprekrAppController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isCollapsed: Bool
    @State private var hoveredSection: AppSection?
    @State private var isInfoButtonHovered = false
    @State private var isInfoPresented = false

    private let expandedWidth: CGFloat = 228
    private let collapsedWidth: CGFloat = 72

    init(controller: SprekrAppController, isCollapsed: Binding<Bool>) {
        self.controller = controller
        _isCollapsed = isCollapsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, isCollapsed ? 14 : 18)
                .padding(.top, 18)
                .padding(.bottom, 24)

            VStack(spacing: 6) {
                ForEach(AppSection.allCases) { section in
                    navigationButton(section)
                }
            }
            .padding(.horizontal, isCollapsed ? 10 : 14)

            Spacer(minLength: 20)

            ZStack(alignment: .bottomLeading) {
                Button {
                    withAnimation(infoAnimation) {
                        isInfoPresented.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(SprekrPalette.icon)
                            .frame(width: 20, height: 20)
                        if !isCollapsed {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("About Sprekr")
                                    .lineLimit(1)
                                Text("Fiducia Development")
                                    .font(SprekrTypography.body(11, weight: .medium, relativeTo: .caption))
                                    .foregroundStyle(SprekrPalette.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .font(SprekrTypography.body(14, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(isInfoPresented ? SprekrPalette.accent : SprekrPalette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: isCollapsed ? .center : .leading)
                    .padding(.horizontal, isCollapsed ? 0 : 12)
                }
                .buttonStyle(SprekrHoverButtonStyle(
                    baseFill: isInfoPresented ? SprekrPalette.accent.opacity(0.10) : .clear,
                    cornerRadius: 12,
                    hoverOpacity: 0.065,
                    pressedOpacity: 0.11
                ))
                .onHover { isInfoButtonHovered = $0 }
                .overlay(alignment: .leading) {
                    if isCollapsed && isInfoButtonHovered && !isInfoPresented {
                        SprekrSidebarTooltip(text: "About Sprekr")
                            .offset(x: 62)
                            .transition(sidebarTooltipTransition)
                            .allowsHitTesting(false)
                    }
                }
                .help("About Sprekr")
                .accessibilityLabel("About Sprekr")
                .accessibilityHint("Shows information about Fiducia Development and local privacy")
            }
            .overlay(alignment: .bottomLeading) {
                if isInfoPresented {
                    SprekrProjectInfoCallout {
                        withAnimation(infoAnimation) {
                            isInfoPresented = false
                        }
                    }
                    .offset(x: infoButtonWidth)
                    .transition(infoTransition)
                    .zIndex(5)
                }
            }
            .padding(.horizontal, isCollapsed ? 10 : 14)
            .padding(.bottom, 14)
            .zIndex(isInfoButtonHovered || isInfoPresented ? 4 : 0)
        }
        .frame(width: isCollapsed ? collapsedWidth : expandedWidth)
        .onExitCommand {
            guard isInfoPresented else { return }
            withAnimation(infoAnimation) {
                isInfoPresented = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            SprekrBrandMarkView(
                width: isCollapsed ? 30 : 29,
                height: isCollapsed ? 20 : 19
            )
                .frame(width: 36, height: 36)

            if !isCollapsed {
                Text("Sprekr")
                    .font(SprekrTypography.body(16, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(SprekrPalette.primaryText)
                Spacer(minLength: 4)
            }
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
    }

    private func navigationButton(_ section: AppSection) -> some View {
        let isSelected = controller.section == section
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                isInfoPresented = false
                controller.section = section
            }
        } label: {
            HStack(spacing: 13) {
                SprekrIconView(icon: section.icon, size: 20)
                if !isCollapsed {
                    Text(section.rawValue)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .font(SprekrTypography.body(
                15,
                weight: isSelected ? .semibold : .medium,
                relativeTo: .body
            ))
            .foregroundStyle(isSelected ? SprekrPalette.primaryText : SprekrPalette.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: isCollapsed ? .center : .leading)
            .padding(.horizontal, isCollapsed ? 0 : 13)
        }
        .buttonStyle(SprekrHoverButtonStyle(
            baseFill: isSelected ? SprekrPalette.accent.opacity(0.12) : .clear,
            cornerRadius: 12,
            hoverOpacity: isSelected ? 0.055 : 0.072,
            pressedOpacity: 0.12
        ))
        .onHover { isHovered in
            hoveredSection = isHovered ? section : (hoveredSection == section ? nil : hoveredSection)
        }
        .overlay(alignment: .leading) {
            if isCollapsed && hoveredSection == section {
                SprekrSidebarTooltip(text: section.rawValue)
                    .offset(x: 62)
                    .transition(sidebarTooltipTransition)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .zIndex(hoveredSection == section ? 4 : 0)
    }

    private var sidebarTooltipTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))
    }

    private var infoButtonWidth: CGFloat {
        let sidebarWidth = isCollapsed ? collapsedWidth : expandedWidth
        let horizontalPadding: CGFloat = isCollapsed ? 10 : 14
        return sidebarWidth - horizontalPadding * 2
    }

    private var infoAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
    }

    private var infoTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.985, anchor: .bottomLeading))
    }

}

enum ProjectInfoCopy {
    static let label = "FIDUCIA DEVELOPMENT"
    static let title = "Built to keep your words yours."
    static let introduction = "Fiducia Development builds practical digital products with care for clarity, privacy and useful technology. Sprekr is our free dictation project for people who want fast speech to text without a monthly subscription."
    static let localTitle = "Private on this Mac"
    static let localBody = "Every recording is processed on this Mac with a local speech model. Audio is temporary and disappears after the result is ready."
    static let controlTitle = "You stay in control"
    static let controlBody = "Your History and Dictionary use encrypted local storage. There is no account, advertising, analytics, telemetry or cloud sync. You can export or permanently remove your data from Settings."

    static let allText = [
        label,
        title,
        introduction,
        localTitle,
        localBody,
        controlTitle,
        controlBody
    ]
}

enum ProjectInfoCalloutGeometry {
    static let panelWidth: CGFloat = 410
    static let infoButtonHeight: CGFloat = 50
    static let arrowWidth: CGFloat = 14
    static let arrowHeight: CGFloat = 22
    static let arrowBottomInset: CGFloat = 14

    static var arrowCenterAboveBottom: CGFloat {
        arrowBottomInset + arrowHeight / 2
    }
}

private struct SprekrProjectInfoCallout: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: -1) {
            SprekrCalloutArrow()
                .fill(SprekrPalette.canvas)
                .frame(
                    width: ProjectInfoCalloutGeometry.arrowWidth,
                    height: ProjectInfoCalloutGeometry.arrowHeight
                )
                .overlay {
                    SprekrCalloutArrow()
                        .stroke(SprekrPalette.line.opacity(0.82), lineWidth: 1)
                }
                .padding(.bottom, ProjectInfoCalloutGeometry.arrowBottomInset)
                .zIndex(1)

            SprekrProjectInfoPopover(dismiss: dismiss)
                .zIndex(2)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SprekrCalloutArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct SprekrProjectInfoPopover: View {
    let dismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZStack {
            SprekrPalette.canvas
            SprekrContentBackground()
                .opacity(0.13)

            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 12) {
                    FiduciaBrandMarkView(width: 30, height: 30)
                        .frame(width: 36, height: 36)

                    Text(ProjectInfoCopy.label)
                        .sprekrLabel()

                    Spacer(minLength: 12)

                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SprekrPalette.icon)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SprekrHoverButtonStyle(cornerRadius: 9))
                    .help("Close")
                    .accessibilityLabel("Close information")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(ProjectInfoCopy.title)
                        .sprekrHeading(32)
                    Text(ProjectInfoCopy.introduction)
                        .sprekrBody()
                }

                Divider()
                    .overlay(SprekrPalette.line.opacity(0.68))

                ProjectInfoRow(
                    symbol: "lock.shield",
                    title: ProjectInfoCopy.localTitle,
                    detail: ProjectInfoCopy.localBody
                )

                ProjectInfoRow(
                    symbol: "hand.raised",
                    title: ProjectInfoCopy.controlTitle,
                    detail: ProjectInfoCopy.controlBody
                )
            }
            .padding(24)
        }
        .frame(width: ProjectInfoCalloutGeometry.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(shape)
        .overlay {
            shape.stroke(SprekrPalette.line.opacity(0.82), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ProjectInfoRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SprekrPalette.icon)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(SprekrTypography.body(15, weight: .semibold))
                    .foregroundStyle(SprekrPalette.primaryText)
                Text(detail)
                    .font(SprekrTypography.body(13, weight: .regular))
                    .foregroundStyle(SprekrPalette.secondaryText)
                    .lineSpacing(3)
            }
        }
    }
}

private struct SprekrSidebarTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SprekrTypography.body(13, weight: .medium))
            .foregroundStyle(Color(red: 0.95, green: 0.95, blue: 0.92))
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.11, blue: 0.105))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .fixedSize()
            .accessibilityHidden(true)
    }
}
