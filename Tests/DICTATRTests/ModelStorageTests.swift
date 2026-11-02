import XCTest
@testable import DICTATR

final class ModelStorageTests: XCTestCase {
    func testMigrationReusesDownloadsAndIsRepeatable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Documents/huggingface")
        let destination = root.appendingPathComponent("huggingface")
        let relativeFile = "models/argmaxinc/model/weights.bin"
        try FileManager.default.createDirectory(at: source.appendingPathComponent(relativeFile).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cached weights".utf8).write(to: source.appendingPathComponent(relativeFile))

        try ModelStorage.migrate(from: source, to: destination)
        try ModelStorage.migrate(from: source, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(relativeFile)), Data("cached weights".utf8))
    }

    func testMergePreservesConflictsAndMovesMissingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("old")
        let destination = root.appendingPathComponent("new")
        for directory in [source, destination] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("models"), withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: source.appendingPathComponent("models/shared"))
        try Data("new".utf8).write(to: destination.appendingPathComponent("models/shared"))
        try Data("tokenizer".utf8).write(to: source.appendingPathComponent("models/missing"))

        try ModelStorage.migrate(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("models/shared")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("models/shared")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("models/missing")), Data("tokenizer".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("models/missing").path))
    }
}
