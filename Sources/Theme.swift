import AppKit
import SwiftUI

/// Colors, type and measurements. Everything is tuned for long, calm writing
/// sessions: warm paper, soft ink, one quiet accent.
enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    static let paper = dynamic(light: hex(0xF8F6F1), dark: hex(0x1B1A18))
    static let panel = dynamic(light: hex(0xF2EFE8), dark: hex(0x21201D))
    static let ink = dynamic(light: hex(0x2B2A26), dark: hex(0xE0DCD3))
    static let inkSecondary = dynamic(light: hex(0x8A857B), dark: hex(0x8F8A80))
    static let marker = dynamic(light: hex(0x2B2A26, 0.28), dark: hex(0xE0DCD3, 0.28))
    static let ghost = dynamic(light: hex(0x2B2A26, 0.16), dark: hex(0xE0DCD3, 0.17))
    static let accent = dynamic(light: hex(0xA8743A), dark: hex(0xD3A468))
    static let ai = dynamic(light: hex(0x7468AE), dark: hex(0xA9A0DE))
    static let hairline = dynamic(light: hex(0x2B2A26, 0.08), dark: hex(0xE0DCD3, 0.08))
    static let selection = dynamic(light: hex(0xA8743A, 0.18), dark: hex(0xD3A468, 0.24))
    static let mark = dynamic(light: hex(0xEBCB6B, 0.35), dark: hex(0xC9A53F, 0.28))
    static let cutInk = dynamic(light: hex(0x2B2A26, 0.30), dark: hex(0xE0DCD3, 0.30))
    static let cutStrike = dynamic(light: hex(0xB4553F, 0.55), dark: hex(0xE07B62, 0.55))
    static let codeBackground = dynamic(light: hex(0x2B2A26, 0.05), dark: hex(0xE0DCD3, 0.06))

    /// Text zoom (⌘+ / ⌘- / ⌘0). Never saved: every launch starts at 1.
    private(set) static var zoom: CGFloat = 1

    static var column: CGFloat { 660 * zoom }
    static let topInset: CGFloat = 72

    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.serif),
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }

    // Fonts and spacing at the current zoom, rebuilt by setZoom.
    private(set) static var body = serif(18)
    private(set) static var mono = NSFont.monospacedSystemFont(ofSize: 15.5, weight: .regular)
    private(set) static var overflowFont = serif(15)
    private static var headings = makeHeadings(1)
    private(set) static var paragraph = makeParagraph(1)
    private(set) static var headingParagraph = makeHeadingParagraph(1)
    private(set) static var quoteParagraph = makeQuoteParagraph(1)

    static func heading(_ level: Int) -> NSFont {
        headings[min(max(level, 1), 4) - 1]
    }

    static func setZoom(_ z: CGFloat) {
        zoom = z
        body = serif(18 * z)
        mono = NSFont.monospacedSystemFont(ofSize: 15.5 * z, weight: .regular)
        overflowFont = serif(15 * z)
        headings = makeHeadings(z)
        paragraph = makeParagraph(z)
        headingParagraph = makeHeadingParagraph(z)
        quoteParagraph = makeQuoteParagraph(z)
    }

    private static func makeHeadings(_ z: CGFloat) -> [NSFont] {
        [30, 24, 20, 18].map { serif($0 * z, weight: .semibold) }
    }

    private static func makeParagraph(_ z: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.42
        p.paragraphSpacing = 4 * z
        return p
    }

    private static func makeHeadingParagraph(_ z: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        p.paragraphSpacing = 6 * z
        p.paragraphSpacingBefore = 8 * z
        return p
    }

    private static func makeQuoteParagraph(_ z: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.42
        p.paragraphSpacing = 12 * z
        p.firstLineHeadIndent = 0
        p.headIndent = 18 * z
        return p
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: body, .paragraphStyle: paragraph, .foregroundColor: ink]
    }

    static var overflowAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.35
        p.paragraphSpacing = 8 * zoom
        return [.font: overflowFont, .paragraphStyle: p, .foregroundColor: ink]
    }
}

extension Color {
    static let paper = Color(nsColor: Theme.paper)
    static let panel = Color(nsColor: Theme.panel)
    static let ink = Color(nsColor: Theme.ink)
    static let inkSecondary = Color(nsColor: Theme.inkSecondary)
    static let accent = Color(nsColor: Theme.accent)
    static let aiTint = Color(nsColor: Theme.ai)
    static let hairline = Color(nsColor: Theme.hairline)
}

/// Light or dark pages: follow the Mac (the default), or always one or the other.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var current: AppearanceSetting {
        AppearanceSetting(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Applies the saved choice to every window.
    @MainActor static func apply() {
        switch current {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
