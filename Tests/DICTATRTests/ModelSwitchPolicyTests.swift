import XCTest
@testable import DICTATR

final class ModelSwitchPolicyTests: XCTestCase {
    private func idleSnapshot() -> ModelSwitchPolicy.Snapshot {
        ModelSwitchPolicy.Snapshot(
            dictationState: .idle,
            isModelLoading: false,
            hasModelLoadTask: false,
            isModelSwitching: false,
            hasInFlightLocalTranscription: false,
            inFlightHTTPTranscriptions: 0,
            recordingStartInProgress: false,
            isRecorderRecording: false,
            recordingRecoveryPending: false
        )
    }

    func testCanEditSelectionOnlyWhenFullyIdle() {
        let idle = idleSnapshot()
        XCTAssertTrue(ModelSwitchPolicy.canEditSelection(idle))
        XCTAssertNil(ModelSwitchPolicy.blockedReason(idle))
    }

    func testCanStartRecordingWhenNoModelActivityExists() {
        XCTAssertTrue(ModelSwitchPolicy.canStartRecording(idleSnapshot()))
    }

    func testRecordingAdmissionBlockedDuringSwitchLoadAndPendingTask() {
        var snapshot = idleSnapshot()
        snapshot.isModelSwitching = true
        XCTAssertFalse(ModelSwitchPolicy.canStartRecording(snapshot))

        snapshot = idleSnapshot()
        snapshot.isModelLoading = true
        XCTAssertFalse(ModelSwitchPolicy.canStartRecording(snapshot))

        snapshot = idleSnapshot()
        snapshot.hasModelLoadTask = true
        XCTAssertFalse(ModelSwitchPolicy.canStartRecording(snapshot))
    }

    func testBlockedWhileRecording() {
        var snapshot = idleSnapshot()
        snapshot.dictationState = .recording
        XCTAssertFalse(ModelSwitchPolicy.canEditSelection(snapshot))
        XCTAssertEqual(ModelSwitchPolicy.blockedReason(snapshot), .recording)
    }

    func testBlockedWhileRecorderStillRecording() {
        var snapshot = idleSnapshot()
        snapshot.isRecorderRecording = true
        XCTAssertFalse(ModelSwitchPolicy.canEditSelection(snapshot))
        XCTAssertEqual(ModelSwitchPolicy.blockedReason(snapshot), .recording)
    }

    func testBlockedWhileTranscribing() {
        var snapshot = idleSnapshot()
        snapshot.dictationState = .transcribing
        XCTAssertFalse(ModelSwitchPolicy.canEditSelection(snapshot))
        XCTAssertEqual(ModelSwitchPolicy.blockedReason(snapshot), .transcribing)
    }

    func testBlockedWhileModelLoading() {
        var snapshot = idleSnapshot()
        snapshot.isModelLoading = true
        XCTAssertFalse(ModelSwitchPolicy.canEditSelection(snapshot))
        XCTAssertEqual(ModelSwitchPolicy.blockedReason(snapshot), .modelLoading)
    }

    func testBlockedWhileModelTaskExistsBeforeEngineReportsLoading() {
        var snapshot = idleSnapshot()
        snapshot.hasModelLoadTask = true
        XCTAssertFalse(ModelSwitchPolicy.canEditSelection(snapshot))
        XCTAssertEqual(ModelSwitchPolicy.blockedReason(snapshot), .modelLoading)
    }

    func testBlockedWhileModelSwitching() {
        var snapshot = idleSnapshot()
        snapshot.isModelSwitching = true
        XCTAssertFalse(ModelSwitchPolicy.canEditSelection(snapshot))
        XCTAssertEqual(ModelSwitchPolicy.blockedReason(snapshot), .modelSwitching)
    }

    func testBlockedWhileLocalTranscriptionInFlight() {
        var snapshot = idleSnapshot()
        snapshot.hasInFlightLocalTranscription = true
        XCTAssertFalse(ModelSwitchPolicy.canEditSelection(snapshot))
        XCTAssertEqual(ModelSwitchPolicy.blockedReason(snapshot), .localTranscription)
    }

    func testBlockedWhileHTTPTranscriptionInFlight() {
        var snapshot = idleSnapshot()
        snapshot.inFlightHTTPTranscriptions = 1
        XCTAssertFalse(ModelSwitchPolicy.canEditSelection(snapshot))
        XCTAssertEqual(ModelSwitchPolicy.blockedReason(snapshot), .httpTranscription)
    }

    func testBlockedWhileRecordingStartInProgress() {
        var snapshot = idleSnapshot()
        snapshot.recordingStartInProgress = true
        XCTAssertFalse(ModelSwitchPolicy.canEditSelection(snapshot))
        XCTAssertEqual(ModelSwitchPolicy.blockedReason(snapshot), .recordingStart)
    }

    func testBlockedWhileRecordingRecoveryPending() {
        var snapshot = idleSnapshot()
        snapshot.recordingRecoveryPending = true
        XCTAssertFalse(ModelSwitchPolicy.canEditSelection(snapshot))
        XCTAssertEqual(ModelSwitchPolicy.blockedReason(snapshot), .recordingRecovery)
    }

    func testShouldReloadWhenActiveDoesNotMatchSelected() {
        XCTAssertFalse(
            ModelSwitchPolicy.shouldReload(
                selected: .smallEnglish,
                activeVariant: WhisperModelChoice.smallEnglish.rawValue
            )
        )
        XCTAssertTrue(
            ModelSwitchPolicy.shouldReload(
                selected: .largeV3_626MB,
                activeVariant: WhisperModelChoice.smallEnglish.rawValue
            )
        )
        XCTAssertTrue(
            ModelSwitchPolicy.shouldReload(
                selected: .smallEnglish,
                activeVariant: nil
            )
        )
    }
}
