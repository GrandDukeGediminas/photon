import AppKit
import PhotonApp

extension AppState {
    /// Name prompt for "Save preset" (the UI's `browseCollections` dialog with `isSaving`).
    static func promptPresetName(existing: [String]) -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = existing.isEmpty ? "Name of the preset." : "A preset with the same name is updated."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
