import SwiftUI
import HermesKit

/// One set of colors for a theme. Values come from the desktop's presets
/// (apps/shared/src/theme-presets.ts, apps/desktop/src/themes).
public struct Slots: Hashable, Sendable {
    var background, foreground, sidebar, primary, muted, border, userBubble, destructive, success: UInt32
    /// Text on top of `primary` (send button, Run).
    var onPrimary: UInt32 = 0xffffff
}

public struct Palette: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// nil for dark-only themes; the app then forces dark mode.
    let light: Slots?
    let dark: Slots
    /// Monospaced text everywhere (Matrix).
    var monospaced = false
    var radius: CGFloat = 6

    static let nous = Palette(
        id: "nous", name: "Nous",
        light: Slots(background: 0xffffff, foreground: 0x1f2328, sidebar: 0xf6f8fa, primary: 0x0053fd, muted: 0x656d76,
                     border: 0xd0d7de, userBubble: 0xdae7fd, destructive: 0xcf222e, success: 0x1f8a65),
        dark: Slots(background: 0x0d1117, foreground: 0xe6edf3, sidebar: 0x010409, primary: 0x4a84fe, muted: 0x7d8590,
                    border: 0x30363d, userBubble: 0x07162c, destructive: 0xf85149, success: 0x55a583))

    /// Desktop "Catppuccin (Latte / Mocha)": Latte in light mode, Mocha in dark.
    static let catppuccin = Palette(
        id: "catppuccin", name: "Catppuccin",
        light: Slots(background: 0xeff1f5, foreground: 0x4c4f69, sidebar: 0xe6e9ef, primary: 0x6d2ebf, muted: 0x8c8fa1,
                     border: 0xacb0be, userBubble: 0xd7d3e9, destructive: 0xd20f39, success: 0x40a02b),
        dark: Slots(background: 0x1e1e2e, foreground: 0xcdd6f4, sidebar: 0x181825, primary: 0xcba6f7, muted: 0x7f849c,
                    border: 0x585b70, userBubble: 0x38324b, destructive: 0xf38ba8, success: 0xa6e3a1))

    /// The desktop's "Cyberpunk" preset ("Neon green on black, matrix terminal"). Dark only, monospaced.
    /// The bubble uses the preset's `secondary` green so it stays visible on the near-black background.
    static let matrix = Palette(
        id: "matrix", name: "Matrix", light: nil,
        dark: Slots(background: 0x000a00, foreground: 0x00ff41, sidebar: 0x001200, primary: 0x00ff41, muted: 0x1a8a30,
                    border: 0x003000, userBubble: 0x002800, destructive: 0xff003c, success: 0x00ba75, onPrimary: 0x000a00),
        monospaced: true)

    public static let all: [Palette] = [nous, catppuccin, matrix]

    public static func named(_ id: String) -> Palette { all.first { $0.id == id } ?? nous }
}

/// Colors for the current palette. Views read these statically; RootView sets `palette`
/// and rebuilds the view tree when the theme changes.
public enum Theme {
    nonisolated(unsafe) static var palette = Palette.nous

    public static var background: Color { color(\.background) }
    public static var foreground: Color { color(\.foreground) }
    public static var sidebar: Color { color(\.sidebar) }
    public static var primary: Color { color(\.primary) }
    public static var muted: Color { color(\.muted) }
    public static var border: Color { color(\.border) }
    public static var userBubble: Color { color(\.userBubble) }
    public static var destructive: Color { color(\.destructive) }
    public static var success: Color { color(\.success) }
    public static var onPrimary: Color { color(\.onPrimary) }

    // Text styles rather than fixed sizes so they follow the chat text size (12pt and 11pt at the default).
    public static let mono = Font.system(.caption, design: .monospaced)
    public static let monoSmall = Font.system(.caption2, design: .monospaced)
    public static var radius: CGFloat { palette.radius }

    static func color(_ slot: KeyPath<Slots, UInt32>) -> Color {
        let dark = palette.dark[keyPath: slot]
        let light = palette.light?[keyPath: slot] ?? dark
        return dynamic(light, dark)
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
        #else
        Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
        #endif
    }

    #if canImport(UIKit)
    static func ui(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    #else
    static func ns(_ hex: UInt32) -> NSColor {
        NSColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    #endif
}

/// The user's light/dark choice; dark-only palettes ignore it.
public enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

/// The chat text size setting: an index into a fixed list of Dynamic Type sizes.
/// Only the chat screens apply it (`chatTextSize()`); lists, settings and navigation keep the system size.
public enum ChatTextSize {
    public static let key = "chatTextSize"
    static let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge, .accessibility1]
    static let percents = [80, 90, 100, 110, 120, 135, 150, 170]
    /// `.large`, the system default.
    public static let standard = 3

    static func clamped(_ index: Int) -> Int { min(max(index, 0), sizes.count - 1) }
    static func size(_ index: Int) -> DynamicTypeSize { sizes[clamped(index)] }
    static func label(_ index: Int) -> String { "\(percents[clamped(index)])%" }
}

private struct ChatTextSizeModifier: ViewModifier {
    @AppStorage(ChatTextSize.key) private var index = ChatTextSize.standard
    func body(content: Content) -> some View { content.dynamicTypeSize(ChatTextSize.size(index)) }
}

extension View {
    /// Scales every text style in a chat screen to the user's chat text size.
    func chatTextSize() -> some View { modifier(ChatTextSizeModifier()) }

    /// Applies the palette's colors, scheme and font treatment to a whole screen.
    func themed(_ palette: Palette, _ appearance: Appearance) -> some View {
        #if canImport(UIKit)
        // Navigation titles ignore SwiftUI's foregroundStyle, so style the bar itself.
        let title = UIColor(Theme.foreground)
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: title]
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: title]
        #endif
        return self
            .preferredColorScheme(palette.light == nil ? .dark : appearance.scheme)
            .fontDesign(palette.monospaced ? .monospaced : nil)
            .foregroundStyle(Theme.foreground)
            .tint(Theme.primary)
    }

    /// Lists and forms paint the palette instead of the system grouped background.
    func themedList() -> some View {
        self.scrollContentBackground(.hidden).background(Theme.background)
    }
}
