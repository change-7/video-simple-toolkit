import SwiftUI
import AppKit

struct CopyButton: View {
    let title: String
    let valueProvider: () -> String
    var disabled: Bool = false
    var showsInstantHelp: Bool = true

    var body: some View {
        if showsInstantHelp {
            button
                .instantHelp("텍스트를 클립보드에 복사합니다.")
        } else {
            button
        }
    }

    private var button: some View {
        Button(title) {
            copyToClipboard(valueProvider())
        }
        .disabled(disabled)
    }

    private func copyToClipboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
