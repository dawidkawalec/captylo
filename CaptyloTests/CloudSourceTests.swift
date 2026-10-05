import Testing
@testable import Captylo

/// `CloudSource`: what "Podstawowe" in Modele says runs the cloud or the AI, the same rule as
/// `CloudRouter` (Pro with the Captylo choice or without an own key = Captylo, else the own key).
struct CloudSourceTests {
    @Test func proRunsOnCaptyloUnlessTheOwnKeyIsChosen() {
        #expect(CloudSource(isPro: true, prefersCaptylo: true, hasOwnKey: true).kind == .captylo)
        #expect(CloudSource(isPro: true, prefersCaptylo: true, hasOwnKey: false).kind == .captylo)
        #expect(CloudSource(isPro: true, prefersCaptylo: false, hasOwnKey: false).kind == .captylo)
        #expect(CloudSource(isPro: true, prefersCaptylo: false, hasOwnKey: true).kind == .ownKey)
    }

    @Test func freeRunsOnTheOwnKeyOrNothing() {
        #expect(CloudSource(isPro: false, prefersCaptylo: true, hasOwnKey: true).kind == .ownKey)
        #expect(CloudSource(isPro: false, prefersCaptylo: false, hasOwnKey: true).kind == .ownKey)
        #expect(CloudSource(isPro: false, prefersCaptylo: true, hasOwnKey: false).kind == .none)
    }
}
