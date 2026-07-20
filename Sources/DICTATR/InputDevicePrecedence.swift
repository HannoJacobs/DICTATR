import Foundation

struct InputDevicePreference: Codable, Equatable, Identifiable, Sendable {
    let uid: String
    var name: String

    var id: String { uid }
}

enum InputDevicePrecedence {
    enum ResolutionSource: String, Equatable, Sendable {
        case preferenceMatch
        case systemDefault
        case firstAvailable
    }

    struct Resolution: Equatable, Sendable {
        let device: CaptureDeviceSelection.Candidate
        let source: ResolutionSource
        let matchedPreferenceIndex: Int?
    }

    static let defaultsKey = "inputDevicePrecedence"

    static func resolve(
        preferences: [InputDevicePreference],
        available: [CaptureDeviceSelection.Candidate],
        systemDefaultUID: String?
    ) -> Resolution? {
        for (index, preference) in preferences.enumerated() {
            if let match = candidate(uid: preference.uid, in: available) {
                return Resolution(
                    device: match,
                    source: .preferenceMatch,
                    matchedPreferenceIndex: index
                )
            }
        }

        if let systemDefaultUID,
           let match = candidate(uid: systemDefaultUID, in: available) {
            return Resolution(
                device: match,
                source: .systemDefault,
                matchedPreferenceIndex: nil
            )
        }

        guard let first = available.first else { return nil }
        return Resolution(
            device: first,
            source: .firstAvailable,
            matchedPreferenceIndex: nil
        )
    }

    static func pin(
        _ device: InputDevicePreference,
        in preferences: [InputDevicePreference]
    ) -> [InputDevicePreference] {
        var next = preferences.filter { $0.uid != device.uid }
        next.insert(device, at: 0)
        return next
    }

    static func ensureRecorded(
        _ device: InputDevicePreference,
        in preferences: [InputDevicePreference]
    ) -> [InputDevicePreference] {
        guard let index = preferences.firstIndex(where: { $0.uid == device.uid }) else {
            return preferences + [device]
        }
        var next = preferences
        next[index].name = device.name
        return next
    }

    static func moveUp(
        uid: String,
        in preferences: [InputDevicePreference]
    ) -> [InputDevicePreference] {
        move(uid: uid, by: -1, in: preferences)
    }

    static func moveDown(
        uid: String,
        in preferences: [InputDevicePreference]
    ) -> [InputDevicePreference] {
        move(uid: uid, by: 1, in: preferences)
    }

    static func remove(
        uid: String,
        from preferences: [InputDevicePreference]
    ) -> [InputDevicePreference] {
        preferences.filter { $0.uid != uid }
    }

    static func read(from defaults: UserDefaults = .standard) -> [InputDevicePreference] {
        guard let data = defaults.data(forKey: defaultsKey),
              let preferences = try? JSONDecoder().decode([InputDevicePreference].self, from: data)
        else {
            return []
        }
        return preferences
    }

    static func write(
        _ preferences: [InputDevicePreference],
        to defaults: UserDefaults = .standard
    ) {
        // Persistence failure must not crash capture; UI will re-seed from live devices.
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func snapshot(_ preferences: [InputDevicePreference]) -> String {
        guard !preferences.isEmpty else { return "none" }
        return preferences.enumerated().map { index, preference in
            "{\(index) uid=\(preference.uid) name=\(preference.name)}"
        }.joined(separator: " ")
    }

    private static func candidate(
        uid: String,
        in available: [CaptureDeviceSelection.Candidate]
    ) -> CaptureDeviceSelection.Candidate? {
        available.first { $0.uniqueID == uid }
    }

    private static func move(
        uid: String,
        by offset: Int,
        in preferences: [InputDevicePreference]
    ) -> [InputDevicePreference] {
        guard let index = preferences.firstIndex(where: { $0.uid == uid }) else {
            return preferences
        }
        let destination = index + offset
        guard preferences.indices.contains(destination) else {
            return preferences
        }
        var next = preferences
        next.swapAt(index, destination)
        return next
    }
}
