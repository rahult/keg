import Foundation

/// Plain-text output helpers: aligned columns and human-readable sizes.
/// No ANSI color library — the CLI stays honest piped or on a terminal.
public enum OutputFormatting {
    /// Renders rows as an aligned column table with a header rule, like
    /// `docker ps`. Column widths come from the widest cell (header
    /// included), capped so a long image reference can't blow up layout.
    public static func table(headers: [String], rows: [[String]], indent: String = "  ") -> String {
        let cap = 42
        let capped = rows.map { row in row.map { cell in
            cell.count > cap ? String(cell.prefix(cap - 1)) + "…" : cell
        } }
        var widths = headers.map(\.count)
        for row in capped {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }

        func render(_ cells: [String]) -> String {
            let padded = cells.enumerated().map { index, cell in
                cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            return indent + padded.joined(separator: "  ")
        }

        var lines = [render(headers)]
        lines.append(indent + widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
        for row in capped {
            lines.append(render(row))
        }
        return lines.joined(separator: "\n")
    }

    /// Byte counts the way people read them (KiB/MiB/GiB), like docker.
    public static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Relative "created" rendering: 3 minutes ago, 2 days ago.
    public static func ago(epochSeconds: Int64, from reference: Date = Date()) -> String {
        let seconds = Int(reference.timeIntervalSince1970) - Int(epochSeconds)
        guard seconds >= 0 else { return "just now" }
        let units: [(label: String, size: Int)] = [
            ("second", 60), ("minute", 60), ("hour", 24), ("day", 7), ("week", 5), ("month", 12), ("year", Int.max),
        ]
        var value = seconds
        var unit = "second"
        for (index, candidate) in units.enumerated() {
            unit = candidate.label
            if value < candidate.size || index == units.count - 1 { break }
            value /= candidate.size
        }
        return "\(value) \(unit)\(value == 1 ? "" : "s") ago"
    }

    /// The marker rendered before a container state (dot + state word).
    public static func stateBadge(_ state: String) -> String {
        switch state {
        case "running": return "● running"
        case "exited", "dead": return "○ \(state)"
        case "created", "paused", "restarting": return "◐ \(state)"
        default: return "· \(state)"
        }
    }
}
