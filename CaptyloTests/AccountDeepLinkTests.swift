import Foundation
import Testing
@testable import Captylo

struct AccountDeepLinkTests {
    private func kind(_ text: String) -> DeepLinkKind? {
        AccountStore.deepLinkKind(URL(string: text)!)
    }

    @Test func checkoutAndPortalReturnsAreRecognised() {
        #expect(kind("captylo://pro/done") == .proDone)
        #expect(kind("captylo://pro/done/") == .proDone)
        #expect(kind("captylo://pro/done?from=app") == .proDone)
        #expect(kind("CAPTYLO://PRO/done") == .proDone)
        #expect(kind("captylo://account/refresh") == .refresh)
        #expect(kind("captylo://account/refresh/") == .refresh)
    }

    @Test func anythingElseIsNotOurs() {
        #expect(kind("captylo://pro") == nil)
        #expect(kind("captylo://pro/cancel") == nil)
        #expect(kind("captylo://account") == nil)
        #expect(kind("captylo://account/refresh/now") == nil)
        #expect(kind("https://captylo.com/pro/done") == nil)
        #expect(kind("captylo:pro/done") == nil)
        #expect(kind("file:///Users/anna/nagranie.m4a") == nil)
    }
}
