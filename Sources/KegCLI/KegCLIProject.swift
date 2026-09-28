import Foundation
import KegCLICore

/// `keg project …` — repo-scoped container infra driven by keg.yaml — and
/// `keg skill …` — install the agent skill this CLI ships with.
enum KegCLIProject {
    static let usage = """
    keg project — container infra for this repo, from keg.yaml

    USAGE
      keg project <subcommand> [options]      (from the directory with keg.yaml)

    SUBCOMMANDS
      init [--force]        Scaffold keg.yaml, pre-detected for the repo's stack
      validate              Parse + validate the config without starting anything
      up [--build]          Build/pull, recreate + start services in dependency
                            order; prints URLs (exits non-zero with a log tail
                            if a service dies during startup)
      status [--json]       Per-service state, ports and URLs
      logs <service> [-f]   Service logs (-f follows, -n N tails N lines)
      down                  Stop + remove this project's containers
                            (bind-mount and named-volume data always survives)

    OPTIONS
      --file <path>         Use this keg.yaml instead of ./keg.yaml
      --build               Force an image rebuild even if cached
      --timeout <seconds>   Startup wait per service (default 120)

    Containers are named <project>-<service>-1 and labeled
    com.docker.compose.project — the Keg app's Compose screen shows the same
    infra grouped under the project name.
    """

    static let skillUsage = """
    keg skill — the keg agent skill (SKILL.md for coding agents)

    USAGE
      keg skill install [--dir <path>] [--project]
                        Install into the user skill conventions
                        (~/.zcode/skills/keg + ~/.agents/skills/keg).
                        --project installs repo-locally instead; --dir to
                        one explicit directory.
      keg skill show        Print the SKILL.md to stdout
      keg skill path        Print where the packaged skill lives
      keg skill uninstall [--dir <path>] [--project]
                            Remove installed copies (default: user scope)

    Agents that load SKILL.md files pick the skill up automatically; humans
    can read the same file — it doubles as the keg.yaml handbook.
    """

    // MARK: - Dispatch

    static func run(
        _ operands: [String],
        socketOverride: String?,
        print: (String) -> Void
    ) -> Int32 {
        guard let subcommand = operands.first else {
            print(usage)
            return 0
        }
        let rest = Array(operands.dropFirst())
        switch subcommand {
        case "help", "--help", "-h":
            print(usage)
            return 0
        case "init": return initProject(rest, print: print)
        case "validate": return validate(rest, print: print)
        case "up": return up(rest, socketOverride: socketOverride, print: print)
        case "down": return down(rest, socketOverride: socketOverride, print: print)
        case "status": return status(rest, socketOverride: socketOverride, print: print)
        case "logs": return logs(rest, socketOverride: socketOverride, print: print)
        default:
            print("unknown project subcommand: \(subcommand)\n")
            print(usage)
            return 1
        }
    }

    static func runSkill(
        _ operands: [String],
        print: (String) -> Void
    ) -> Int32 {
        guard let subcommand = operands.first else {
            print(skillUsage)
            return 0
        }
        let rest = Array(operands.dropFirst())
        switch subcommand {
        case "help", "--help", "-h":
            print(skillUsage)
            return 0
        case "install": return skillInstall(rest, print: print)
        case "show": return skillShow(print: print)
        case "path": return skillPath(print: print)
        case "uninstall": return skillUninstall(rest, print: print)
        default:
            print("unknown skill subcommand: \(subcommand)\n")
            print(skillUsage)
            return 1
        }
    }

    // MARK: - Shared helpers

    private static func option(_ operands: [String], _ name: String) -> String? {
        guard let index = operands.firstIndex(of: name), index + 1 < operands.count else { return nil }
        return operands[index + 1]
    }

    /// Config location: `--file <path>` or keg.yaml in the current directory.
    private static func loadConfig(_ operands: [String], print: (String) -> Void) -> KegProjectConfig? {
        let directory: String
        if let file = option(operands, "--file") {
            directory = URL(filePath: file).deletingLastPathComponent().path
        } else {
            directory = FileManager.default.currentDirectoryPath
        }
        do {
            return try KegProjectLoader.load(directory: directory)
        } catch {
            print("\(error)")
            return nil
        }
    }

