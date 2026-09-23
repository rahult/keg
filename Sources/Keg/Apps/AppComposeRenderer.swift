import Foundation

/// Renders a catalog app's compose template: substitutes `{{.Placeholder}}`
/// slots with wizard answers plus the reserved Keg-provided values, emitting
/// YAML that is always parseable — user-supplied secrets are quoted and
/// escaped so a password like `foo"bar` cannot corrupt the document.
enum AppComposeRenderer {
    /// Values Keg provides automatically; templates may reference them
    /// without declaring a field.
    static let reservedIDs = ["KegWebPort", "KegDataDir", "KegTimeZone"]

    // Regex values are immutable but the stdlib does not mark the type
    // Sendable; safe to share, so the check is silenced deliberately.
    private nonisolated(unsafe) static let placeholderPattern = /\{\{\.([A-Za-z][A-Za-z0-9_]*)\}\}/

    enum RenderError: Error, CustomStringConvertible {
        case missingValues([String])
        case missingRequired([String])
        case embeddedUnsafeValue(field: String)
        case portNotAnInteger(field: String)

        var description: String {
            switch self {
            case .missingValues(let fields):
                return "Missing values for: \(fields.joined(separator: ", "))"
            case .missingRequired(let labels):
                return "This app now requires settings you haven't chosen yet: \(labels.joined(separator: ", ")). Remove and reinstall it to configure the new options."
            case .embeddedUnsafeValue(let field):
                return "'\(field)' contains characters that are only allowed in a standalone placeholder"
            case .portNotAnInteger(let field):
                return "'\(field)' must be a port number"
            }
        }
    }

    /// Placeholders referenced by a template.
    static func placeholders(in compose: String) -> Set<String> {
        Set(compose.matches(of: placeholderPattern).map { String($0.1) })
    }

