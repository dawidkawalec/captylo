import Foundation
import ServiceManagement
import Testing
@testable import Captylo

struct LaunchAtLoginTests {
    private let home = "/Users/someone"

    @Test func aCopyInApplicationsCanRegisterEvenWhenNotFound() {
        let url = URL(fileURLWithPath: "/Applications/Captylo.app")
        #expect(LaunchAtLogin.isUnavailable(status: .notFound, bundleURL: url, home: home) == false)
    }

    @Test func aCopyInTheUsersApplicationsCanRegisterToo() {
        let url = URL(fileURLWithPath: "/Users/someone/Applications/Captylo.app")
        #expect(LaunchAtLogin.isUnavailable(status: .notFound, bundleURL: url, home: home) == false)
    }

    @Test func buildFoldersAndTranslocatedCopiesStayUnavailable() {
        let paths = [
            "/Users/someone/Downloads/Captylo.app",
            "/Users/someone/code/captylo/.local-build/Build/Products/Debug/Captylo.app",
            "/private/var/folders/xy/T/AppTranslocation/1234/d/Captylo.app",
            "/Volumes/Captylo/Captylo.app",
        ]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            #expect(LaunchAtLogin.isUnavailable(status: .notFound, bundleURL: url, home: home), "\(path)")
        }
    }

    @Test func otherStatusesNeverBlockTheSwitch() {
        let url = URL(fileURLWithPath: "/Users/someone/Downloads/Captylo.app")
        for status in [SMAppService.Status.notRegistered, .enabled, .requiresApproval] {
            #expect(LaunchAtLogin.isUnavailable(status: status, bundleURL: url, home: home) == false)
        }
    }
}
