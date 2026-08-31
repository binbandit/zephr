import Foundation
import CoreGraphics

/// A color as plain sRGB components in 0…1. Core is AppKit-free, so config
/// colors travel as numbers and only become an `NSColor` at the app boundary.
public struct RGBAColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA`, with or without the leading
    /// `#` and in either case. Returns nil rather than a guess, so the config
    /// parser can warn with the line number the mistake is actually on.
    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        // `isHexDigit` alone also accepts fullwidth forms that `UInt32` then
        // rejects; requiring ASCII keeps accept and parse in agreement.
        guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let packed = UInt32(digits, radix: 16)
        else { return nil }

        func byte(_ shift: UInt32) -> Double { Double((packed >> shift) & 0xFF) / 255 }
        // #RGB is shorthand: each nibble doubles into a byte, so f → ff.
        func nibble(_ shift: UInt32) -> Double { Double((packed >> shift) & 0xF) * 17 / 255 }

        switch digits.count {
        case 3: self.init(red: nibble(8), green: nibble(4), blue: nibble(0))
        case 6: self.init(red: byte(16), green: byte(8), blue: byte(0))
        case 8: self.init(red: byte(24), green: byte(16), blue: byte(8), alpha: byte(0))
        default: return nil
        }
    }

    /// `#RRGGBB`, gaining the `AA` suffix only when the color is translucent.
    /// The inverse of `init(hex:)`, and what the Settings color well writes
    /// back — a config the GUI produces must be one a human can re-edit.
    public var hexString: String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha >= 1 ? rgb : rgb + String(format: "%02X", byte(alpha))
    }
}

/// How the focused-window border is drawn (§4.3), from `[layout]`.
///
/// Kept out of `LayoutConfig` because none of it reaches the solver: these
/// values only paint, which is also why the parser warns and keeps the
/// default on a bad one instead of rejecting the whole file.
public struct FocusBorderStyle: Sendable, Equatable {
    /// `focus-border`.
    public var enabled: Bool
    /// `focus-border-color`. nil means the macOS accent color, which is a
    /// live user setting the border follows — no fixed hex can stand in for
    /// it, so "unset" has to stay distinguishable from "set to some color".
    public var color: RGBAColor?
    /// `focus-border-width`, in points.
    public var width: CGFloat
    /// `focus-border-radius`, the outline's own corner radius; 0 is square.
    /// nil tracks the system window radius, which grew in macOS 26 and will
    /// move again.
    public var cornerRadius: CGFloat?

    public init(
        enabled: Bool = true,
        color: RGBAColor? = nil,
        width: CGFloat = 2,
        cornerRadius: CGFloat? = nil
    ) {
        self.enabled = enabled
        self.color = color
        self.width = width
        self.cornerRadius = cornerRadius
    }

    public static let `default` = FocusBorderStyle()
}