    private static func requireClient(
        _ socketOverride: String?, print: (String) -> Void
    ) -> KegAPIClient? {
        guard let path = socketOverride ?? KegSocketResolver.resolve() else {
            print("Keg is not running — no Docker API socket found.")
            print("Open the Keg app (or run: keg open), then retry.")
            return nil
        }
        // 60s interactive budget: on busy machines `container list -a`
        // (behind the container-list route) can outrun the 10s default.
        return KegAPIClient(socketPath: path, timeoutSeconds: 60)
    }

    // MARK: - init

    static func initProject(_ operands: [String], print: (String) -> Void) -> Int32 {
        let directory: URL
        if let dir = option(operands, "--dir") {
            directory = URL(filePath: dir)
        } else if let file = option(operands, "--file") {
            directory = URL(filePath: file).deletingLastPathComponent()
        } else {
            directory = URL(filePath: FileManager.default.currentDirectoryPath)
        }
        do {
            let written = try KegProjectScaffold.write(
                directory: directory,
                force: operands.contains("--force")
            )
            print("wrote \(written.path)")
            print("next: edit the TODOs, then `keg project validate` and `keg project up`")
            return 0
        } catch {
            print("\(error)")
            return 1
        }
    }

    // MARK: - validate

    static func validate(_ operands: [String], print: (String) -> Void) -> Int32 {
        guard let config = loadConfig(operands, print: print) else { return 1 }
        let order = (try? KegProjectLoader.orderedServiceNames(in: config)) ?? []
        print("✓ \(config.name): \(config.services.count) service\(config.services.count == 1 ? "" : "s"), valid")
        for name in order {
            guard let service = config.services[name] else { continue }
            let origin: String
            if let build = service.build {
                origin = "build \(build.context)\(build.dockerfile.map { " (\($0))" } ?? "")"
            } else {
                origin = service.image ?? "?"
            }
            let ports = service.ports.map { "\($0.hostPort):\($0.containerPort)" }.joined(separator: ", ")
            print("  \(name)  \(origin)\(ports.isEmpty ? "" : "  → \(ports)")")
        }
        print("containers: \(order.map { KegProjectLoader.containerName(project: config.name, service: $0) }.joined(separator: ", "))")
        return 0
    }

    // MARK: - up

    static func up(_ operands: [String], socketOverride: String?, print: (String) -> Void) -> Int32 {
        guard let config = loadConfig(operands, print: print) else { return 1 }
        guard let client = requireClient(socketOverride, print: print) else { return 1 }
        var options = KegProjectEngine.UpOptions()
        options.rebuild = operands.contains("--build")
        if let timeout = option(operands, "--timeout"), let seconds = TimeInterval(timeout), seconds > 0 {
            options.waitTimeout = seconds
        }

        print("▲ \(config.name)")
        let engine = KegProjectEngine(client: client)
        do {
            let result = try engine.up(config, options: options) { text in
                print(text)
            }
            print("")
            for outcome in result.outcomes {
                let urls = outcome.urls.isEmpty ? "" : "  " + outcome.urls.joined(separator: "  ")
                print("  ✓ \(outcome.service)  (\(outcome.container))\(urls)")
            }
            print("done — `keg project status` to re-check, `keg project down` to stop")
            return 0
        } catch {
            print("up failed: \(error)")
            return 1
        }
    }

    // MARK: - down

    static func down(_ operands: [String], socketOverride: String?, print: (String) -> Void) -> Int32 {
        guard let config = loadConfig(operands, print: print) else { return 1 }
        guard let client = requireClient(socketOverride, print: print) else { return 1 }
        let engine = KegProjectEngine(client: client)
        do {
            let removed = try engine.down(config)
            if removed == 0 {
                print("nothing to remove — no containers for project “\(config.name)”")
            } else {
                print("removed \(removed) container\(removed == 1 ? "" : "s") — data in bind mounts and named volumes was kept")
            }
            return 0
        } catch {
            print("down failed: \(error)")
            return 1
        }
    }

    // MARK: - status

