// LocalHTTPServer.swift
//
// Minimal HTTP server on localhost:9876 using Network.framework.
// Accepts POST /transcribe with raw audio bytes, returns transcribed text.
// Also responds to GET /ping with "pong" for health checks.
//
// Only listens on IPv4 loopback (127.0.0.1) — not accessible from outside the machine.
//
// DESIGN NOTES:
//   - Uses NWListener (Network.framework) — no external dependencies needed.
//   - The transcription closure is injected at init, so this class has no dependency
//     on TranscriptionEngine or WhisperKit directly.
//   - Each connection is handled independently; concurrent requests each get their own
//     temp file and Task. WhisperKit serializes internally if needed.
//   - HTTP parsing is minimal but sufficient for curl/programmatic clients.
//     We accumulate data until we have the full body (based on Content-Length header).

import Foundation
import Network
import os

final class LocalHTTPServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.dictatr", category: "HTTPServer")

    private var listener: NWListener?
    private let port: UInt16 = 9876
    private let transcribe: @Sendable (URL) async throws -> String

    /// - Parameter transcribe: Closure that takes an audio file URL and returns transcribed text.
    init(transcribe: @escaping @Sendable (URL) async throws -> String) {
        self.transcribe = transcribe
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )

        do {
            let listener = try NWListener(using: params)
            self.listener = listener

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    AppDiagnostics.info(.httpServer, "HTTP server listening on 127.0.0.1:\(self.port)")
                case .failed(let error):
                    AppDiagnostics.error(.httpServer, "HTTP server failed error=\(error.localizedDescription)")
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.start(queue: .global(qos: .utility))
        } catch {
            AppDiagnostics.error(.httpServer, "Failed to create HTTP listener error=\(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        AppDiagnostics.info(.httpServer, "HTTP server stopped")
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        receiveAllData(connection: connection, buffer: Data())
    }

    /// Accumulate data from the connection until we have a complete HTTP request.
    /// NWConnection.receive may deliver data in chunks, so we keep reading until
    /// we have the full body (determined by Content-Length) or the connection closes.
    private func receiveAllData(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            // Check if we have the header separator yet
            let headerSeparator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
            guard let separatorRange = accumulated.range(of: headerSeparator) else {
                if isComplete || error != nil {
                    // Connection closed before we got complete headers
                    Self.sendResponse(connection: connection, status: 400, body: "Bad Request: incomplete headers")
                    return
                }
                // Keep reading
                self.receiveAllData(connection: connection, buffer: accumulated)
                return
            }

            let headerData = accumulated[accumulated.startIndex..<separatorRange.lowerBound]
            let headerString = String(data: headerData, encoding: .utf8) ?? ""
            let bodyStartIndex = separatorRange.upperBound
            let currentBody = accumulated[bodyStartIndex...]

            // For GET requests (like /ping), no body needed
            if headerString.hasPrefix("GET ") {
                self.routeRequest(connection: connection, header: headerString, body: Data())
                return
            }

            // For POST, check Content-Length to know when we have the full body
            let contentLength = self.parseContentLength(from: headerString)
            if contentLength > 0, currentBody.count < contentLength {
                if isComplete || error != nil {
                    // Connection closed before full body received — process what we have
                    AppDiagnostics.warning(
                        .httpServer,
                        "Connection closed early bodyBytes=\(currentBody.count)/\(contentLength)"
                    )
                    self.routeRequest(connection: connection, header: headerString, body: Data(currentBody))
                    return
                }
                // Keep reading
                self.receiveAllData(connection: connection, buffer: accumulated)
                return
            }

            // We have enough data
            self.routeRequest(connection: connection, header: headerString, body: Data(currentBody))
        }
    }

    private func parseContentLength(from header: String) -> Int {
        for line in header.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    // MARK: - Routing

    private func routeRequest(connection: NWConnection, header: String, body: Data) {
        if header.hasPrefix("GET /ping") {
            Self.sendResponse(connection: connection, status: 200, body: "pong")
            return
        }

        if header.hasPrefix("POST /transcribe") {
            handleTranscribe(connection: connection, header: header, body: body)
            return
        }

        Self.sendResponse(connection: connection, status: 404, body: "Not Found")
    }

    // MARK: - Transcription endpoint

    private func handleTranscribe(connection: NWConnection, header: String, body: Data) {
        guard !body.isEmpty else {
            Self.sendResponse(connection: connection, status: 400, body: "Empty request body")
            return
        }

        // Detect format from Content-Type or default to wav
        let ext: String
        if header.lowercased().contains("audio/ogg") || header.lowercased().contains("application/ogg") {
            ext = "ogg"
        } else {
            ext = "wav"
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictatr_http_\(UUID().uuidString).\(ext)")

        do {
            try body.write(to: tempURL)
        } catch {
            AppDiagnostics.error(.httpServer, "Failed to write temp file error=\(error.localizedDescription)")
            Self.sendResponse(connection: connection, status: 500, body: "Failed to write temp file")
            return
        }

        AppDiagnostics.info(.httpServer, "Received transcription request bytes=\(body.count) ext=\(ext)")

        let transcribe = self.transcribe
        Task {
            defer { try? FileManager.default.removeItem(at: tempURL) }
            do {
                let text = try await transcribe(tempURL)
                Self.sendResponse(connection: connection, status: 200, body: text)
                AppDiagnostics.info(.httpServer, "Transcription served chars=\(text.count)")
            } catch {
                AppDiagnostics.error(.httpServer, "Transcription failed error=\(error.localizedDescription)")
                Self.sendResponse(connection: connection, status: 500, body: "Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - HTTP response

    private static func sendResponse(connection: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var responseData = header.data(using: .utf8)!
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
