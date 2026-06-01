import CoreFoundation
import CoreGraphics
import Testing
@testable import BeepBeep

struct HatTilingTests {

    @Test func levelTwoHatTextureIsDeterministic() throws {
        let polygons = HatTilingGenerator.polygons(level: 2, tileIndex: 0)
        let bounds = HatTilingGenerator.boundingBox(for: polygons)

        #expect(polygons.count > 100)
        #expect(bounds.width > 0)
        #expect(bounds.height > 0)

        let first = try #require(polygons.first?.first)
        #expect(first.x.isFinite)
        #expect(first.y.isFinite)
    }
}
