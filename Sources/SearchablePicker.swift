import AppKit
import SwiftUI

/// A searchable dropdown built from SwiftUI alone. SwiftUI has no combobox —
/// `Picker` has no search field and `.searchable` needs a navigation context —
/// so this is a button that opens a popover holding a search field and a
/// filtered list. Callers see one component.
///
/// `selection` carries the option **id**. Text that matches no option can still
/// be committed as a free-form id (Enter, or the "use typed text" row), which is
/// how a locally configured model outside the catalog stays selectable.
/// The id a committed search text maps to: a known option's id when the text
/// matches its name or id, otherwise the text itself as a free-form id. Pure, so
/// the free-text rule is pinned by a check rather than by opening the popover.
func resolveModelSelection(_ text: String, in options: [(id: String, name: String)]) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    return options.first { $0.name == trimmed || $0.id == trimmed }?.id ?? trimmed
}

struct SearchablePicker: View {
    let options: [(id: String, name: String)]
    @Binding var selection: String
    var placeholder: String = "Select…"
    var searchPlaceholder: String = "Search"

    @State private var isOpen = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var selectedName: String {
        options.first { $0.id == selection }?.name ?? selection
    }

    private var filtered: [(id: String, name: String)] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return options }
        return options.filter {
            $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle)
        }
    }

    var body: some View {
        Button {
            query = ""
            isOpen = true
        } label: {
            HStack(spacing: 6) {
                Text(selectedName.isEmpty ? placeholder : selectedName)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selectedName.isEmpty ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { popover }

        // A field-bound change made outside the popover (opening the editor for
        // another harness) must not carry the previous search text over.
        .onChange(of: selection) { _ in query = "" }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(searchPlaceholder, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit(commitTypedText)
                .padding(8)
            Divider()
            if filtered.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No matching model").font(.caption).foregroundStyle(.secondary)
                    let typed = query.trimmingCharacters(in: .whitespaces)
                    if !typed.isEmpty {
                        Button("Use “\(typed)”") { commitTypedText() }
                            .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered, id: \.id) { option in
                            Button {
                                selection = option.id
                                isOpen = false
                            } label: {
                                HStack {
                                    Text(option.name).lineLimit(1)
                                    Spacer(minLength: 8)
                                    if option.id == selection {
                                        Image(systemName: "checkmark").font(.caption)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            Divider()
            Text("Type to filter · ⏎ uses unmatched text as an id")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(6)
        }
        .frame(width: 360)
        .onAppear { searchFocused = true }
    }

    /// Commits the typed text: a known name/id maps to its id, anything else is
    /// taken verbatim as the free-form id the editor has always accepted.
    private func commitTypedText() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        selection = resolveModelSelection(text, in: options)
        isOpen = false
    }
}
