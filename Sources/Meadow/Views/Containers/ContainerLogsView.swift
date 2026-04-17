import SwiftUI

// MARK: - Log Line Model

enum LogLevel: Sendable {
    case error
    case warning
    case info
    case debug
    case trace
    case unknown

    init(line: String) {
        let lower = line.lowercased()

        // Structured log patterns: "level":"error", "level":"warn", LEVEL=ERROR
        if lower.contains("\"level\":\"error\"") || lower.contains("\"level\":\"fatal\"") || lower.contains("\"level\":\"critical\"") {
            self = .error
        } else if lower.contains("\"level\":\"warn\"") || lower.contains("\"level\":\"warning\"") {
            self = .warning
        } else if lower.contains("\"level\":\"info\"") {
            self = .info
        } else if lower.contains("\"level\":\"debug\"") {
            self = .debug
        } else if lower.contains("\"level\":\"trace\"") {
            self = .trace
        }
        // KEY=VALUE log patterns
        else if lower.contains("level=error") || lower.contains("level=fatal") || lower.contains("level=critical") {
            self = .error
        } else if lower.contains("level=warn") || lower.contains("level=warning") {
            self = .warning
        } else if lower.contains("level=info") {
            self = .info
        } else if lower.contains("level=debug") {
            self = .debug
        } else if lower.contains("level=trace") {
            self = .trace
        }
        // Plain text patterns
        else if lower.hasPrefix("error") || lower.hasPrefix("fatal") || lower.hasPrefix("panic") || lower.hasPrefix("exception") || lower.contains("error:") || lower.contains("failed") || lower.contains("failure") {
            self = .error
        } else if lower.hasPrefix("warn") || lower.hasPrefix("warning") || lower.contains("warn:") || lower.contains("warning:") || lower.contains("deprecated") {
            self = .warning
        } else if lower.hasPrefix("info") || lower.hasPrefix("notice") || lower.contains("info:") || lower.contains("notice:") || lower.hasPrefix("==>") || lower.contains("listening on") || lower.contains("started") || lower.contains("ready") || lower.contains("connected") {
            self = .info
        } else if lower.hasPrefix("debug") || lower.hasPrefix("trace") || lower.contains("debug:") || lower.contains("trace:") {
            self = .debug
        } else {
            self = .unknown
        }
    }

    var color: Color {
        switch self {
        case .error: return .red
        case .warning: return .orange
        case .info: return .primary
        case .debug: return .secondary
        case .trace: return Color.secondary.opacity(0.6)
        case .unknown: return .primary
        }
    }

    var label: String {
        switch self {
        case .error: return "ERR"
        case .warning: return "WRN"
        case .info: return "INF"
        case .debug: return "DBG"
        case .trace: return "TRC"
        case .unknown: return "   "
        }
    }
}

struct LogLine: Identifiable {
    let id: Int
    let lineNumber: Int
    let text: String
    let level: LogLevel

    init(id: Int, lineNumber: Int, text: String) {
        self.id = id
        self.lineNumber = lineNumber
        self.text = text
        self.level = LogLevel(line: text)
    }
}

// MARK: - Log Level Filter

enum LogLevelFilter: String, CaseIterable {
    case all = "All"
    case errors = "Errors"
    case warnings = "Warnings+"
    case info = "Info+"

    func matches(_ level: LogLevel) -> Bool {
        switch self {
        case .all: return true
        case .errors: return level == .error
        case .warnings: return level == .error || level == .warning
        case .info: return level != .unknown
        }
    }
}

// MARK: - Smart Log Viewer

