import Foundation

/// Tool executor for agent operations
/// Handles: bash, read, write, edit, glob, grep, web_fetch, web_search
public actor ToolExecutor {
    private let workingDirectory: URL

    public init(workingDirectory: URL = URL(fileURLWithPath: ".")) {
        self.workingDirectory = workingDirectory
    }

    // MARK: - Tool Execution Entry Point

    public struct ToolInput {
        public let name: String
        public let arguments: [String: Any]

        public init(name: String, arguments: [String: Any]) {
            self.name = name
            self.arguments = arguments
        }
    }

    public struct ToolOutput: Sendable {
        public let content: String
        public let isError: Bool

        public init(content: String, isError: Bool = false) {
            self.content = content
            self.isError = isError
        }
    }

    public func execute(_ input: ToolInput) async throws -> ToolOutput {
        switch input.name {
        case "bash":
            return try await executeBash(input.arguments)
        case "read":
            return try await executeRead(input.arguments)
        case "write":
            return try await executeWrite(input.arguments)
        case "edit":
            return try await executeEdit(input.arguments)
        case "glob":
            return try await executeGlob(input.arguments)
        case "grep":
            return try await executeGrep(input.arguments)
        case "web_fetch":
            return try await executeWebFetch(input.arguments)
        case "web_search":
            return try await executeWebSearch(input.arguments)
        default:
            throw ToolExecutorError.unknownTool(input.name)
        }
    }

    // MARK: - Bash (Process)

    private func executeBash(_ args: [String: Any]) async throws -> ToolOutput {
        guard let command = args["command"] as? String else {
            throw ToolExecutorError.missingArgument("command")
        }

        let timeoutSeconds = (args["timeout"] as? Int).map { Double($0) } ?? 30.0

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Use Task to handle timeout
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                process.terminate()
            }

            process.terminationHandler = { process in
                timeoutTask.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: ToolOutput(content: stdout))
                } else {
                    let errorMsg = stderr.isEmpty ? "Command exited with status \(process.terminationStatus)" : stderr
                    continuation.resume(returning: ToolOutput(content: stdout + "\n" + errorMsg, isError: true))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ToolExecutorError.processError(error.localizedDescription))
            }
        }
    }

    // MARK: - Read (FileManager)

    private func executeRead(_ args: [String: Any]) async throws -> ToolOutput {
        guard let path = args["path"] as? String else {
            throw ToolExecutorError.missingArgument("path")
        }

        let url = resolvePath(path)
        let maxBytes = args["max_bytes"] as? Int

        do {
            if url.hasDirectoryPath {
                // List directory contents
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )

                var lines: [String] = []
                for item in contents.prefix(100) {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
                    let icon = isDir.boolValue ? "[DIR]" : "[FILE]"
                    lines.append("\(icon)\t\(item.lastPathComponent)")
                }

                let header = "Contents of \(url.path):\n"
                return ToolOutput(content: header + lines.joined(separator: "\n"))
            } else {
                // Read file
                let data: Data
                if let maxBytes = maxBytes {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    data = handle.readData(ofLength: maxBytes)
                } else {
                    data = try Data(contentsOf: url)
                }

                guard let content = String(data: data, encoding: .utf8) else {
                    throw ToolExecutorError.invalidEncoding
                }

                if let maxBytes = maxBytes, data.count >= maxBytes {
                    return ToolOutput(content: content + "\n\n[Truncated - file exceeds \(maxBytes) bytes]")
                }

                return ToolOutput(content: content)
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain {
            throw ToolExecutorError.fileNotFound(path)
        }
    }

    // MARK: - Write (FileManager)

    private func executeWrite(_ args: [String: Any]) async throws -> ToolOutput {
        guard let path = args["path"] as? String else {
            throw ToolExecutorError.missingArgument("path")
        }
        guard let content = args["content"] as? String else {
            throw ToolExecutorError.missingArgument("content")
        }

        let url = resolvePath(path)

        // Create parent directories if needed
        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolOutput(content: "Wrote \(content.utf8.count) bytes to \(path)")
        } catch {
            throw ToolExecutorError.writeError(error.localizedDescription)
        }
    }

    // MARK: - Edit (String.replace)

    private func executeEdit(_ args: [String: Any]) async throws -> ToolOutput {
        guard let path = args["path"] as? String else {
            throw ToolExecutorError.missingArgument("path")
        }
        guard let oldText = args["old_text"] as? String else {
            throw ToolExecutorError.missingArgument("old_text")
        }
        guard let newText = args["new_text"] as? String else {
            throw ToolExecutorError.missingArgument("new_text")
        }

        let url = resolvePath(path)

        do {
            var content = try String(contentsOf: url, encoding: .utf8)

            guard content.contains(oldText) else {
                throw ToolExecutorError.textNotFound(oldText)
            }

            let countBefore = content.components(separatedBy: oldText).count - 1
            content = content.replacingOccurrences(of: oldText, with: newText)

            try content.write(to: url, atomically: true, encoding: .utf8)

            return ToolOutput(content: "Replaced \(countBefore) occurrence(s) of '\(oldText.prefix(50))...' with '\(newText.prefix(50))...' in \(path)")
        } catch let error as ToolExecutorError {
            throw error
        } catch {
            throw ToolExecutorError.writeError(error.localizedDescription)
        }
    }

    // MARK: - Glob (FileManager)

    private func executeGlob(_ args: [String: Any]) async throws -> ToolOutput {
        guard let pattern = args["pattern"] as? String else {
            throw ToolExecutorError.missingArgument("pattern")
        }

        let basePath = (args["path"] as? String).map { resolvePath($0).path } ?? workingDirectory.path
        let recursive = args["recursive"] as? Bool ?? false

        do {
            let results = try glob(pattern: pattern, in: basePath, recursive: recursive)
            if results.isEmpty {
                return ToolOutput(content: "No files matching '\(pattern)' found")
            }
            return ToolOutput(content: results.map { $0.path }.joined(separator: "\n"))
        } catch {
            throw ToolExecutorError.globError(error.localizedDescription)
        }
    }

    private func glob(pattern: String, in basePath: String, recursive: Bool) throws -> [URL] {
        var results: [URL] = []

        // Convert glob pattern to regex
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "**/", with: ".*/")
            .replacingOccurrences(of: "*", with: "[^/]*")

        let regex = try NSRegularExpression(pattern: "^" + regexPattern + "$", options: [])
        let baseURL = URL(fileURLWithPath: basePath)

        if recursive {
            let enumerator = FileManager.default.enumerator(
                at: baseURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            while let url = enumerator?.nextObject() as? URL {
                let relativePath = url.path.replacingOccurrences(of: basePath + "/", with: "")
                let range = NSRange(relativePath.startIndex..., in: relativePath)
                if regex.firstMatch(in: relativePath, options: [], range: range) != nil {
                    results.append(url)
                }
            }
        } else {
            let parentDir = baseURL.deletingLastPathComponent()
            let contents = try FileManager.default.contentsOfDirectory(
                at: parentDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            for url in contents {
                let range = NSRange(url.lastPathComponent.startIndex..., in: url.lastPathComponent)
                if regex.firstMatch(in: url.lastPathComponent, options: [], range: range) != nil {
                    results.append(url)
                }
            }
        }

        return results
    }

    // MARK: - Grep (String)

    private func executeGrep(_ args: [String: Any]) async throws -> ToolOutput {
        guard let path = args["path"] as? String else {
            throw ToolExecutorError.missingArgument("path")
        }
        guard let pattern = args["pattern"] as? String else {
            throw ToolExecutorError.missingArgument("pattern")
        }

        let url = resolvePath(path)
        let context = args["context"] as? Int ?? 0
        let caseSensitive = args["case_sensitive"] as? Bool ?? false

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let results = try grep(
                pattern: pattern,
                in: content,
                context: context,
                caseSensitive: caseSensitive
            )

            if results.isEmpty {
                return ToolOutput(content: "No matches for '\(pattern)' in \(path)")
            }

            return ToolOutput(content: "Matches in \(path):\n\n" + results.joined(separator: "\n"))
        } catch let error as ToolExecutorError {
            throw error
        } catch {
            throw ToolExecutorError.grepError(error.localizedDescription)
        }
    }

    private func grep(pattern: String, in content: String, context: Int, caseSensitive: Bool) throws -> [String] {
        var results: [String] = []

        let regex = try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : .caseInsensitive)

        let lines = content.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                var matchLine = ""

                if context > 0 {
                    let startIdx = max(0, index - context)
                    let endIdx = min(lines.count - 1, index + context)

                    for i in startIdx...endIdx {
                        let prefix = i == index ? ">>> " : "    "
                        matchLine += "\(prefix)\(i + 1): \(lines[i])\n"
                    }
                } else {
                    matchLine = "\(index + 1): \(line)"
                }

                results.append(matchLine)
            }
        }

        return results
    }

    // MARK: - Web Fetch (URLSession)

    private func executeWebFetch(_ args: [String: Any]) async throws -> ToolOutput {
        guard let urlString = args["url"] as? String else {
            throw ToolExecutorError.missingArgument("url")
        }

        guard let url = URL(string: urlString) else {
            throw ToolExecutorError.invalidURL(urlString)
        }

        let maxBytes = args["max_bytes"] as? Int ?? 50000

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ToolExecutorError.networkError("Invalid response")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw ToolExecutorError.httpError(httpResponse.statusCode)
            }

            var content: String
            if data.count > maxBytes {
                content = String(data: data.prefix(maxBytes), encoding: .utf8) ?? "[Binary content]"
                content += "\n\n[Content truncated - \(data.count) bytes total]"
            } else {
                content = String(data: data, encoding: .utf8) ?? "[Binary content]"
            }

            let header = "URL: \(urlString)\nStatus: \(httpResponse.statusCode)\n\n"
            return ToolOutput(content: header + content)

        } catch let error as ToolExecutorError {
            throw error
        } catch {
            throw ToolExecutorError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Web Search (DuckDuckGo)

    private func executeWebSearch(_ args: [String: Any]) async throws -> ToolOutput {
        guard let query = args["query"] as? String else {
            throw ToolExecutorError.missingArgument("query")
        }

        let count = args["count"] as? Int ?? 10

        // Use DuckDuckGo HTML (no API key required)
        let searchURL = URL(string: "https://html.duckduckgo.com/html/?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)")!

        var request = URLRequest(url: searchURL)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        do {
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let html = String(data: data, encoding: .utf8) else {
                throw ToolExecutorError.networkError("Failed to decode response")
            }

            // Parse DuckDuckGo HTML results
            let results = parseDuckDuckGoResults(html, count: count)

            if results.isEmpty {
                return ToolOutput(content: "No search results for '\(query)'")
            }

            var output = "Search results for '\(query)':\n\n"
            for (index, result) in results.enumerated() {
                output += "\(index + 1). \(result.title)\n"
                output += "   \(result.url)\n"
                if !result.snippet.isEmpty {
                    output += "   \(result.snippet)\n"
                }
                output += "\n"
            }

            return ToolOutput(content: output)

        } catch let error as ToolExecutorError {
            throw error
        } catch {
            throw ToolExecutorError.networkError(error.localizedDescription)
        }
    }

    private struct SearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    private func parseDuckDuckGoResults(_ html: String, count: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Simple regex-based parsing for DuckDuckGo HTML results
        let resultPattern = #"<a class=\"result__a\" href=\"([^\"]+)\">([^<]+)</a>"#
        let snippetPattern = #"<a class=\"result__snippet\"[^>]*>([^<]+)</a>"#

        let resultRegex = try? NSRegularExpression(pattern: resultPattern, options: [])
        let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [])

        let fullRange = NSRange(html.startIndex..., in: html)
        let matches = resultRegex?.matches(in: html, options: [], range: fullRange) ?? []

        for (_, match) in matches.prefix(count).enumerated() {
            guard match.numberOfRanges >= 3 else { continue }

            let urlRange = Range(match.range(at: 1), in: html)!
            let titleRange = Range(match.range(at: 2), in: html)!

            let url = String(html[urlRange])
            let title = String(html[titleRange])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            // Try to find snippet
            var snippet = ""
            if let snippetMatch = snippetRegex?.firstMatch(in: html, options: [], range: fullRange),
               snippetMatch.numberOfRanges >= 2 {
                let snippetRange = Range(snippetMatch.range(at: 1), in: html)!
                snippet = String(html[snippetRange])
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }

            results.append(SearchResult(title: title, url: url, snippet: snippet))
        }

        return results
    }

    // MARK: - Helpers

    private func resolvePath(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return workingDirectory.appendingPathComponent(path)
    }
}

// MARK: - Errors

public enum ToolExecutorError: Error, LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case processError(String)
    case fileNotFound(String)
    case invalidEncoding
    case writeError(String)
    case textNotFound(String)
    case globError(String)
    case grepError(String)
    case invalidURL(String)
    case networkError(String)
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .processError(let msg):
            return "Process error: \(msg)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .invalidEncoding:
            return "Unable to decode file as UTF-8"
        case .writeError(let msg):
            return "Write error: \(msg)"
        case .textNotFound(let text):
            return "Text not found in file: \(text.prefix(50))..."
        case .globError(let msg):
            return "Glob error: \(msg)"
        case .grepError(let msg):
            return "Grep error: \(msg)"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .httpError(let code):
            return "HTTP error: \(code)"
        }
    }
}
