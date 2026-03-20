import AppKit
import Foundation

@MainActor
enum FolderAccessManager {
    static func selectFolder(title: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func selectLogExportURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Log"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
