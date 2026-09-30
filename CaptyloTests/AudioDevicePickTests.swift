import Testing
@testable import Captylo

struct AudioDevicePickTests {
    typealias Input = AudioDevices.Input

    private let builtIn = Input(id: 10, uid: "BuiltInMicrophoneDevice", modelUID: "Digital Mic", name: "Mikrofon (MacBook Pro)", isBuiltIn: true)
    private let usb = Input(id: 20, uid: "AppleUSBAudioEngine:1:port1", modelUID: "USB Audio", name: "USB Mic", isBuiltIn: false)
    private let usbOtherPort = Input(id: 21, uid: "AppleUSBAudioEngine:1:port2", modelUID: "USB Audio", name: "USB Mic", isBuiltIn: false)
    private let headset = Input(id: 30, uid: "BT-Headset", modelUID: "BT Model", name: "Headset", isBuiltIn: false)

    @Test func systemDefaultFollowsTheDefaultUID() {
        let picked = AudioDevices.pick(
            selection: .systemDefault, inputs: [builtIn, usb, headset], defaultUID: headset.uid, lidClosed: false)
        #expect(picked == headset)
    }

    @Test func systemDefaultWithoutDefaultPrefersBuiltIn() {
        let picked = AudioDevices.pick(
            selection: .systemDefault, inputs: [usb, builtIn], defaultUID: nil, lidClosed: false)
        #expect(picked == builtIn)
    }

    @Test func exactUIDWins() {
        let picked = AudioDevices.pick(
            selection: .device(uid: usb.uid, modelUID: usb.modelUID),
            inputs: [builtIn, usbOtherPort, usb], defaultUID: builtIn.uid, lidClosed: false)
        #expect(picked == usb)
    }

    @Test func sameModelUIDMatchesWhenTheUIDChanged() {
        let picked = AudioDevices.pick(
            selection: .device(uid: "AppleUSBAudioEngine:1:port9", modelUID: "USB Audio"),
            inputs: [builtIn, usbOtherPort], defaultUID: builtIn.uid, lidClosed: false)
        #expect(picked == usbOtherPort)
    }

    @Test func missingDeviceFallsBackToTheDefault() {
        let picked = AudioDevices.pick(
            selection: .device(uid: "gone", modelUID: "gone model"),
            inputs: [builtIn, headset], defaultUID: headset.uid, lidClosed: false)
        #expect(picked == headset)
    }

    @Test func lidClosedExcludesBuiltInAndPrefersExternal() {
        let selectedBuiltIn = AudioDevices.pick(
            selection: .device(uid: builtIn.uid, modelUID: builtIn.modelUID),
            inputs: [builtIn, usb], defaultUID: builtIn.uid, lidClosed: true)
        #expect(selectedBuiltIn == usb)

        let systemDefault = AudioDevices.pick(
            selection: .systemDefault, inputs: [builtIn, headset], defaultUID: builtIn.uid, lidClosed: true)
        #expect(systemDefault == headset)
    }

    @Test func lidClosedWithOnlyBuiltInReturnsNil() {
        let picked = AudioDevices.pick(
            selection: .systemDefault, inputs: [builtIn], defaultUID: builtIn.uid, lidClosed: true)
        #expect(picked == nil)
    }

    @Test func lidOpenWithOnlyBuiltInStillWorks() {
        let picked = AudioDevices.pick(
            selection: .systemDefault, inputs: [builtIn], defaultUID: nil, lidClosed: false)
        #expect(picked == builtIn)
    }

    @Test func noInputsReturnsNil() {
        #expect(AudioDevices.pick(selection: .systemDefault, inputs: [], defaultUID: "x", lidClosed: false) == nil)
    }
}
