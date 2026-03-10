import SwiftUI
import AppKit

struct CopyButton: View {
    let title: String
    let valueProvider: () -> String
    var disabled: Bool = false

    var body: some View {
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