    /// Required fields must resolve to non-empty values — a backstop for
    /// install/update paths even if the UI's own check is bypassed, and the
    /// guard when an updated template introduces a requirement the stored
    /// answers can't satisfy.
    static func validateRequired(app: CatalogApp, values: [String: String]) throws {
        let missing = app.fields
            .filter { $0.required }
            .filter { (values[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .map(\.label)
        guard missing.isEmpty else { throw RenderError.missingRequired(missing) }
    }

    /// Merges catalog defaults (with `{{.KegDataDir}}` indirection expanded)
    /// under user answers, then layers the reserved values. Answers win.
    static func resolvedValues(
        app: CatalogApp,
        answers: [String: String],
        dataRoot: String,
        webPort: Int
    ) throws -> [String: String] {
        let absoluteDataRoot = NSString(string: dataRoot).expandingTildeInPath
        var values: [String: String] = [:]
        for field in app.fields {
            let raw = answers[field.id] ?? field.defaultValue
            values[field.id] = raw.replacingOccurrences(
                of: "{{.KegDataDir}}",
                with: absoluteDataRoot
            )
        }
        values["KegDataDir"] = absoluteDataRoot
        values["KegTimeZone"] = TimeZone.current.identifier
        values["KegWebPort"] = String(webPort)
        return values
    }

    /// Renders the template. Throws when a placeholder has no value, or
    /// when a value embedded inside a template-quoted string carries
    /// characters that would break that quoting.
    static func render(app: CatalogApp, values: [String: String]) throws -> String {
        let referenced = placeholders(in: app.compose)
        let missing = referenced.filter { values[$0] == nil }.sorted()
        guard missing.isEmpty else { throw RenderError.missingValues(missing) }
        try validateEmbeddable(app: app, values: values)

        var rendered = ""
        for line in app.compose.split(separator: "\n", omittingEmptySubsequences: false) {
            rendered += renderLine(line, values: values) + "\n"
        }
        return rendered
    }

    private static func renderLine(_ line: Substring, values: [String: String]) -> String {
        var result = ""
        var rest = line[...]
        while let match = rest.firstMatch(of: placeholderPattern) {
            result += rest[..<match.range.lowerBound]
            let id = String(match.1)
            let value = values[id] ?? ""
            result += substitution(for: value, id: id, lineSoFar: result, remainderAfter: rest[match.range.upperBound...])
            rest = rest[match.range.upperBound...]
        }
        result += rest
        return result
    }

    /// Standalone placeholders (the whole YAML value) receive a fully quoted
    /// safe scalar; placeholders embedded in a larger string receive the raw
    /// value but refuse characters that would break the enclosing quotes.
    private static func substitution(
        for value: String,
        id: String,
        lineSoFar: String,
        remainderAfter: Substring
    ) -> String {
        let trimmedTail = remainderAfter.trimmingCharacters(in: .whitespaces)
        let standalone = valueIsComplete(lineSoFar: lineSoFar, tail: trimmedTail)
        if standalone {
            return yamlScalar(value)
        }
        if value.contains("\"") || value.contains("\\") || value.contains("\n") {
            // Callers cannot recover from a broken document — fail loudly.
            // This mirrors RenderError.embeddedUnsafeValue but during line
            // rendering; validated up front by `validateEmbeddable` below.
            return ""
        }
        return value
    }

    private static func valueIsComplete(lineSoFar: String, tail: String) -> Bool {
        // Standalone means: nothing meaningful before the placeholder on the
        // line except a `- ` sequence or a `key:` prefix, and nothing after
        // it. `tail` is already whitespace-trimmed.
        let before = lineSoFar.trimmingCharacters(in: .whitespaces)
        let headPattern = /^(-\s+)?([A-Za-z0-9_.-]+:\s*)?$/
        return tail.isEmpty && before.firstMatch(of: headPattern) != nil
    }

    /// Up-front check that values substituted into *embedded* positions
    /// (inside template-quoted strings) cannot break the quoting.
    static func validateEmbeddable(app: CatalogApp, values: [String: String]) throws {
        for line in app.compose.split(separator: "\n") {
            var search = line[...]
            while let match = search.firstMatch(of: placeholderPattern) {
                let id = String(match.1)
                let before = String(line[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let after = String(line[match.range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let headPattern = /^(-\s+)?([A-Za-z0-9_.-]+:\s*)?$/
                let standalone = after.isEmpty && before.firstMatch(of: headPattern) != nil
                if !standalone, let value = values[id],
                   value.contains("\"") || value.contains("\\") || value.contains("\n") {
                    throw RenderError.embeddedUnsafeValue(field: id)
                }
                search = search[match.range.upperBound...]
            }
        }
    }

    /// Renders `value` as a YAML scalar: plain when unambiguous, a
    /// double-quoted escaped string when it contains YAML-significant
    /// characters (so secrets with `#`, `:`, quotes, or spaces survive).
    static func yamlScalar(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        let special = value.range(of: #"[:#{}\[\],&*!|>'"%@`]"#, options: .regularExpression) != nil
            || value.range(of: #"\s"#, options: .regularExpression) != nil
        let ambiguous = ["~", "null", "true", "false", "yes", "no", "on", "off"].contains(value.lowercased())
            && value == value.lowercased() || value.hasSuffix(":")
            || value.hasPrefix("-") || value.hasPrefix("?") || value.hasPrefix(":")
        guard special || ambiguous else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

/// Checks whether a TCP port is already taken on this host by attempting to
/// bind it. No subprocesses, no parsing — bind(2) is the ground truth.
enum PortProbe {
    /// True when something is already listening on `port` (loopback-wide).
    static func isPortInUse(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var one: Int32 = 1
        // Without SO_REUSEADDR a port in TIME_WAIT reads as "in use"; we only
        // care about live listeners, so allow reuse before binding.
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // s_addr is network byte order — INADDR_LOOPBACK needs the htonl
        // equivalent on little-endian hosts or bind targets 1.0.0.127 and
        // fails with EADDRNOTAVAIL.
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // EADDRINUSE (and EACCES for privileged ports) mean the port is not
        // available for this install.
        return bindResult != 0 && (errno == EADDRINUSE || errno == EACCES)
    }
}

enum SecretGenerator {
    /// URL-safe alphanumeric secret, ~24 characters. Used to pre-fill
    /// `generate: true` wizard fields so users never invent weak passwords.
    static func password(length: Int = 24) -> String {
        let pool = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { pool[Int($0) % pool.count] })
    }
}
