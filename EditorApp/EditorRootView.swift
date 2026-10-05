import AppKit
import SwiftUI

struct EditorRootView: View {
    @State private var selectedTab: RootTab = .toolkit

    var body: some View {
        TabView(selection: $selectedTab) {
            EditorWorkspaceView()
                .tabItem {
                    Label("편집", systemImage: "timeline.selection")
                }
                .tag(RootTab.editor)

            MainView()
                .tabItem {
                    Label("툴킷", systemImage: "square.and.arrow.down")
                }
                .tag(RootTab.toolkit)
        }
        .background(EditorRootWindowSizer(selectedTab: selectedTab))
    }
}

private enum RootTab {
    case editor
    case toolkit

    var preferredSize: CGSize {
        switch self {
        case .editor:
            return CGSize(width: 1180, height: 760)
        case .toolkit:
            return CGSize(width: 820, height: 620)
        }
    }

    var minimumSize: CGSize {
        switch self {
        case .editor:
            return CGSize(width: 760, height: 560)
        case .toolkit:
            return CGSize(width: 700, height: 520)
        }
    }
}

private struct EditorRootWindowSizer: NSViewRepresentable {
    let selectedTab: RootTab

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.lastTab != selectedTab else { return }
        context.coordinator.lastTab = selectedTab

        DispatchQueue.main.async {
            guard let window = nsView.window else { return }

            window.minSize = selectedTab.minimumSize
            let targetSize = selectedTab.preferredSize
            let currentFrame = window.frame
            let targetFrame = NSRect(
                x: currentFrame.minX,
                y: currentFrame.maxY - targetSize.height,
                width: targetSize.width,
                height: targetSize.height
            )

            window.setFrame(targetFrame, display: true, animate: true)
        }
    }

    final class Coordinator {
        var lastTab: RootTab?
    }
}
