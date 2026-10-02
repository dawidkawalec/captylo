import Foundation
import Testing
@testable import Captylo

struct DebugCommandTests {
    @Test func parsesTranscribeWithOptions() {
        let command = DebugCommand.parse(["/Applications/Captylo.app/Contents/MacOS/Captylo", "--transcribe", "/tmp/a.wav", "--ai", "--language", "pl"])
        #expect(command == .transcribe(url: URL(fileURLWithPath: "/tmp/a.wav"), ai: true, language: "pl"))
    }

    @Test func parsesTranscribeWithDefaults() {
        let command = DebugCommand.parse(["app", "--transcribe", "~/Desktop/nagranie.m4a"])
        guard case .transcribe(let url, let ai, let language, let engine) = command else {
            Issue.record("expected transcribe")
            return
        }
        #expect(url.lastPathComponent == "nagranie.m4a")
        #expect(!url.path.contains("~"))
        #expect(ai == false)
        #expect(language == nil)
        #expect(engine == nil)
    }

    @Test func transcribeRequiresAPath() {
        #expect(DebugCommand.parse(["app", "--transcribe"]) == nil)
        #expect(DebugCommand.parse(["app", "--transcribe", "--ai"]) == nil)
        #expect(DebugCommand.parse(["app", "--transcribe", "/tmp/a.wav", "--language"]) == nil)
    }

    @Test func parsesShowWidget() {
        #expect(DebugCommand.parse(["app", "--show-widget", "recording"]) == .showWidget(.recording))
        #expect(DebugCommand.parse(["app", "--show-widget", "transcribing"]) == .showWidget(.transcribing))
        #expect(DebugCommand.parse(["app", "--show-widget", "enhancing"]) == .showWidget(.enhancing))
        #expect(DebugCommand.parse(["app", "--show-widget", "idle"]) == nil)
        #expect(DebugCommand.parse(["app", "--show-widget"]) == nil)
    }

    @Test func parsesSimpleFlags() {
        #expect(DebugCommand.parse(["app", "--check"]) == .check)
        #expect(DebugCommand.parse(["app", "--reset-onboarding"]) == .resetOnboarding)
    }

    @Test func parsesTranscribeEngine() {
        let url = URL(fileURLWithPath: "/tmp/a.wav")
        #expect(DebugCommand.parse(["app", "--transcribe", "/tmp/a.wav", "--engine", "parakeet"])
            == .transcribe(url: url, ai: false, language: nil, engine: .parakeet))
        #expect(DebugCommand.parse(["app", "--transcribe", "/tmp/a.wav", "--engine", "cloud", "--ai"])
            == .transcribe(url: url, ai: true, language: nil, engine: .elevenLabs))
        #expect(DebugCommand.parse(["app", "--transcribe", "/tmp/a.wav", "--engine", "whisper"]) == nil)
        #expect(DebugCommand.parse(["app", "--transcribe", "/tmp/a.wav", "--engine"]) == nil)
    }

    @Test func parsesAXProbe() {
        #expect(DebugCommand.parse(["app", "--ax-probe"]) == .axProbe(showText: false))
        #expect(DebugCommand.parse(["app", "--ax-probe", "--show-text"]) == .axProbe(showText: true))
        #expect(DebugCommand.axProbe(showText: false).isHeadless)
    }

    @Test func parsesOpenSection() {
        #expect(DebugCommand.parse(["app", "--open-section", "historia"]) == .openSection(.historia))
        #expect(DebugCommand.parse(["app", "--open-section", "slownik"]) == .openSection(.slownik))
        #expect(DebugCommand.parse(["app", "--open-section", "Słownik"]) == .openSection(.slownik))
        #expect(DebugCommand.parse(["app", "--open-section", "USTAWIENIA"]) == .openSection(.ustawienia))
        #expect(DebugCommand.parse(["app", "--open-section", "spotkania"]) == .openSection(.spotkania))
        #expect(DebugCommand.parse(["app", "--open-section", "kuchnia"]) == nil)
        #expect(DebugCommand.parse(["app", "--open-section"]) == nil)
    }

    @Test func onlyOpenSectionRunsTheGUI() {
        #expect(DebugCommand.openSection(.modele).isHeadless == false)
        #expect(DebugCommand.check.isHeadless)
        #expect(DebugCommand.resetOnboarding.isHeadless)
        #expect(DebugCommand.showWidget(.recording).isHeadless)
        // Shows windows, but never starts services (no second hotkey tap next to a real Captylo).
        #expect(DebugCommand.designPreview("main-pulpit").isHeadless)
    }

    @Test func parsesDesignPreview() {
        #expect(DebugCommand.parse(["app", "--design-preview", "widget-compact"]) == .designPreview("widget-compact"))
        #expect(DebugCommand.parse(["app", "--design-preview", "Main-Pulpit"]) == .designPreview("main-pulpit"))
        #expect(DebugCommand.parse(["app", "-NSDocumentRevisionsDebugMode", "YES", "--design-preview", "glass-gallery"]) == .designPreview("glass-gallery"))
    }

    @Test func designPreviewWithoutTargetStillParses() {
        // A missing or unknown target must fail in the runner, never fall through to a GUI launch.
        #expect(DebugCommand.parse(["app", "--design-preview"]) == .designPreview(""))
        #expect(DebugCommand.parse(["app", "--design-preview", "--check"]) == .designPreview(""))
        #expect(DebugCommand.parse(["app", "--design-preview", "kuchnia"]) == .designPreview("kuchnia"))
    }

    @Test func parsesMeetingFromFiles() {
        #expect(DebugCommand.parse(["Captylo", "--meeting-from-files", "/tmp/me.wav", "/tmp/them.wav"])
                == .meetingFromFiles(me: URL(filePath: "/tmp/me.wav"), them: URL(filePath: "/tmp/them.wav")))
        #expect(DebugCommand.parse(["Captylo", "--meeting-from-files", "/tmp/me.wav"]) == nil)
        #expect(DebugCommand.parse(["Captylo", "--meeting-from-files"]) == nil)
        #expect(DebugCommand.parse(["Captylo", "--meeting-from-files", "/tmp/me.wav", "--check"]) == nil)
        #expect(DebugCommand.meetingFromFiles(me: URL(filePath: "/tmp/me.wav"), them: URL(filePath: "/tmp/them.wav")).isHeadless)
    }

    @Test func meetingFromFilesExpandsTilde() {
        guard case .meetingFromFiles(let me, let them) = DebugCommand.parse(["app", "--meeting-from-files", "~/me.wav", "~/them.m4a"]) else {
            Issue.record("expected meetingFromFiles")
            return
        }
        #expect(me.lastPathComponent == "me.wav")
        #expect(them.lastPathComponent == "them.m4a")
        #expect(!me.path.contains("~"))
        #expect(!them.path.contains("~"))
    }

    @Test func ignoresUnknownArgumentsAndPlainLaunches() {
        #expect(DebugCommand.parse(["app"]) == nil)
        #expect(DebugCommand.parse([]) == nil)
        #expect(DebugCommand.parse(["app", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        #expect(DebugCommand.parse(["app", "-NSDocumentRevisionsDebugMode", "YES", "--check"]) == .check)
    }
}
