import Foundation

/// SSE event received from server
public struct SSEEvent: Sendable {
    public let id: String?
    public let event: String?
    public let data: String
    public let retry: Int?

    public init(id: String? = nil, event: String? = nil, data: String, retry: Int? = nil) {
        self.id = id
        self.event = event
        self.data = data
        self.retry = retry
    }
}

/// Async stream of SSE events
public typealias SSEEventStream = AsyncThrowingStream<SSEEvent, Error>

/// Server-Sent Events client for streaming responses
/// Based on: https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events
public final class SSEClient: @unchecked Sendable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }

    /// Stream SSE events from the server
    /// - Returns: AsyncStream of SSEEvent
    public nonisolated func streamEvents() -> SSEEventStream {
        SSEEventStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            Task { @MainActor in
                do {
                    for try await event in await self.streamEventsAsync() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Stream events and decode as specific type
    /// - Parameter decoder: JSONDecoder for parsing event data
    /// - Returns: AsyncStream of decoded events
    public nonisolated func streamEvents<T: Decodable & Sendable>(decoder: JSONDecoder) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            Task { @MainActor in
                do {
                    for try await event in await self.streamEventsAsync() {
                        if !event.data.isEmpty, event.data != "[DONE]" {
                            if let data = event.data.data(using: .utf8),
                               let decoded = try? decoder.decode(T.self, from: data) {
                                continuation.yield(decoded)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Stream events from the Managed Agents events endpoint
    /// - Parameters:
    ///   - apiKey: API key for authentication
    ///   - sessionId: Session ID to stream events for
    ///   - baseURL: Base API URL
    /// - Returns: AsyncStream of session events
    public nonisolated static func streamSessionEvents(
        apiKey: String,
        sessionId: String,
        baseURL: URL = URL(string: "https://api.anthropic.com")!
    ) -> AsyncThrowingStream<SessionEvent, Error> {
        guard let url = URL(string: "/v1/sessions/\(sessionId)/events/stream", relativeTo: baseURL) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ManagedAgentsError.invalidURL("/v1/sessions/\(sessionId)/events/stream"))
            }
        }

        let headers: [String: String] = [
            "anthropic-version": "2023-06-01",
            "anthropic-beta": ManagedAgentsClient.betaHeader,
            "x-api-key": apiKey,
            "accept": "text/event-stream",
        ]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let client = SSEClient(url: url, headers: headers)
        return client.streamEvents(decoder: decoder)
    }

    /// Internal async method for streaming SSE events
    private func streamEventsAsync() -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var request = URLRequest(url: self.url)
                request.httpMethod = "GET"

                for (key, value) in self.headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }

                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = TimeInterval.infinity
                config.timeoutIntervalForResource = TimeInterval.infinity
                let session = URLSession(configuration: config)

                var buffer = Data()
                var lastEventId: String?
                var eventType: String?
                var eventData = ""
                var hasData = false

                let task = session.dataTask(with: request) { data, response, error in
                    if let error = error {
                        continuation.finish(throwing: error)
                        return
                    }

                    if let data = data {
                        buffer.append(data)
                        self.processSSEBuffer(
                            &buffer,
                            &lastEventId,
                            &eventType,
                            &eventData,
                            &hasData,
                            continuation: continuation
                        )
                    }

                    if hasData {
                        let event = SSEEvent(id: lastEventId, event: eventType, data: eventData, retry: nil)
                        continuation.yield(event)
                    }

                    continuation.finish()
                }
                task.resume()
            }
        }
    }

    private func processSSEBuffer(
        _ buffer: inout Data,
        _ lastEventId: inout String?,
        _ eventType: inout String?,
        _ eventData: inout String,
        _ hasData: inout Bool,
        continuation: SSEEventStream.Continuation
    ) {
        while let lineEnd = buffer.range(of: Data("\n".utf8)) {
            let lineData = buffer[..<lineEnd.lowerBound]
            buffer = buffer[lineEnd.upperBound...]

            guard let line = String(data: lineData, encoding: .utf8) else { continue }

            if line.isEmpty {
                if hasData {
                    let event = SSEEvent(id: lastEventId, event: eventType, data: eventData, retry: nil)
                    continuation.yield(event)
                    eventData = ""
                    hasData = false
                    lastEventId = nil
                    eventType = nil
                }
            } else if line.hasPrefix(":") && !line.hasPrefix(": ") {
                continue
            } else if let colonIndex = line.firstIndex(of: ":") {
                let field = String(line[..<colonIndex])
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

                switch field {
                case "id":
                    lastEventId = value
                case "event":
                    eventType = value
                case "data":
                    if hasData {
                        eventData += "\n"
                    }
                    eventData += value
                    hasData = true
                case "retry":
                    break
                default:
                    break
                }
            }
        }
    }
}

// MARK: - SSE Parsing Extensions

public extension SSEEvent {
    /// Parse event data as JSON
    func parseJSON<T: Decodable>(decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard let data = data.data(using: .utf8) else {
            throw SSEDecodeError.invalidData
        }
        return try decoder.decode(T.self, from: data)
    }

    /// Check if this is the end-of-stream marker
    var isDone: Bool {
        data == "[DONE]"
    }

    /// Parse delta content for streaming chat completions
    var deltaContent: String? {
        guard event == "message", !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
           let delta = json["delta"] as? [String: Any],
           let content = delta["content"] as? [String] {
            return content.first
        }
        return nil
    }
}

public enum SSEDecodeError: Error, LocalizedError {
    case invalidData
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Invalid data for SSE decoding"
        case .decodingFailed(let message):
            return "Failed to decode SSE data: \(message)"
        }
    }
}
