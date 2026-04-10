import Darwin
import Foundation

struct AudioContentionKillResult {
    struct KilledProcess {
        let pid: Int32
        let description: String
    }

    let killed: [KilledProcess]
    let skipped: [String]
    let inspectionFailure: String?
}

enum AudioContentionReset {
    private struct ProcessSnapshot {
        let pid: Int32
        let parentPID: Int32
        let command: String
    }

    private struct Candidate {
        let helper: ProcessSnapshot
        let reason: String
    }

    private static let signatures: [(needle: String, reason: String)] = [
        ("--utility-sub-type=audio.mojom.AudioService", "Chromium/Electron audio service")
    ]

    static func killLikelyContenders(excluding excludedPIDs: Set<Int32>) -> AudioContentionKillResult {
        let candidates: [Candidate]
        let processTable: [Int32: ProcessSnapshot]
        do {
            let lookup = try findCandidates(excluding: excludedPIDs)
            candidates = lookup.candidates
            processTable = lookup.processTable
        } catch {
            return AudioContentionKillResult(
                killed: [],
                skipped: [],
                inspectionFailure: "Failed to inspect running processes: \(error.localizedDescription)"
            )
        }

        let targets = buildTargets(from: candidates, processTable: processTable, excluding: excludedPIDs)
        var killed: [AudioContentionKillResult.KilledProcess] = []
        var skipped: [String] = []

        for target in targets {
            let commandSummary = summarize(command: target.command)
            if kill(target.pid, SIGTERM) != 0 {
                skipped.append("pid=\(target.pid) reason=\(target.reason) signal=TERM errno=\(errno) command=\(commandSummary)")
                continue
            }

            usleep(250_000)
            if kill(target.pid, 0) == 0 {
                if kill(target.pid, SIGKILL) != 0 {
                    skipped.append("pid=\(target.pid) reason=\(target.reason) signal=KILL errno=\(errno) command=\(commandSummary)")
                    continue
                }
            }

            killed.append(.init(pid: target.pid, description: "\(target.reason) command=\(commandSummary)"))
        }

        return AudioContentionKillResult(killed: killed, skipped: skipped, inspectionFailure: nil)
    }

    private static func findCandidates(excluding excludedPIDs: Set<Int32>) throws -> (candidates: [Candidate], processTable: [Int32: ProcessSnapshot]) {
        let output = try runProcess(launchPath: "/bin/ps", arguments: ["-ax", "-o", "pid=,command="])
        let parentOutput = try runProcess(launchPath: "/bin/ps", arguments: ["-ax", "-o", "pid=,ppid=,command="])

        let processTable = parentOutput
            .split(separator: "\n")
            .compactMap { line -> ProcessSnapshot? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }

                let parts = trimmed.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard parts.count == 3,
                      let pid = Int32(parts[0]),
                      let parentPID = Int32(parts[1])
                else {
                    return nil
                }

                return ProcessSnapshot(pid: pid, parentPID: parentPID, command: String(parts[2]))
            }
            .reduce(into: [Int32: ProcessSnapshot]()) { partial, snapshot in
                partial[snapshot.pid] = snapshot
            }

        let candidates = output
            .split(separator: "\n")
            .compactMap { line -> Candidate? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }

                let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
                guard !excludedPIDs.contains(pid) else { return nil }

                let command = String(parts[1])
                guard let signature = signatures.first(where: { command.contains($0.needle) }) else {
                    return nil
                }

                guard let snapshot = processTable[pid] else { return nil }
                return Candidate(helper: snapshot, reason: signature.reason)
            }

        return (candidates, processTable)
    }

    private static func buildTargets(
        from candidates: [Candidate],
        processTable: [Int32: ProcessSnapshot],
        excluding excludedPIDs: Set<Int32>
    ) -> [ProcessSnapshotTarget] {
        var targets: [Int32: ProcessSnapshotTarget] = [:]

        for candidate in candidates {
            if let owner = processTable[candidate.helper.parentPID],
               owner.parentPID > 0,
               !excludedPIDs.contains(owner.pid),
               shouldKillOwningApp(for: owner.command)
            {
                let appName = extractAppName(from: owner.command) ?? "owner app"
                targets[owner.pid] = ProcessSnapshotTarget(
                    pid: owner.pid,
                    command: owner.command,
                    reason: "\(candidate.reason) owner=\(appName) helperPid=\(candidate.helper.pid)"
                )
            } else {
                targets[candidate.helper.pid] = ProcessSnapshotTarget(
                    pid: candidate.helper.pid,
                    command: candidate.helper.command,
                    reason: candidate.reason
                )
            }
        }

        return targets.values.sorted { $0.pid < $1.pid }
    }

    private static func shouldKillOwningApp(for command: String) -> Bool {
        command.contains(".app/Contents/MacOS/")
    }

    private static func extractAppName(from command: String) -> String? {
        guard let appRange = command.range(of: ".app/Contents/MacOS/") else { return nil }
        let prefix = command[..<appRange.lowerBound]
        guard let slash = prefix.lastIndex(of: "/") else { return nil }
        return String(prefix[prefix.index(after: slash)...])
    }

    private struct ProcessSnapshotTarget {
        let pid: Int32
        let command: String
        let reason: String
    }

    private static func runProcess(launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "AudioContentionReset",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "ps exited with status \(process.terminationStatus)" : message]
            )
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private static func summarize(command: String) -> String {
        if command.count <= 140 {
            return command
        }

        return String(command.prefix(140)) + "..."
    }
}
