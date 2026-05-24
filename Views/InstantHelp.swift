import SwiftUI

private struct InstantHelpModifier: ViewModifier {
    let message: String
    var alignment: Alignment = .topLeading

    @AppStorage(SettingsKeys.hoverHelpEnabled) private var isHoverHelpEnabled: Bool = true
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
}