struct ContainerLogsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let containerID: String
    @State private var logLines: [LogLine] = []
    @State private var rawBuffer = ""
    @State private var isFollowing = true
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var levelFilter: LogLevelFilter = .all
    @State private var logProcess: Process?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading && logLines.isEmpty {
                ProgressView("Loading logs...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, logLines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                logContent
            }
        }
        .accessibilityLabel("Container Logs")
        .accessibilityHint("View and filter log output for this container")
        .navigationTitle("Logs")
        .searchable(text: $searchText, prompt: "Search logs")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Level", selection: $levelFilter) {
                    ForEach(LogLevelFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .accessibilityLabel("Log level filter")
                .accessibilityHint("Filter logs by severity level")
            }

            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $isFollowing) {
                    Label("Follow", systemImage: isFollowing ? "arrow.down.to.line.compact" : "arrow.down.to.line.compact")
                }
                .toggleStyle(.button)
                .tint(isFollowing ? .accentColor : .secondary)
                .accessibilityLabel("Follow logs")
                .accessibilityHint("Automatically scroll to new log entries")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    copyAllLogs()
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .accessibilityLabel("Copy all logs")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    clearLogs()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .accessibilityLabel("Clear logs")
            }
        }
        .task {
            await loadLogs()
        }
        .onChange(of: isFollowing) {
            if isFollowing {
                Task { await loadLogs() }
            } else {
                logProcess?.terminate()
                logProcess = nil
            }
        }
        .onDisappear {
            logProcess?.terminate()
        }
    }

    // MARK: - Log Content

    private var filteredLines: [LogLine] {
        var result = logLines

        if levelFilter != .all {
            result = result.filter { levelFilter.matches($0.level) }
        }

        if !searchText.isEmpty {
            result = result.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
        }

        return result
    }

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredLines) { line in
                        logRow(line)
                            .id(line.id)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: logLines.count) {
                if isFollowing, let last = logLines.last {
                    if reduceMotion {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func logRow(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Line number gutter
            Text(String(line.lineNumber))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 8)

            // Level badge
            Text(line.level.label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(levelBadgeColor(line.level), in: RoundedRectangle(cornerRadius: 2))
                .frame(width: 28)
                .padding(.trailing, 6)

            // Log text
            Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(line.level.color)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func levelBadgeColor(_ level: LogLevel) -> Color {
        switch level {
        case .error: return .red.opacity(0.8)
        case .warning: return .orange.opacity(0.7)
        case .info: return .blue.opacity(0.5)
        case .debug: return .gray.opacity(0.4)
        case .trace: return .gray.opacity(0.3)
        case .unknown: return .clear
        }
    }

    // MARK: - Actions

    private func copyAllLogs() {
        let allText = logLines.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allText, forType: .string)
    }

    private func clearLogs() {
        logLines = []
        rawBuffer = ""
    }

    // MARK: - Log Loading

    private func loadLogs() async {
        isLoading = true
        errorMessage = nil

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        var args = ["container", "logs"]
        if isFollowing { args.append("-f") }
        args.append(containerID)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            logProcess = process

            if isFollowing {
                // Stream logs — append new lines as they arrive. Detach the
                // handler on EOF so it doesn't spin after the child exits.
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        return
                    }
                    if let str = String(data: data, encoding: .utf8) {
                        Task { @MainActor in
                            appendLogText(str)
                        }
                    }
                }
                // Keep alive while following
                try? await Task.sleep(for: .seconds(Int.max))
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: data, encoding: .utf8) {
                    appendLogText(str)
                }
                process.waitUntilExit()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func appendLogText(_ text: String) {
        rawBuffer += text

        // Split into lines, keeping incomplete last line in buffer
        var lines = rawBuffer.components(separatedBy: "\n")
        if rawBuffer.hasSuffix("\n") {
            rawBuffer = ""
        } else {
            rawBuffer = lines.removeLast()
        }

        let startIndex = logLines.count + 1
        var newLines: [LogLine] = []
        for (index, text) in lines.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            newLines.append(LogLine(
                id: startIndex + index,
                lineNumber: startIndex + index,
                text: trimmed
            ))
        }

        logLines.append(contentsOf: newLines)
        isLoading = false
    }
}
