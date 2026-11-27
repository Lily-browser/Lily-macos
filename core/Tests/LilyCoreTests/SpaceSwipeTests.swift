import SwiftUI
import Testing
@testable import LilyCore

@Suite struct SpaceSwipeTests {
    @Test func colorBlendHitsTheEndsAndTheMiddle() {
        #expect(SpaceSwipe.blend("#000000", "#FFFFFF", 0) == "#000000")
        #expect(SpaceSwipe.blend("#000000", "#FFFFFF", 1) == "#FFFFFF")
        #expect(SpaceSwipe.blend("#000000", "#FFFFFF", 0.5) == "#808080")
        #expect(SpaceSwipe.blend("#FF0000", "#0000FF", 0.5) == "#800080")
        // Out-of-range fractions clamp; unreadable colors leave the first as it is.
        #expect(SpaceSwipe.blend("#102030", "#FFFFFF", 7) == "#FFFFFF")
        #expect(SpaceSwipe.blend("#102030", "not a color", 0.5) == "#102030")
        #expect(SpaceSwipe.blend("5E5CE6", "#BF5AF2", 1) == "#BF5AF2")
    }

    @Test func progressIsZeroWithoutATargetAndClampsAtOne() {
        #expect(SpaceSwipe.progress(offset: 90, threshold: 60, hasTarget: false) == 0)
        #expect(SpaceSwipe.progress(offset: 30, threshold: 60, hasTarget: true) == 0.5)
        #expect(SpaceSwipe.progress(offset: -30, threshold: 60, hasTarget: true) == 0.5)
        #expect(SpaceSwipe.progress(offset: 500, threshold: 60, hasTarget: true) == 1)
        #expect(SpaceSwipe.progress(offset: 10, threshold: 0, hasTarget: true) == 0)
    }

    @Test func depthRecedesWithDistanceAndPivotsOnTheEdgeItMovesToward() {
        let rest = SpaceSwipe.depth(offset: 0, reduceMotion: false)
        #expect(rest.scale == 1 && rest.tilt == 0 && rest.opacity == 1)
        let half = SpaceSwipe.depth(offset: -110, reduceMotion: false)
        let full = SpaceSwipe.depth(offset: -220, reduceMotion: false)
        #expect(half.scale < 1 && full.scale < half.scale)
        #expect(abs(full.tilt) > abs(half.tilt))
        #expect(half.anchor == .leading) // dragging left: the leading edge is where it is heading
        #expect(SpaceSwipe.depth(offset: 110, reduceMotion: false).anchor == .trailing)
        #expect(half.tilt < 0 && SpaceSwipe.depth(offset: 110, reduceMotion: false).tilt > 0)
        #expect(SpaceSwipe.depth(offset: -900, reduceMotion: false) == full || SpaceSwipe.depth(offset: -900, reduceMotion: false).scale == full.scale)
    }

    @Test func reduceMotionKeepsOnlyTheFade() {
        let still = SpaceSwipe.depth(offset: -200, reduceMotion: true)
        #expect(still.scale == 1 && still.tilt == 0)
        #expect(still.opacity < 1)
    }
}
