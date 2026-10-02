import Foundation
import Testing
@testable import Captylo

struct MeetingCallLinkTests {
    private func app(_ text: String) -> String? {
        CallLinkDetector.app(url: nil, location: nil, notes: text)
    }

    @Test func eachServiceIsRecognisedByItsDomain() {
        #expect(app("https://meet.google.com/abc-defg-hij") == "Meet")
        #expect(app("https://us02web.zoom.us/j/123456789?pwd=abc") == "Zoom")
        #expect(app("https://zoom.com/j/123") == "Zoom")
        #expect(app("https://teams.microsoft.com/l/meetup-join/19%3ameeting") == "Teams")
        #expect(app("https://teams.live.com/meet/9123") == "Teams")
        #expect(app("https://firma.webex.com/firma/j.php?MTID=m1") == "Webex")
        #expect(app("https://whereby.com/pokoj-zespolu") == "Whereby")
        #expect(app("https://meet.jit.si/PokojZespolu") == "Jitsi")
        #expect(app("https://jitsi.firma.pl/standup") == "Jitsi")
        #expect(app("https://discord.gg/abc123") == "Discord")
        #expect(app("https://discord.com/channels/1/2") == "Discord")
        #expect(app("https://app.slack.com/huddle/T123/C456") == "Slack")
        #expect(app("https://facetime.apple.com/join#v=1&p=abc") == "FaceTime")
    }

    @Test func theEventURLWinsThenTheLocationThenTheNotes() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")
        #expect(CallLinkDetector.app(url: url, location: "https://zoom.us/j/1", notes: "https://teams.microsoft.com/x") == "Meet")
        #expect(CallLinkDetector.app(url: nil, location: "https://zoom.us/j/1", notes: "https://teams.microsoft.com/x") == "Zoom")
        #expect(CallLinkDetector.app(url: nil, location: "Sala 3", notes: "Dołącz: https://teams.microsoft.com/l/x") == "Teams")
        #expect(CallLinkDetector.app(url: URL(string: "https://firma.pl/agenda"), location: nil, notes: "zoom.us/j/55") == "Zoom")
    }

    @Test func linksAreFoundInsideTextInAnyCase() {
        #expect(app("Spotkanie online: HTTPS://MEET.GOOGLE.COM/ABC-DEFG-HIJ, do zobaczenia") == "Meet")
        #expect(app("Link: <https://Us02Web.Zoom.Us/j/1>") == "Zoom")
        #expect(app("Wejście przez meet.google.com/xyz-abcd-efg (bez https)") == "Meet")
        #expect(app("Agenda\n1. Plan\n2. https://whereby.com/sala\n3. Pytania") == "Whereby")
    }

    @Test func plainWordsAndOtherDomainsAreNotLinks() {
        #expect(app("Zoom z klientem w sali 2") == nil)
        #expect(app("Rozmowa na Teams, link przyjdzie później") == nil)
        #expect(app("https://zoom.us.example.com/fake") == nil)
        #expect(app("https://notzoom.us/j/1") == nil)
        #expect(app("https://app.slack.com/client/T1/C2") == nil)
        #expect(app("https://meet.google.com.evil.pl/abc") == nil)
        #expect(app("") == nil)
        #expect(CallLinkDetector.app(url: nil, location: nil, notes: nil) == nil)
    }
}
