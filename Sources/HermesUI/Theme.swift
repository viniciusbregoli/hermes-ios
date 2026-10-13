import SwiftUI
import HermesKit

/// The desktop's default `nous` skin (apps/shared/src/theme-presets.ts).
public enum Theme {
    public static let background = dynamic(0xffffff, 0x0d1117)
    public static let foreground = dynamic(0x1f2328, 0xe6edf3)
    public static let sidebar = dynamic(0xf6f8fa, 0x010409)
    public static let primary = dynamic(0x0053fd, 0x4a84fe)
    public static let muted = dynamic(0x656d76, 0x7d8590)
    public static let border = dynamic(0xd0d7de, 0x30363d)
    public static let userBubble = dynamic(0xdae7fd, 0x07162c)
    public static let destructive = dynamic(0xcf222e, 0xf85149)
    public static let success = dynamic(0x1f8a65, 0x55a583)

    public static let mono = Font.system(size: 12, design: .monospaced)
    public static let monoSmall = Font.system(size: 11, design: .monospaced)
    /// Desktop radii are near square (radius scalar 0.2).
    public static let radius: CGFloat = 6

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
