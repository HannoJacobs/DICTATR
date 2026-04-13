import XCTest
@testable import DICTATR

final class RecordingBackendTests: XCTestCase {
    func testBluetoothGraphMismatchDeclinesTapInstall() {
        let decision = RecordingStartupGate.tapInstallDecision(
            routeInvolvesBluetooth: true,
            inputFormat: AudioGraphFormatSnapshot(sampleRate: 24_000, channelCount: 1),
            outputFormat: AudioGraphFormatSnapshot(sampleRate: 48_000, channelCount: 1)
        )

        XCTAssertFalse(decision.shouldInstallTap)
        XCTAssertEqual(decision.reason, .bluetoothGraphMismatch)
    }

    func testBuiltInMatchingGraphAllowsTapInstall() {
        let decision = RecordingStartupGate.tapInstallDecision(
            routeInvolvesBluetooth: false,
            inputFormat: AudioGraphFormatSnapshot(sampleRate: 48_000, channelCount: 1),
            outputFormat: AudioGraphFormatSnapshot(sampleRate: 48_000, channelCount: 1)
        )

        XCTAssertTrue(decision.shouldInstallTap)
        XCTAssertEqual(decision.reason, .readyLiveGraph)
    }

    func testBluetoothMatchingGraphAllowsTapInstall() {
        let decision = RecordingStartupGate.tapInstallDecision(
            routeInvolvesBluetooth: true,
            inputFormat: AudioGraphFormatSnapshot(sampleRate: 24_000, channelCount: 1),
            outputFormat: AudioGraphFormatSnapshot(sampleRate: 24_000, channelCount: 1)
        )

        XCTAssertTrue(decision.shouldInstallTap)
        XCTAssertEqual(decision.reason, .readyLiveGraph)
    }

    func testRouteQuietAloneDoesNotSatisfyRetrySuccessGate() {
        let satisfied = RecordingStartupGate.retrySuccessGateSatisfied(
            lastObservedRouteChangeMsAgo: 30_000,
            graphReady: false,
            firstTapSeen: false
        )

        XCTAssertFalse(satisfied)
    }

    func testStartupDeadlineFailsWhenNoGraphReadinessOrFirstTapExists() {
        let shouldFail = RecordingStartupGate.startupDeadlineShouldFail(
            lastObservedRouteChangeMsAgo: 30_000,
            graphReady: false,
            firstTapSeen: false
        )

        XCTAssertTrue(shouldFail)
    }

    func testStartupDeadlinePassesWhenFirstTapHasArrived() {
        let shouldFail = RecordingStartupGate.startupDeadlineShouldFail(
            lastObservedRouteChangeMsAgo: 0,
            graphReady: false,
            firstTapSeen: true
        )

        XCTAssertFalse(shouldFail)
    }
}
