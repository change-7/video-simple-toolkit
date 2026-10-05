import SwiftUI

enum ToolkitTheme {
    static let accent = Color(red: 0.05, green: 0.58, blue: 0.52)
    static let accentSoft = Color(red: 0.05, green: 0.58, blue: 0.52).opacity(0.14)
    static let action = Color(red: 0.95, green: 0.42, blue: 0.12)
    static let panelFill = Color(nsColor: .controlBackgroundColor).opacity(0.84)
    static let insetFill = Color(nsColor: .textBackgroundColor).opacity(0.82)
    static let selectedFill = accent.opacity(0.12)
    static let hairline = Color.primary.opacity(0.10)
    static let emphasizedHairline = Color.primary.opacity(0.16)
    static let panelShadow = Color.black.opacity(0.06)
}

struct ToolkitWindowBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Color(nsColor: .underPageBackgroundColor).opacity(0.22)
        }
        .ignoresSafeArea()
    }
}

struct ToolkitPanelGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)

            configuration.content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ToolkitTheme.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ToolkitTheme.hairline, lineWidth: 1)
        )
        .shadow(color: ToolkitTheme.panelShadow, radius: 8, y: 2)
    }
}

extension GroupBoxStyle where Self == ToolkitPanelGroupBoxStyle {
    static var toolkitPanel: ToolkitPanelGroupBoxStyle {
        ToolkitPanelGroupBoxStyle()
    }
}

struct ToolkitMetricPill: View {
    let title: String
    let value: String
    var color: Color = ToolkitTheme.accent

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(color.opacity(0.10))
        )
        .overlay(
            Capsule()
                .stroke(color.opacity(0.18), lineWidth: 1)
        )
    }
}

struct ToolkitStatusPill: View {
    let title: String
    let isReady: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isReady ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

private struct InstantHelpModifier: ViewModifier {
    let message: String
    var alignment: Alignment = .topLeading

    @AppStorage("settings.ui.hoverHelpEnabled") private var isHoverHelpEnabled: Bool = true
    @State private var isHovering = false

    func body(content: Content) -> some View {
        let isPresented = Binding<Bool>(
            get: { isHoverHelpEnabled && isHovering },
            set: { presented in
                if !presented {
                    isHovering = false
                }
            }
        )

        content
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.06)) {
                    isHovering = isHoverHelpEnabled && hovering
                }
            }
            .popover(isPresented: isPresented, arrowEdge: .top) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
    }
}

extension View {
    func instantHelp(_ message: String, alignment: Alignment = .topLeading) -> some View {
        modifier(InstantHelpModifier(message: message, alignment: alignment))
    }

    func toolkitDropSurface(isActive: Bool, cornerRadius: CGFloat = 8) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(isActive ? ToolkitTheme.accentSoft : ToolkitTheme.insetFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    isActive ? ToolkitTheme.accent.opacity(0.82) : ToolkitTheme.emphasizedHairline,
                    style: StrokeStyle(lineWidth: 1, dash: isActive ? [4, 4] : [])
                )
        )
    }
}
