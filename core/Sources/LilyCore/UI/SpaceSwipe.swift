import SwiftUI

/// The look of the two-finger swipe between spaces: how far the outgoing list recedes (scale, tilt, fade) and the
/// color the sidebar tint washes through on the way to the next space. Pure functions, so they are tested without a window.
enum SpaceSwipe {
    /// How the list looks at `offset` points of drag. `reduceMotion` keeps only the fade: no scaling or tilt.
    struct Depth: Equatable {
        var scale: CGFloat
        var tilt: Double
        var opacity: Double
        /// The edge it pivots on: the one it is moving toward.
        var anchor: UnitPoint
    }

    /// Distance at which the effect is complete.
    static let fullDepth: CGFloat = 220

    static func depth(offset: CGFloat, reduceMotion: Bool) -> Depth {
        let p = min(1, abs(offset) / fullDepth)
        let eased = p * p * (3 - 2 * p) // smoothstep: gentle start, gentle end
        let direction: Double = offset < 0 ? -1 : 1
        let fade = 1 - min(0.35, abs(offset) / 500)
        if reduceMotion { return Depth(scale: 1, tilt: 0, opacity: fade, anchor: .center) }
        return Depth(scale: 1 - 0.07 * eased, tilt: direction * 14 * Double(eased), opacity: fade,
                     anchor: offset < 0 ? .leading : .trailing)
    }

    /// How far along the swipe is toward switching: 0 at rest, 1 at the point where it arms.
    static func progress(offset: CGFloat, threshold: CGFloat, hasTarget: Bool) -> CGFloat {
        guard hasTarget, threshold > 0 else { return 0 }
        return min(1, abs(offset) / threshold)
    }

    /// `from` mixed toward `to` (`#RRGGBB`), `t` in 0...1. An unreadable color leaves `from` as it is.
    static func blend(_ from: String, _ to: String, _ t: CGFloat) -> String {
        guard let a = rgb(from), let b = rgb(to) else { return from }
        let t = min(1, max(0, t))
        func mix(_ x: Int, _ y: Int) -> Int { Int((Double(x) + (Double(y) - Double(x)) * Double(t)).rounded()) }
        return String(format: "#%02X%02X%02X", mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b))
    }

    private static func rgb(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return (value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
    }
}

/// The sidebar tint during a swipe: `from` washing toward `to` as `progress` goes 0 → 1. Animatable, so that when the swipe
/// is released the tint eases back (or on to the new space's color) together with the list instead of jumping.
struct SpaceWash: View, @preconcurrency Animatable {
    var from: String?
    var to: String?
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        SidebarBackground(spaceColor: from.map { start in to.map { SpaceSwipe.blend(start, $0, progress) } ?? start })
    }
}
