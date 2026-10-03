import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A Markdown file. The text lives in an `NSTextStorage` that the editor's
/// text view edits directly; alternates and the overflow drawer ride along.
final class WriterDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.markdownText, .plainText] }
    static var writableContentTypes: [UTType] { [.markdownText] }

    let storage: NSTextStorage
    let overflow: NSTextStorage
    @Published var groups: [String: VariantGroup]

    init() {
        storage = NSTextStorage()
        overflow = NSTextStorage()
        groups = [:]
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let (text, groups, overflow) = MarkdownCodec.decode(String(decoding: data, as: UTF8.self))
        storage = NSTextStorage(attributedString: text)
        self.overflow = NSTextStorage(string: overflow)
        self.groups = groups
    }

    func snapshot(contentType: UTType) throws -> String {
        MarkdownCodec.encode(storage: storage, groups: groups, overflow: overflow.string)
    }

    func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(snapshot.utf8))
    }
}
