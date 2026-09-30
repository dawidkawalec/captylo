import Foundation
import Testing
@testable import Captylo

struct LearningEditWatcherTests {
    @Test func offMainReturnsTheResultOfFastWork() async {
        let value = await EditWatcher.offMain(deadline: .seconds(2)) { 42 }
        #expect(value == 42)
    }

    @Test func sentChatMessageCountsAsGone() {
        let delivered = "Wrzucam to na supa bejs w piątek."
        #expect(EditWatcher.isGone("", delivered: delivered))
        #expect(EditWatcher.isGone(nil, delivered: delivered))
        #expect(EditWatcher.isGone("Zupełnie nowa wiadomość o czymś innym", delivered: delivered))
        #expect(!EditWatcher.isGone("Wrzucam to na Supabase w piątek.", delivered: delivered))
        #expect(!EditWatcher.isGone(delivered + " I jeszcze dopisałem długie zdanie na końcu wiadomości.", delivered: delivered))
    }

    @Test func offMainGivesUpAtTheDeadline() async {
        let clock = ContinuousClock()
        let started = clock.now
        let value = await EditWatcher.offMain(deadline: .milliseconds(50)) { () -> Int in
            Thread.sleep(forTimeInterval: 0.8)
            return 1
        }
        #expect(value == nil)
        #expect(clock.now - started < .milliseconds(500))
    }
}
