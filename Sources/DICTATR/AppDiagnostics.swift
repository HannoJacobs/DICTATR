import AppKit
import Darwin
import Foundation
import os

enum DiagnosticLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .default
        case .error:
            return .error
        }
    }
}

enum DiagnosticCategory: String {
    case lifecycle = "Lifecycle"
    case appState = "AppState"
    case transcriptionEngine = "TranscriptionEngine"
    case audioRecorder = "AudioRecorder"
    case httpServer = "HTTPServer"
    case pasteboard = "Pasteboard"
    case hotkey = "Hotkey"
    case database = "Database"
    case audioDevices = "AudioDevices"
    case forensics = "Forensics"
}

enum AppDiagnostics {
    private static let subsystem = "com.dictatr"
    private static let fileQueue = DispatchQueue(label: "com.dictatr.diagnostics.file", qos: .utility)
    private static let lifecycleLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.lifecycle.rawValue)
    private static let appStateLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.appState.rawValue)
    private static let transcriptionEngineLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.transcriptionEngine.rawValue)
    private static let audioRecorderLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.audioRecorder.rawValue)
    private static let httpServerLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.httpServer.rawValue)
    private static let pasteboardLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.pasteboard.rawValue)
    private static let hotkeyLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.hotkey.rawValue)
    private static let databaseLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.database.rawValue)
    private static let audioDevicesLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.audioDevices.rawValue)
    private static let forensicsLogger = Logger(subsystem: subsystem, category: DiagnosticCategory.forensics.rawValue)
    static let launchSessionID = String(UUID().uuidString.prefix(8)).lowercased()
    static let logFileURL = prepareLogFile()

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    static var buildVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? appVersion
    }

    static var logFilePath: String {
        logFileURL?.path ?? "unavailable"
    }

    static var runtimeSummary: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let bundlePath = Bundle.main.bundleURL.path
        let executablePath = Bundle.main.executableURL?.path ?? (CommandLine.arguments.first ?? "unknown")
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let osBuild = sysctlString("kern.osversion") ?? "unknown"
        let hwModel = sysctlString("hw.model") ?? "unknown"

        return [
            "version=\(appVersion)",
            "build=\(buildVersion)",
            "bundleID=\(bundleID)",
            "pid=\(ProcessInfo.processInfo.processIdentifier)",
            "os=\(osVersion)",
            "osBuild=\(osBuild)",
            "hwModel=\(hwModel)",
            "bundlePath=\(bundlePath)",
            "executablePath=\(executablePath)",
            "diagnosticsFile=\(logFilePath)"
        ].joined(separator: " ")
    }

    static var recordingVersionSummary: String {
        let bundlePath = Bundle.main.bundleURL.path
        return "version=\(appVersion) build=\(buildVersion) bundlePath=\(bundlePath)"
    }

    static func compactText(_ text: String, limit: Int = 500) -> String {
        let sanitized = text.replacingOccurrences(of: "\n", with: "\\n")
        guard sanitized.count > limit else { return sanitized }
        let prefix = sanitized.prefix(limit)
        return "\(prefix)…<truncated totalChars=\(sanitized.count)>"
    }

    static func quoted(_ text: String, limit: Int = 500) -> String {
        "\"\(compactText(text, limit: limit))\""
    }

    static func optionalQuoted(_ text: String?, limit: Int = 500) -> String {
        guard let text else { return "nil" }
        return quoted(text, limit: limit)
    }

    static func boolLabel(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    static func threadSummary() -> String {
        "thread=\(Thread.isMainThread ? "main" : "background")"
    }

    static func frontmostAppSummary() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "frontmostApp=none"
        }

        let bundleID = app.bundleIdentifier ?? "unknown"
        let name = app.localizedName ?? "unknown"
        return "frontmostApp={name=\(name) bundleID=\(bundleID) pid=\(app.processIdentifier)}"
    }

    static func debug(_ category: DiagnosticCategory, _ message: String) {
        emit(level: .debug, category: category, message: message)
    }

    static func info(_ category: DiagnosticCategory, _ message: String) {
        emit(level: .info, category: category, message: message)
    }

    static func warning(_ category: DiagnosticCategory, _ message: String) {
        emit(level: .warning, category: category, message: message)
    }

    static func error(_ category: DiagnosticCategory, _ message: String) {
        emit(level: .error, category: category, message: message)
    }

    private static func emit(level: DiagnosticLevel, category: DiagnosticCategory, message: String) {
        let sanitized = message.replacingOccurrences(of: "\n", with: " | ")
        logger(for: category).log(level: level.osLogType, "\(sanitized, privacy: .public)")

        guard let logFileURL else { return }

        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )
        let line = "\(timestamp) [\(level.rawValue)] [\(category.rawValue)] launchSession=\(launchSessionID) \(sanitized)\n"

        fileQueue.async {
            append(line: line, to: logFileURL)
        }
    }

    private static func logger(for category: DiagnosticCategory) -> Logger {
        switch category {
        case .lifecycle:
            return lifecycleLogger
        case .appState:
            return appStateLogger
        case .transcriptionEngine:
            return transcriptionEngineLogger
        case .audioRecorder:
            return audioRecorderLogger
        case .httpServer:
            return httpServerLogger
        case .pasteboard:
            return pasteboardLogger
        case .hotkey:
            return hotkeyLogger
        case .database:
            return databaseLogger
        case .audioDevices:
            return audioDevicesLogger
        case .forensics:
            return forensicsLogger
        }
    }

    private static func append(line: String, to url: URL) {
        guard let data = line.data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            lifecycleLogger.error("Failed to append diagnostics log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func prepareLogFile() -> URL? {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let logsDir = appSupport
            .appendingPathComponent("DICTATR", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)

        do {
            try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            lifecycleLogger.error("Failed to create diagnostics directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let filename = "dictatr-\(launchTimestamp())-\(launchSessionID).log"
        let logURL = logsDir.appendingPathComponent(filename)
        fileManager.createFile(atPath: logURL.path, contents: Data())

        let latestURL = logsDir.appendingPathComponent("latest.log")
        try? fileManager.removeItem(at: latestURL)
        try? fileManager.createSymbolicLink(at: latestURL, withDestinationURL: logURL)

        pruneOldLogs(in: logsDir, keeping: 40)
        return logURL
    }

    private static func pruneOldLogs(in logsDir: URL, keeping limit: Int) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let sessionLogs = urls
            .filter { $0.pathExtension == "log" && $0.lastPathComponent != "latest.log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard sessionLogs.count > limit else { return }

        for url in sessionLogs.prefix(sessionLogs.count - limit) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func launchTimestamp() -> String {
        let components = Calendar.current.dateComponents(in: .current, from: Date())
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        return String(cString: buffer)
    }
}
