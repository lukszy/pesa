import AppKit
import SwiftUI

/// A searchable model selector: an `NSComboBox` whose dropdown filters as the
/// user types, while typed text that matches no known model is still accepted as
/// a free-form id. SwiftUI's `Picker` has no search field and a menu cannot host
/// one, so the native macOS searchable select is bridged here.
///
/// `selection` always carries the model **id**. A dropdown row shows the model's
/// display name; free text is taken verbatim as an id, which is how a locally
/// configured non-catalog model stays selectable.
struct SearchableModelField: NSViewRepresentable {
    let models: [(id: String, name: String)]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.usesDataSource = true
        combo.dataSource = context.coordinator
        combo.delegate = context.coordinator
        combo.isEditable = true
        // Our own filtering owns the dropdown; the built-in completion would
        // fight it by rewriting the field mid-type.
        combo.completes = false
        combo.numberOfVisibleItems = 12
        combo.placeholderString = "Search or type a model id"
        context.coordinator.apply(selection: selection, to: combo)
        return combo
    }

    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.parent = self
        context.coordinator.models = models
        // Reset the filter only when the field is not mid-edit, so a list update
        // (the provider's models arriving) cannot wipe what the user typed.
        if combo.currentEditor() == nil {
            context.coordinator.filtered = models
            context.coordinator.apply(selection: selection, to: combo)
        }
        combo.reloadData()
    }

    final class Coordinator: NSObject, NSComboBoxDataSource, NSComboBoxDelegate {
        var parent: SearchableModelField
        var models: [(id: String, name: String)]
        var filtered: [(id: String, name: String)]

        init(_ parent: SearchableModelField) {
            self.parent = parent
            self.models = parent.models
            self.filtered = parent.models
        }

        /// The field shows the display name for a known id, otherwise the id
        /// itself (a free-form or non-catalog value).
        func apply(selection: String, to combo: NSComboBox) {
            combo.stringValue = models.first { $0.id == selection }?.name ?? selection
        }

        func numberOfItems(in comboBox: NSComboBox) -> Int { filtered.count }

        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            index < filtered.count ? filtered[index].name : nil
        }

        func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
            filtered.firstIndex { $0.name == string } ?? NSNotFound
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            let index = combo.indexOfSelectedItem
            guard index >= 0, index < filtered.count else { return }
            parent.selection = filtered[index].id
            combo.stringValue = filtered[index].name
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            let query = combo.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            filtered = query.isEmpty ? models : models.filter {
                $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query)
            }
            combo.reloadData()
        }

        /// Enter or focus loss commits. A known name or id maps to its id; any
        /// other text is the free-form id the field has always accepted.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            let text = combo.stringValue.trimmingCharacters(in: .whitespaces)
            if let match = models.first(where: { $0.name == text || $0.id == text }) {
                parent.selection = match.id
                combo.stringValue = match.name
            } else {
                parent.selection = text
            }
        }
    }
}
