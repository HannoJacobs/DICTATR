import XCTest
@testable import DICTATR

final class WhisperModelChoiceTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "DICTATR.WhisperModelChoiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testCatalogHasExactlyTwoCasesWithExactRawValues() {
        XCTAssertEqual(WhisperModelChoice.allCases.count, 2)
        XCTAssertEqual(
            WhisperModelChoice.allCases.map(\.rawValue),
            [
                "openai_whisper-small.en",
                "openai_whisper-large-v3-v20240930_626MB"
            ]
        )
    }

    func testCanonicalDefaultsKeyAndDefaultChoice() {
        XCTAssertEqual(WhisperModelChoice.defaultsKey, "selectedWhisperModelVariant")
        XCTAssertEqual(WhisperModelChoice.defaultChoice, .smallEnglish)
        XCTAssertEqual(WhisperModelChoice.defaultChoice.rawValue, "openai_whisper-small.en")
    }

    func testResolveMissingOrInvalidStorageToSmall() {
        XCTAssertEqual(WhisperModelChoice.resolve(stored: nil), .smallEnglish)
        XCTAssertEqual(WhisperModelChoice.resolve(stored: ""), .smallEnglish)
        XCTAssertEqual(WhisperModelChoice.resolve(stored: "openai_whisper-large-v3-turbo"), .smallEnglish)
        XCTAssertEqual(WhisperModelChoice.resolve(stored: "garbage"), .smallEnglish)
    }

    func testResolveExactRawValues() {
        XCTAssertEqual(WhisperModelChoice.resolve(stored: "openai_whisper-small.en"), .smallEnglish)
        XCTAssertEqual(
            WhisperModelChoice.resolve(stored: "openai_whisper-large-v3-v20240930_626MB"),
            .largeV3_626MB
        )
    }

    func testUserDefaultsRoundTrip() {
        XCTAssertEqual(WhisperModelChoice.read(from: defaults), .smallEnglish)

        WhisperModelChoice.write(.largeV3_626MB, to: defaults)
        XCTAssertEqual(
            defaults.string(forKey: WhisperModelChoice.defaultsKey),
            WhisperModelChoice.largeV3_626MB.rawValue
        )
        XCTAssertEqual(WhisperModelChoice.read(from: defaults), .largeV3_626MB)

        WhisperModelChoice.write(.smallEnglish, to: defaults)
        XCTAssertEqual(WhisperModelChoice.read(from: defaults), .smallEnglish)
    }

    func testInvalidStoredDefaultsValueResolvesToSmall() {
        defaults.set("not-a-real-variant", forKey: WhisperModelChoice.defaultsKey)
        XCTAssertEqual(WhisperModelChoice.read(from: defaults), .smallEnglish)
    }

    func testTruthfulDisplayLabelsAndDetails() {
        XCTAssertEqual(WhisperModelChoice.smallEnglish.pickerLabel, "Whisper Small (English) — Default")
        XCTAssertEqual(WhisperModelChoice.largeV3_626MB.pickerLabel, "Whisper Large V3")

        XCTAssertTrue(WhisperModelChoice.smallEnglish.detailText.lowercased().contains("default"))
        XCTAssertTrue(WhisperModelChoice.largeV3_626MB.detailText.contains("626"))
        XCTAssertTrue(WhisperModelChoice.largeV3_626MB.detailText.lowercased().contains("download"))
        XCTAssertTrue(WhisperModelChoice.largeV3_626MB.detailText.lowercased().contains("compile"))
    }
}
