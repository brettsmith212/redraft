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
    /// The length target in words, if the writer set one.
    @Published var target: Int?

    init() {
        storage = NSTextStorage()
        overflow = NSTextStorage()
        groups = [:]
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let contents = Self.text(from: data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let (text, groups, overflow, target) = MarkdownCodec.decode(contents)
        storage = NSTextStorage(attributedString: text)
        self.overflow = NSTextStorage(string: overflow)
        self.groups = groups
        self.target = target
    }

    /// The file's text. Markdown is UTF-8, but a file from elsewhere may use
    /// another encoding: read it in that one (it's saved back as UTF-8) rather
    /// than garble it, and refuse a file that can't be read without loss.
    static func text(from data: Data) -> String? {
        let utf8 = String(decoding: data, as: UTF8.self)
        if utf8.utf8.elementsEqual(data) { return utf8 }
        var converted: NSString?
        var lossy: ObjCBool = false
        let encoding = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: [String.Encoding.utf16.rawValue, String.Encoding.windowsCP1252.rawValue, String.Encoding.macOSRoman.rawValue],
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        guard encoding != 0, !lossy.boolValue, let converted else { return nil }
        return converted as String
    }

    func snapshot(contentType: UTType) throws -> String {
        MarkdownCodec.encode(storage: storage, groups: groups, overflow: overflow.string, target: target)
    }

    func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(snapshot.utf8))
    }
}
