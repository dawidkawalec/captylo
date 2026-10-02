import Foundation

/// Names the video call service behind an event's link: "Meet", "Zoom", "Teams", "Webex",
/// "Whereby", "Jitsi", "Discord", "Slack" (huddles) or "FaceTime". Only real links count (a
/// host with a known domain), never the words "Zoom" or "Teams" in a title or a note.
enum CallLinkDetector {
    private struct Service {
        let app: String
        /// The host itself or any subdomain of it.
        let domains: [String]
        /// A host label that marks the service wherever it is hosted ("jitsi.firma.pl").
        var hostLabel: String? = nil
        /// The path must contain this (lowercase) for the link to count.
        var pathContains: String? = nil
    }

    private static let services: [Service] = [
        Service(app: "Meet", domains: ["meet.google.com"]),
        Service(app: "Zoom", domains: ["zoom.us", "zoom.com"]),
        Service(app: "Teams", domains: ["teams.microsoft.com", "teams.live.com"]),
        Service(app: "Webex", domains: ["webex.com"]),
        Service(app: "Whereby", domains: ["whereby.com"]),
        Service(app: "Jitsi", domains: ["meet.jit.si"], hostLabel: "jitsi"),
        Service(app: "Discord", domains: ["discord.gg", "discord.com"]),
        Service(app: "Slack", domains: ["slack.com"], pathContains: "/huddle"),
        Service(app: "FaceTime", domains: ["facetime.apple.com"]),
    ]

    /// A link with or without a scheme: host (group 1) and path (group 2).
    private static let linkPattern = try? NSRegularExpression(
        pattern: #"(?:https?://)?((?:[a-z0-9-]+\.)+[a-z]{2,})(?::\d+)?(/[^\s<>"')\]]*)?"#,
        options: [.caseInsensitive]
    )

    /// The service of the first recognised link, looking at the URL, then the location, then
    /// the notes; nil when none of them holds a known link.
    static func app(url: URL?, location: String?, notes: String?) -> String? {
        for text in [url?.absoluteString, location, notes] {
            guard let text, !text.isEmpty, let app = app(inText: text) else { continue }
            return app
        }
        return nil
    }

    /// The service of the first recognised link in `text`, in reading order.
    static func app(inText text: String) -> String? {
        guard let linkPattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in linkPattern.matches(in: text, range: range) {
            guard let hostRange = Range(match.range(at: 1), in: text) else { continue }
            let host = text[hostRange].lowercased()
            let path = Range(match.range(at: 2), in: text).map { text[$0].lowercased() } ?? ""
            if let app = app(host: host, path: path) {
                return app
            }
        }
        return nil
    }

    private static func app(host: String, path: String) -> String? {
        let labels = host.split(separator: ".")
        for service in services {
            let byDomain = service.domains.contains { host == $0 || host.hasSuffix("." + $0) }
            let byLabel = service.hostLabel.map { label in labels.contains { $0 == label } } ?? false
            guard byDomain || byLabel else { continue }
            if let needle = service.pathContains, !path.contains(needle) { continue }
            return service.app
        }
        return nil
    }
}
