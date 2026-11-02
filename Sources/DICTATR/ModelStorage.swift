import Foundation

enum ModelStorage {
    static var downloadBase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    /// Move existing downloads without overwriting files already in the new cache.
    /// Conflicting files stay in Documents so no user data is discarded.
    static func migrate(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return }
        guard manager.fileExists(atPath: destination.path) else {
            try manager.moveItem(at: source, to: destination)
            return
        }

        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let destinationValues = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true,
              destinationValues.isDirectory == true, destinationValues.isSymbolicLink != true else { return }

        for child in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try migrate(from: child, to: destination.appendingPathComponent(child.lastPathComponent))
        }
        if try manager.contentsOfDirectory(atPath: source.path).isEmpty {
            try manager.removeItem(at: source)
        }
    }
}
