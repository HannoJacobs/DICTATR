import XCTest
@testable import DICTATR

final class InputDevicePrecedenceTests: XCTestCase {
    private func preference(uid: String, name: String) -> InputDevicePreference {
        InputDevicePreference(uid: uid, name: name)
    }

    private func candidate(uid: String, name: String) -> CaptureDeviceSelection.Candidate {
        CaptureDeviceSelection.Candidate(uniqueID: uid, localizedName: name)
    }

    func testResolvePrefersFirstAvailablePreference() {
        let preferences = [
            preference(uid: "offline-usb", name: "USB Mic"),
            preference(uid: "airpods-input", name: "AirPods"),
            preference(uid: "builtin", name: "MacBook Mic")
        ]
        let available = [
            candidate(uid: "airpods-input", name: "AirPods"),
            candidate(uid: "builtin", name: "MacBook Mic")
        ]

        let resolution = InputDevicePrecedence.resolve(
            preferences: preferences,
            available: available,
            systemDefaultUID: "builtin"
        )

        XCTAssertEqual(resolution?.device.uniqueID, "airpods-input")
        XCTAssertEqual(resolution?.source, .preferenceMatch)
        XCTAssertEqual(resolution?.matchedPreferenceIndex, 1)
    }

    func testResolveFallsBackToSystemDefaultWhenNoPreferenceAvailable() {
        let preferences = [
            preference(uid: "offline-usb", name: "USB Mic")
        ]
        let available = [
            candidate(uid: "builtin", name: "MacBook Mic"),
            candidate(uid: "airpods-input", name: "AirPods")
        ]

        let resolution = InputDevicePrecedence.resolve(
            preferences: preferences,
            available: available,
            systemDefaultUID: "airpods-input"
        )

        XCTAssertEqual(resolution?.device.uniqueID, "airpods-input")
        XCTAssertEqual(resolution?.source, .systemDefault)
        XCTAssertNil(resolution?.matchedPreferenceIndex)
    }

    func testResolveFallsBackToFirstAvailableWhenSystemDefaultMissing() {
        let available = [
            candidate(uid: "builtin", name: "MacBook Mic")
        ]

        let resolution = InputDevicePrecedence.resolve(
            preferences: [],
            available: available,
            systemDefaultUID: "missing"
        )

        XCTAssertEqual(resolution?.device.uniqueID, "builtin")
        XCTAssertEqual(resolution?.source, .firstAvailable)
    }

    func testPinMovesDeviceToFrontAndDedupes() {
        let preferences = [
            preference(uid: "builtin", name: "MacBook Mic"),
            preference(uid: "usb", name: "USB Mic")
        ]

        let pinned = InputDevicePrecedence.pin(
            preference(uid: "usb", name: "USB Mic Pro"),
            in: preferences
        )

        XCTAssertEqual(pinned.map(\.uid), ["usb", "builtin"])
        XCTAssertEqual(pinned.first?.name, "USB Mic Pro")
    }

    func testEnsureRecordedAppendsNewDeviceWithoutReordering() {
        let preferences = [
            preference(uid: "usb", name: "USB Mic")
        ]

        let updated = InputDevicePrecedence.ensureRecorded(
            preference(uid: "builtin", name: "MacBook Mic"),
            in: preferences
        )

        XCTAssertEqual(updated.map(\.uid), ["usb", "builtin"])
    }

    func testEnsureRecordedUpdatesNameWithoutReordering() {
        let preferences = [
            preference(uid: "usb", name: "USB Mic"),
            preference(uid: "builtin", name: "MacBook Mic")
        ]

        let updated = InputDevicePrecedence.ensureRecorded(
            preference(uid: "usb", name: "USB Mic Pro"),
            in: preferences
        )

        XCTAssertEqual(updated.map(\.uid), ["usb", "builtin"])
        XCTAssertEqual(updated.first?.name, "USB Mic Pro")
    }

    func testMoveUpAndDownReorderPreferences() {
        let preferences = [
            preference(uid: "a", name: "A"),
            preference(uid: "b", name: "B"),
            preference(uid: "c", name: "C")
        ]

        XCTAssertEqual(
            InputDevicePrecedence.moveUp(uid: "c", in: preferences).map(\.uid),
            ["a", "c", "b"]
        )
        XCTAssertEqual(
            InputDevicePrecedence.moveDown(uid: "a", in: preferences).map(\.uid),
            ["b", "a", "c"]
        )
        XCTAssertEqual(
            InputDevicePrecedence.moveUp(uid: "a", in: preferences).map(\.uid),
            ["a", "b", "c"]
        )
        XCTAssertEqual(
            InputDevicePrecedence.moveDown(uid: "c", in: preferences).map(\.uid),
            ["a", "b", "c"]
        )
    }

    func testRemoveDropsMatchingUID() {
        let preferences = [
            preference(uid: "a", name: "A"),
            preference(uid: "b", name: "B")
        ]

        XCTAssertEqual(
            InputDevicePrecedence.remove(uid: "a", from: preferences).map(\.uid),
            ["b"]
        )
    }

    func testReadWriteRoundTrip() {
        let suiteName = "DICTATR.InputDevicePrecedenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = [
            preference(uid: "usb", name: "USB Mic"),
            preference(uid: "airpods", name: "AirPods")
        ]
        InputDevicePrecedence.write(preferences, to: defaults)

        XCTAssertEqual(InputDevicePrecedence.read(from: defaults), preferences)
    }

    func testReadReturnsEmptyWhenMissingOrCorrupt() {
        let suiteName = "DICTATR.InputDevicePrecedenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(InputDevicePrecedence.read(from: defaults), [])

        defaults.set(Data("not-json".utf8), forKey: InputDevicePrecedence.defaultsKey)
        XCTAssertEqual(InputDevicePrecedence.read(from: defaults), [])
    }
}
