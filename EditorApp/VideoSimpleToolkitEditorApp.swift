import SwiftUI

@main
struct VideoSimpleToolkitEditorApp: App {
    @StateObject private var toolManager = ToolManager()

    var body: some Scene {
        WindowGroup {
            EditorRootView()
                .environmentObject(toolManager)
                .frame(minWidth: 700, minHeight: 520)
                .onAppear {
                    toolManager.refresh()
                }
        }
        .commands {
            EditorUndoRedoCommands()
        }
    }
}

private struct EditorUndoRedoCommands: Commands {
    @FocusedValue(\.editorUndoAction) private var undoAction
    @FocusedValue(\.editorRedoAction) private var redoAction

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                undoAction?()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(undoAction == nil)

            Button("Redo") {
                redoAction?()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(redoAction == nil)
        }
    }
}
