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

    @Test func shortPasteRetypedIsNotGone() {
        // One misheard word replaced as a whole is a fix, not the text leaving the field.
        #expect(!EditWatcher.isGone("Supabase", delivered: "supa bejs"))
        #expect(EditWatcher.isGone("", delivered: "supa bejs"))
    }

    @Test func voiceFixNeedsASelectionInsideTheEarlierPaste() throws {
        let delivered = "wrzucam to na supa bejs w piątek."
        let value = "Hej, " + delivered + " Pa"
        let text = value as NSString
        let anchor = EditSpan.anchor(in: value, paste: text.range(of: delivered))
        let selected = text.range(of: "supa bejs")
        #expect(EditWatcher.selectionInsidePaste(value: value, selection: selected, anchor: anchor) == "supa bejs")
        // Outside the paste, nothing selected, too many words, or a range past the end.
        #expect(EditWatcher.selectionInsidePaste(value: value, selection: text.range(of: "Hej"), anchor: anchor) == nil)
        #expect(EditWatcher.selectionInsidePaste(value: value, selection: NSRange(location: 10, length: 0), anchor: anchor) == nil)
        #expect(EditWatcher.selectionInsidePaste(value: value, selection: text.range(of: "to na supa bejs"), anchor: anchor) == nil)
        #expect(EditWatcher.selectionInsidePaste(value: value, selection: nil, anchor: anchor) == nil)
        #expect(EditWatcher.selectionInsidePaste(value: value, selection: NSRange(location: text.length - 1, length: 5), anchor: anchor) == nil)
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
