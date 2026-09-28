import Foundation

/// The "keg" agent skill: a SKILL.md that teaches coding agents (ZCode,
/// Claude, …) how to containerize a repo with keg.yaml + the keg CLI.
/// Ships inside the CLI binary's resource bundle so any machine with `keg`
/// installed can install the skill next to its agents.
///
/// Bundle lookup is manual on purpose: the generated `Bundle.module`
/// accessor `fatalError`s when the resource bundle wasn't copied (a
/// hand-assembled app bundle, a bare binary), which would take down every
/// CLI command — a missing skill must degrade to an error message instead.
public enum KegSkill {
    /// Anchor for `Bundle(for:)` — finds the bundle holding KegCLICore code.
    private final class BundleMarker {}

    public enum SkillError: Error, CustomStringConvertible {
        case resourceMissing
        public var description: String {
            """
            the keg skill resource is missing from this installation — \
            grab skills/keg/SKILL.md from the Keg repository instead
            """
        }
    }

    /// Where the packaged skill lives: the resource bundle next to the
    /// executable (dev build and bundled CLI), the app bundle's Resources,
    /// or — last resort for in-repo dev builds — the source tree.
    public static func packagedSkillURL() -> URL? {
        let fileManager = FileManager.default
        let bundleName = "Keg_KegCLICore.bundle"

        // A PATH-installed `keg` is usually a symlink into the app bundle;
        // resolving it lands beside the resource bundle. Both the raw and
        // resolved executable directories are considered.
        var baseDirectories: [URL] = []
        if let executableURL = Bundle.main.executableURL {
            baseDirectories.append(executableURL.deletingLastPathComponent())
        }
        let resolved = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        baseDirectories.append(resolved.deletingLastPathComponent())

        var candidates: [URL] = []
        for base in baseDirectories {
            candidates.append(base.appendingPathComponent(bundleName))
            candidates.append(
                base.deletingLastPathComponent()
                    .appendingPathComponent("Resources").appendingPathComponent(bundleName)
            )
            // Deep products (.build/out/Products/Debug/KegTests.xctest/…,
            // .build/<config>/kegcli): walk up to the package root looking
            // for the resource bundle or, bare-bones, the source file.
            var directory = base
            for _ in 0..<12 {
                directory = directory.deletingLastPathComponent()
                candidates.append(directory.appendingPathComponent(bundleName))
                candidates.append(directory
                    .appendingPathComponent("Sources/KegCLICore/Resources/KegSkill/SKILL.md"))
            }
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(bundleName))
        }
        // In test bundles the code lives inside KegTests.xctest and the
        // resource bundle sits next to it — the class's bundle knows that.
        if let codeResourceURL = Bundle(for: BundleMarker.self).resourceURL {
            candidates.append(codeResourceURL.appendingPathComponent(bundleName))
        }

        for candidate in candidates {
            if candidate.pathExtension == "bundle" {
                // Resource-only bundle layouts: standard (Contents/Resources)
                // and flat. Direct path checks — Bundle(url:) probing is
                // both slow and flaky on unrelated bundles in the walk-up.
                for relative in ["Contents/Resources/Resources/KegSkill/SKILL.md",
                                 "Contents/Resources/KegSkill/SKILL.md"] {
                    let direct = candidate.appendingPathComponent(relative)
                    if fileManager.fileExists(atPath: direct.path) { return direct }
                }
            } else if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public static func skillText() throws -> String {
        guard let url = packagedSkillURL() else { throw SkillError.resourceMissing }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Install locations

    /// The agent-skill conventions this machine's tools scan: ZCode's user
    /// skills and the cross-tool `.agents/skills`.
    public static func userSkillDirectories(home: String = NSHomeDirectory()) -> [URL] {
        [
            URL(filePath: home).appendingPathComponent(".zcode/skills/keg"),
            URL(filePath: home).appendingPathComponent(".agents/skills/keg"),
        ]
    }

    /// Repo-local install for teams that commit their agents' skills.
    public static func projectSkillDirectories(root: URL) -> [URL] {
        [
            root.appendingPathComponent(".zcode/skills/keg"),
            root.appendingPathComponent(".agents/skills/keg"),
        ]
    }

    // MARK: Install state

    public enum InstallState: Equatable, Sendable {
        case missing
        case upToDate
        case outdated
    }

    public static func state(at directory: URL, packagedText: String) -> InstallState {
        let file = directory.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .missing }
        return text == packagedText ? .upToDate : .outdated
    }

    /// Directories (user conventions) where the skill is already installed.
    public static func installedDirectories(
        home: String = NSHomeDirectory(),
        packagedText: String? = nil
    ) -> [(directory: URL, state: InstallState)] {
        let packaged = packagedText ?? (try? skillText())
        return userSkillDirectories(home: home).compactMap { directory in
            guard let packaged else { return nil }
            let state = state(at: directory, packagedText: packaged)
            return state == .missing ? nil : (directory, state)
        }
    }

    // MARK: Install

    public enum InstallResult: Equatable, Sendable {
        case created(URL)
        case updated(URL)
        case unchanged(URL)
    }

    /// Write SKILL.md into `directory`, creating the directory as needed.
    public static func install(
        into directory: URL,
        packagedText: String? = nil,
        fileManager: FileManager = .default
    ) throws -> InstallResult {
        let text = try packagedText ?? skillText()
        let file = directory.appendingPathComponent("SKILL.md")
        let previous = state(at: directory, packagedText: text)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        switch previous {
        case .missing: return .created(file)
        case .outdated: return .updated(file)
        case .upToDate: return .unchanged(file)
        }
    }

    public static func uninstall(from directory: URL, fileManager: FileManager = .default) throws {
        let file = directory.appendingPathComponent("SKILL.md")
        guard fileManager.fileExists(atPath: file.path) else {
            throw KegProjectError("no keg skill installed at \(directory.path)")
        }
        try fileManager.removeItem(at: file)
        // Leave the (now empty) directory behind — harmless, and removing
        // a directory we didn't create is not this command's business.
    }
}
