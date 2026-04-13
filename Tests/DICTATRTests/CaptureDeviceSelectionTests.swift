import XCTest
@testable import DICTATR

final class CaptureDeviceSelectionTests: XCTestCase {
    func testResolveReturnsExactUIDMatch() {
        let candidates = [
            CaptureDeviceSelection.Candidate(uniqueID: "BuiltInMicrophoneDevice", localizedName: "MacBook Pro Microphone"),
            CaptureDeviceSelection.Candidate(uniqueID: "78-2B-64-A0-C8-6A:input", localizedName: "Bose QC45")
        ]

        let selected = CaptureDeviceSelection.resolve(
            expectedInputUID: "78-2B-64-A0-C8-6A:input",
            candidates: candidates
        )

        XCTAssertEqual(selected?.uniqueID, "78-2B-64-A0-C8-6A:input")
        XCTAssertEqual(selected?.localizedName, "Bose QC45")
    }

    func testResolveReturnsNilWhenUIDMissing() {
        let candidates = [
            CaptureDeviceSelection.Candidate(uniqueID: "BuiltInMicrophoneDevice", localizedName: "MacBook Pro Microphone")
        ]

        let selected = CaptureDeviceSelection.resolve(
            expectedInputUID: "missing-device",
            candidates: candidates
        )

        XCTAssertNil(selected)
    }
}
