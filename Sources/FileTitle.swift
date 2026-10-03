import SwiftUI

/// The document's name, shown only while the pointer is near the top edge
/// (where the window buttons appear). Clicking it shows where the file lives,
/// with Show in Finder, Copy Path and Rename.
struct FileTitle: View {
    let fileURL: URL?
    let window: () -> NSWindow?
    var export: (() -> Void)? = nil
    @Binding var visible: Bool
    @State private var showDetails = false
    @State private var hovering = false

    private var shown: Bool { visible || hovering || showDetails }

    var body: some View {
        Button {
            if fileURL == nil {
                NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
            } else {
                showDetails.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text(fileURL?.lastPathComponent ?? "Untitled")
                if fileURL != nil {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .opacity(0.7)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.inkSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .help(fileURL == nil ? "Not saved yet. Click to save (⌘S)." : "Show where this file lives")
        .frame(maxWidth: 420)
        .onHover { hovering = $0 }
        .opacity(shown ? 1 : 0)
        .animation(.easeOut(duration: shown ? 0.15 : 0.4), value: shown)
        .allowsHitTesting(shown)
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            if let fileURL {
                FileDetails(fileURL: fileURL, window: window, close: { showDetails = false }, export: export)
            }
        }
    }
}

struct FileDetails: View {
    let fileURL: URL
    let window: () -> NSWindow?
    let close: () -> Void
    var export: (() -> Void)? = nil
    @State private var renaming = false
    @State private var newName = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var folder: String {
        (fileURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if renaming {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($nameFocused)
                        .onSubmit(rename)
                        .onExitCommand { renaming = false }
                } else {
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                }
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text(folder)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Color.inkSecondary)
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Theme.cutStrike).opacity(1))
                }
            }

            Divider()

            HStack(spacing: 14) {
                if renaming {
                    Button("Cancel") { renaming = false; error = nil }
                        .pointingHandOnHover()
                    Spacer()
                    Button("Rename", action: rename)
                        .keyboardShortcut(.defaultAction)
                        .pointingHandOnHover()
                } else {
                    action("Show in Finder", "magnifyingglass") {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        close()
                    }
                    action("Copy Path", "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fileURL.path, forType: .string)
                        close()
                    }
                    if let export {
                        action("Export…", "square.and.arrow.up") {
                            close()
                            export()
                        }
                        .help("Export a clean copy (⌥⇧⌘E)")
                    }
                    action("Rename…", "pencil") {
                        newName = fileURL.deletingPathExtension().lastPathComponent
                        error = nil
                        renaming = true
                        nameFocused = true
                    }
                }
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accent)
        .pointingHandOnHover()
    }

    /// Renames the file in place through the document, so the window, its
    /// undo history and autosave follow it.
    private func rename() {
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { error = "Enter a name without slashes."; return }
        if (name as NSString).pathExtension.isEmpty { name += "." + fileURL.pathExtension }
        let target = fileURL.deletingLastPathComponent().appendingPathComponent(name)
        guard target != fileURL else { renaming = false; return }
        guard !FileManager.default.fileExists(atPath: target.path) else { error = "A file with that name already exists here."; return }
        guard let document = window()?.windowController?.document as? NSDocument else { error = "Couldn't find this document."; return }
        document.move(to: target) { failure in
            DispatchQueue.main.async {
                if let failure {
                    error = failure.localizedDescription
                } else {
                    renaming = false
                    close()
                }
            }
        }
    }
}