    static func status(_ operands: [String], socketOverride: String?, print: (String) -> Void) -> Int32 {
        guard let config = loadConfig(operands, print: print) else { return 1 }
        guard let client = requireClient(socketOverride, print: print) else { return 1 }
        let engine = KegProjectEngine(client: client)
        do {
            let entries = try engine.status(config)
            if operands.contains("--json") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(entries)
                print(String(data: data, encoding: .utf8) ?? "[]")
            } else {
                let rows = entries.map { entry in
                    [
                        entry.service,
                        entry.state,
                        entry.status,
                        entry.ports.joined(separator: ", "),
                        entry.urls.joined(separator: " "),
                    ]
                }
                print(OutputFormatting.table(
                    headers: ["SERVICE", "STATE", "STATUS", "PORTS", "URLS"], rows: rows
                ))
                print("project \(config.name): \(entries.filter { $0.state == "running" }.count)/\(entries.count) running")
            }
            return 0
        } catch {
            print("status failed: \(error)")
            return 1
        }
    }

    // MARK: - logs

    static func logs(_ operands: [String], socketOverride: String?, print: (String) -> Void) -> Int32 {
        guard let service = operands.first(where: { !$0.hasPrefix("-") }) else {
            print("usage: keg project logs <service> [-f] [-n N]")
            return 2
        }
        guard let config = loadConfig(operands, print: print) else { return 1 }
        guard config.services[service] != nil else {
            print("no service “\(service)” in keg.yaml (services: \(config.services.keys.sorted().joined(separator: ", ")))")
            return 1
        }
        let containerName = KegProjectLoader.containerName(project: config.name, service: service)
        // Delegate to the container-logs command with the resolved name.
        let flags = operands.filter { $0.hasPrefix("-") }
        let tails = operands.dropFirst().filter { Int($0) != nil }
        return KegCLI.logs(operands: [containerName] + flags + tails,
                           socketOverride: socketOverride, print: print)
    }

    // MARK: - skill

    static func skillInstall(_ operands: [String], print: (String) -> Void) -> Int32 {
        do {
            let packaged = try KegSkill.skillText()
            let targets: [URL]
            if let dir = option(operands, "--dir") {
                targets = [URL(filePath: dir, directoryHint: .isDirectory)]
            } else if operands.contains("--project") {
                let root = URL(filePath: FileManager.default.currentDirectoryPath)
                targets = KegSkill.projectSkillDirectories(root: root)
            } else {
                targets = KegSkill.userSkillDirectories()
            }
            for target in targets {
                let result = try KegSkill.install(into: target, packagedText: packaged)
                let path = target.appendingPathComponent("SKILL.md").path
                switch result {
                case .created: print("installed \(path)")
                case .updated: print("updated \(path)")
                case .unchanged: print("already up to date: \(path)")
                }
            }
            print("agents that scan SKILL.md skills will pick this up as “keg”")
            return 0
        } catch {
            print("\(error)")
            return 1
        }
    }

    static func skillShow(print: (String) -> Void) -> Int32 {
        do {
            print(try KegSkill.skillText())
            return 0
        } catch {
            print("\(error)")
            return 1
        }
    }

    static func skillPath(print: (String) -> Void) -> Int32 {
        guard let url = KegSkill.packagedSkillURL() else {
            print("\(KegSkill.SkillError.resourceMissing)")
            return 1
        }
        print(url.path)
        return 0
    }

    static func skillUninstall(_ operands: [String], print: (String) -> Void) -> Int32 {
        let targets: [URL]
        if let dir = option(operands, "--dir") {
            targets = [URL(filePath: dir, directoryHint: .isDirectory)]
        } else if operands.contains("--project") {
            let root = URL(filePath: FileManager.default.currentDirectoryPath)
            targets = KegSkill.projectSkillDirectories(root: root)
        } else {
            targets = KegSkill.userSkillDirectories()
        }
        var removedAny = false
        var failures = 0
        for target in targets {
            do {
                try KegSkill.uninstall(from: target)
                print("removed \(target.appendingPathComponent("SKILL.md").path)")
                removedAny = true
            } catch let error as KegProjectError where error.message.contains("no keg skill installed") {
                continue // nothing there — fine for the multi-location default
            } catch {
                print("\(error)")
                failures += 1
            }
        }
        if !removedAny, failures == 0 {
            print("no installed keg skill found")
        }
        return failures == 0 ? 0 : 1
    }
}
