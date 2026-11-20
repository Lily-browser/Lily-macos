import AppKit
import Testing
@testable import LilyCore

@Suite @MainActor struct AppIconTests {
    @Test func everyVariantRendersDistinctLightAndDarkImages() {
        var seen = Set<Data>()
        for variant in AppIconVariant.allCases {
            for dark in [false, true] {
                let png = AppIconArt.png(pixels: 128, variant: variant, dark: dark)
                #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "\(variant) dark=\(dark) is not a PNG")
                let rep = NSBitmapImageRep(data: png)
                #expect(rep?.pixelsWide == 128 && rep?.pixelsHigh == 128)
                seen.insert(png)
            }
        }
        #expect(seen.count == AppIconVariant.allCases.count * 2) // no two icons look alike
        #expect(AppIconVariant.allCases.count == 4)
    }

    @Test func iconKeepsTheTransparentMarginOfTheMacGrid() {
        // The tile fills 824 of 1024 points: the corners and edges stay clear.
        let rep = NSBitmapImageRep(data: AppIconArt.png(pixels: 256, variant: .iris, dark: false))!
        #expect(rep.colorAt(x: 2, y: 2)?.alphaComponent == 0)
        #expect(rep.colorAt(x: 128, y: 128)?.alphaComponent == 1)
    }

    @Test func darkRenderingIsDarker() {
        for variant in AppIconVariant.allCases {
            func brightness(_ dark: Bool) -> CGFloat {
                let rep = NSBitmapImageRep(data: AppIconArt.png(pixels: 64, variant: variant, dark: dark))!
                return rep.colorAt(x: 32, y: 12)?.brightnessComponent ?? 0 // near the top of the tile
            }
            #expect(brightness(true) < brightness(false), "\(variant)")
        }
    }

    @Test func unknownStoredValueFallsBackToTheDefaultIcon() {
        #expect(AppIconVariant(stored: nil) == .iris)
        #expect(AppIconVariant(stored: "somethingFromANewerVersion") == .iris)
        #expect(AppIconVariant(stored: "rose") == .rose)
    }

    @Test func defaultLightDrawsNothingAndOthersFollowTheAppearance() {
        typealias C = AppIconController
        #expect(C.choice(variant: .iris, matchesDarkMode: true, systemIsDark: false) == nil) // the bundle's own icon
        #expect(C.choice(variant: .iris, matchesDarkMode: true, systemIsDark: true) == .init(variant: .iris, dark: true))
        #expect(C.choice(variant: .iris, matchesDarkMode: false, systemIsDark: true) == nil)
        #expect(C.choice(variant: .rose, matchesDarkMode: true, systemIsDark: false) == .init(variant: .rose, dark: false))
        #expect(C.choice(variant: .rose, matchesDarkMode: true, systemIsDark: true) == .init(variant: .rose, dark: true))
        #expect(C.choice(variant: .rose, matchesDarkMode: false, systemIsDark: true) == .init(variant: .rose, dark: false))
    }
}
