import Foundation
import Testing
@testable import Captylo

struct SiteLinksTests {
    @Test func polishPagesLiveUnderPl() {
        #expect(SiteLinks.url("/", language: "pl").absoluteString == "https://captylo.com/pl/")
        #expect(SiteLinks.url("/kawa/", language: "pl").absoluteString == "https://captylo.com/pl/kawa/")
    }

    @Test func englishPagesLiveAtTheRoot() {
        #expect(SiteLinks.url("/", language: "en").absoluteString == "https://captylo.com/")
        #expect(SiteLinks.url("/kawa/", language: "en").absoluteString == "https://captylo.com/kawa/")
    }
}
