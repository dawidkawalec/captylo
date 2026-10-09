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
        for name in ["local", "whisper", "parakeet"] {
            #expect(DebugCommand.parse(["app", "--transcribe", "/tmp/a.wav", "--engine", name])
                == .transcribe(url: url, ai: false, language: nil, engine: .local))
        }
        #expect(DebugCommand.parse(["app", "--transcribe", "/tmp/a.wav", "--engine", "cloud", "--ai"])
            == .transcribe(url: url, ai: true, language: nil, engine: .elevenLabs))
        #expect(DebugCommand.parse(["app", "--transcribe", "/tmp/a.wav", "--engine", "gpu"]) == nil)
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

    @Test func parsesBenchmark() {
        let audio = URL(filePath: "/tmp/sample.wav")
        #expect(DebugCommand.parse(["Captylo", "--benchmark", "/tmp/sample.wav"])
                == .benchmark(url: audio, reference: nil, language: nil))
        #expect(DebugCommand.parse(["Captylo", "--benchmark", "/tmp/sample.wav", "--reference", "/tmp/ref.txt", "--language", "pl"])
                == .benchmark(url: audio, reference: URL(filePath: "/tmp/ref.txt"), language: "pl"))
        #expect(DebugCommand.parse(["Captylo", "--benchmark", "/tmp/sample.wav", "--language", "en"])
                == .benchmark(url: audio, reference: nil, language: "en"))
        #expect(DebugCommand.benchmark(url: audio, reference: nil, language: nil).isHeadless)
    }

    @Test func parsesRebuildSearchIndex() {
        #expect(DebugCommand.parse(["Captylo", "--rebuild-search-index"]) == .rebuildSearchIndex)
        #expect(DebugCommand.rebuildSearchIndex.isHeadless)
    }

    @Test func parsesMCP() {
        #expect(DebugCommand.parse(["/Applications/Captylo.app/Contents/MacOS/Captylo", "--mcp"]) == .mcp)
        #expect(DebugCommand.mcp.isHeadless)
    }

    /// `--mcp` never starts AppKit (no LaunchServices check-in that would swallow a later
    /// launch of the real app); everything else, other debug flags included, is the app.
    @Test func launchModeServesMCPOnlyForTheMCPFlag() {
        #expect(CaptyloMain.mode(for: ["/Applications/Captylo.app/Contents/MacOS/Captylo", "--mcp"]) == .mcpServer)
        #expect(CaptyloMain.mode(for: ["/Applications/Captylo.app/Contents/MacOS/Captylo"]) == .app)
        #expect(CaptyloMain.mode(for: ["Captylo", "--check"]) == .app)
        #expect(CaptyloMain.mode(for: ["Captylo", "--rebuild-search-index"]) == .app)
    }

    /// A script or an AI agent probing the binary with `--help` used to start a second full app.
    @Test func helpAndVersionNeverStartTheApp() {
        let binary = "/Applications/Captylo.app/Contents/MacOS/Captylo"
        #expect(CaptyloMain.mode(for: [binary, "--help"]) == .help)
        #expect(CaptyloMain.mode(for: [binary, "-h"]) == .help)
        #expect(CaptyloMain.mode(for: [binary, "--version"]) == .version)
        #expect(CaptyloMain.mode(for: [binary, "--mcp", "--help"]) == .mcpServer)
        #expect(CaptyloMain.usage.contains("--mcp"))
    }

    /// Only a plain launch hands off to a running Captylo; debug commands and the test host never do.
    @Test func onlyAPlainLaunchHandsOffToARunningCopy() {
        let binary = "/Applications/Captylo.app/Contents/MacOS/Captylo"
        #expect(CaptyloMain.handsOffToRunningCopy(arguments: [binary], isTestHost: false))
        #expect(CaptyloMain.handsOffToRunningCopy(arguments: [binary, "--open-section", "historia"], isTestHost: false))
        #expect(!CaptyloMain.handsOffToRunningCopy(arguments: [binary, "--check"], isTestHost: false))
        #expect(!CaptyloMain.handsOffToRunningCopy(arguments: [binary, "--design-preview"], isTestHost: false))
        #expect(!CaptyloMain.handsOffToRunningCopy(arguments: [binary], isTestHost: true))
    }

    /// The copy a relaunch replaces quits right after, so it never counts as already running.
    @Test func singleInstanceSkipsItselfAndTheReplacedCopy() {
        #expect(SingleInstance.instanceToActivate(currentPID: 10, replacedPID: nil, running: [10]) == nil)
        #expect(SingleInstance.instanceToActivate(currentPID: 10, replacedPID: nil, running: [7, 10]) == 7)
        #expect(SingleInstance.instanceToActivate(currentPID: 10, replacedPID: 7, running: [7, 10]) == nil)
        #expect(SingleInstance.instanceToActivate(currentPID: 10, replacedPID: 7, running: [7, 8, 10]) == 8)
    }

    @Test func benchmarkRejectsMissingValues() {
        #expect(DebugCommand.parse(["Captylo", "--benchmark"]) == nil)
        #expect(DebugCommand.parse(["Captylo", "--benchmark", "--language", "pl"]) == nil)
        #expect(DebugCommand.parse(["Captylo", "--benchmark", "/tmp/sample.wav", "--reference"]) == nil)
        #expect(DebugCommand.parse(["Captylo", "--benchmark", "/tmp/sample.wav", "--reference", "--language", "pl"]) == nil)
        #expect(DebugCommand.parse(["Captylo", "--benchmark", "/tmp/sample.wav", "--language"]) == nil)
    }

    @Test func benchmarkExpandsTilde() {
        guard case .benchmark(let url, let reference, _) = DebugCommand.parse(["app", "--benchmark", "~/sample.m4a", "--reference", "~/sample.txt"]) else {
            Issue.record("expected benchmark")
            return
        }
        #expect(url.lastPathComponent == "sample.m4a")
        #expect(reference?.lastPathComponent == "sample.txt")
        #expect(!url.path.contains("~"))
        #expect(reference.map { !$0.path.contains("~") } == true)
    }

    @Test func ignoresUnknownArgumentsAndPlainLaunches() {
        #expect(DebugCommand.parse(["app"]) == nil)
        #expect(DebugCommand.parse([]) == nil)
        #expect(DebugCommand.parse(["app", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        #expect(DebugCommand.parse(["app", "-NSDocumentRevisionsDebugMode", "YES", "--check"]) == .check)
    }
}
