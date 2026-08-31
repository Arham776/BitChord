import SwiftUI
import CoreGraphics
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Sampled palette from album art (upstream ArtworkPalette). Falls back to a
/// hash-seeded HSL set when pixels aren't available yet.
enum ArtworkPalette {
    struct Colors {
        let colors: [Color]
    }

    static func from(data: Data?, seed: Int) -> [Color] {
        if let data, let sampled = sample(data) { return sampled }
        return hashPalette(seed: seed)
    }

    static func hashPalette(seed: Int) -> [Color] {
        let base = Double(abs(seed) % 360)
        func hsl(_ offset: Double, _ s: Double, _ l: Double) -> Color {
            let hue = (base + offset).truncatingRemainder(dividingBy: 360) / 360
            return Color(hue: hue, saturation: s, brightness: l)
        }
        return [
            hsl(0, 0.65, 0.10), hsl(30, 0.60, 0.14), hsl(60, 0.55, 0.10),
            hsl(330, 0.55, 0.13), hsl(0, 0.70, 0.18), hsl(120, 0.45, 0.12),
            hsl(210, 0.60, 0.08), hsl(180, 0.55, 0.13), hsl(300, 0.50, 0.09),
        ]
    }

    private static func sample(_ data: Data) -> [Color]? {
#if os(iOS)
        guard let image = UIImage(data: data)?.cgImage else { return nil }
#else
        guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
#endif
        let width = min(image.width, 24)
        let height = min(image.height, 24)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var buckets: [Int: (r: Int, g: Int, b: Int, n: Int)] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let key = (r / 32) << 10 | (g / 32) << 5 | (b / 32)
            var bucket = buckets[key] ?? (0, 0, 0, 0)
            bucket.r += r; bucket.g += g; bucket.b += b; bucket.n += 1
            buckets[key] = bucket
        }
        let ranked = buckets.values.sorted { $0.n > $1.n }.prefix(6)
        guard !ranked.isEmpty else { return nil }
        var colors: [Color] = ranked.map {
            Color(
                red: Double($0.r) / Double($0.n * 255),
                green: Double($0.g) / Double($0.n * 255),
                blue: Double($0.b) / Double($0.n * 255)
            )
        }
        while colors.count < 9 { colors.append(colors[colors.count % max(colors.count, 1)]) }
        return Array(colors.prefix(9))
    }

    /// Page wash + accent from a sleeve, matching upstream's release tint.
    struct PageTint {
        var wash: Color
        var accent: Color
        var elevated: Color
    }

    static func pageTint(from data: Data?, seed: Int, dark: Bool = true) -> PageTint {
        let colors = from(data: data, seed: seed)
        let accent = vibrant(in: colors) ?? colors.first ?? Color.accentColor
        let wash = washed(accent, dark: dark)
        return PageTint(
            wash: wash,
            accent: lifted(accent, dark: dark),
            elevated: wash.opacity(0.55)
        )
    }

    private static func vibrant(in colors: [Color]) -> Color? {
        colors.max { a, b in saturation(a) < saturation(b) }
    }

    private static func saturation(_ color: Color) -> CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        NSColor(color).usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #endif
        return s * b
    }

    private static func washed(_ color: Color, dark: Bool) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        NSColor(color).usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #endif
        return Color(hue: Double(h), saturation: Double(min(0.55, s * 0.7)), brightness: dark ? 0.16 : 0.86)
    }

    private static func lifted(_ color: Color, dark: Bool) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        NSColor(color).usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #endif
        return Color(
            hue: Double(h),
            saturation: Double(min(0.85, max(0.45, s))),
            brightness: dark ? Double(max(0.62, b)) : Double(min(0.55, max(0.35, b)))
        )
    }

    /// Four luminous blob colours + a dim base, as upstream `MeshGradient.kt`.
    struct MeshBlobs {
        var base: Color
        var blobs: [Color]
    }

    private static let fallbackBlobs: [Color] = [
        Color(red: 0x3A / 255, green: 0x1C / 255, blue: 0x71 / 255),
        Color(red: 0xD7 / 255, green: 0x6D / 255, blue: 0x77 / 255),
        Color(red: 0x2B / 255, green: 0x58 / 255, blue: 0x76 / 255),
        Color(red: 0xFF / 255, green: 0xAF / 255, blue: 0x7B / 255),
    ]

    static func meshBlobs(from data: Data?, seed: Int) -> MeshBlobs {
        let sampled = from(data: data, seed: seed)
        var distinct: [Color] = []
        for color in sampled where distinct.allSatisfy({ !isClose($0, color) }) {
            distinct.append(color)
            if distinct.count == 4 { break }
        }
        if distinct.isEmpty { distinct = fallbackBlobs }
        var four = distinct
        var step = 1
        while four.count < 4 {
            four.append(shifted(distinct[(four.count - distinct.count) % distinct.count], hue: 24 * CGFloat(step), lightness: 0.12 * CGFloat(step)))
            step += 1
        }
        let tunedFour = four.prefix(4).map(tuned)
        return MeshBlobs(base: dimmed(tunedFour[0]), blobs: Array(tunedFour))
    }

    private static func isClose(_ a: Color, _ b: Color) -> Bool {
        let lhs = hsba(a), rhs = hsba(b)
        let hueGap = min(abs(lhs.h - rhs.h), 1 - abs(lhs.h - rhs.h)) * 360
        return hueGap < 15 && abs(lhs.b - rhs.b) < 0.12
    }

    private static func shifted(_ color: Color, hue: CGFloat, lightness: CGFloat) -> Color {
        let hsl = hsba(color)
        return Color(
            hue: Double((hsl.h + hue / 360).truncatingRemainder(dividingBy: 1)),
            saturation: Double(hsl.s),
            brightness: Double(min(0.7, max(0.2, hsl.b + lightness)))
        )
    }

    /// Boost saturation and clamp lightness so any sleeve yields a rich mesh.
    private static func tuned(_ color: Color) -> Color {
        let hsl = hsba(color)
        return Color(
            hue: Double(hsl.h),
            saturation: Double(min(1, hsl.s * 1.35)),
            brightness: Double(min(0.58, max(0.28, hsl.b)))
        )
    }

    private static func dimmed(_ color: Color) -> Color {
        let hsl = hsba(color)
        return Color(hue: Double(hsl.h), saturation: Double(hsl.s), brightness: 0.12)
    }

    private static func hsba(_ color: Color) -> (h: CGFloat, s: CGFloat, b: CGFloat, a: CGFloat) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        NSColor(color).usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #endif
        return (h, s, b, a)
    }
}
