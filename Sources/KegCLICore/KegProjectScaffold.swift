import Foundation

/// `keg project init` — writes a starter keg.yaml shaped by what the
/// directory looks like. The templates are deliberately small and heavily
/// commented: the config is meant to be finished by a human or an agent,
/// and `keg project validate` + `up` give immediate feedback.
public enum KegProjectScaffold {
    public enum Stack: String, Sendable, CaseIterable {
        case node, python, go, rust, swift, dockerfile, generic
    }

    /// Detect the repo's stack by marker files. Order matters: a repo with
    /// both a Dockerfile and package.json still gets the node template —
    /// the Dockerfile template is only for context-only repos.
    public static func detect(directory: URL, fileManager: FileManager = .default) -> Stack {
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        if exists("package.json") { return .node }
        if exists("requirements.txt") || exists("pyproject.toml") || exists("Pipfile") { return .python }
        if exists("go.mod") { return .go }
        if exists("Cargo.toml") { return .rust }
        if exists("Package.swift") { return .swift }
        if exists("Dockerfile") || exists("Containerfile") { return .dockerfile }
        return .generic
    }

    public static func template(for stack: Stack, projectName: String) -> String {
        switch stack {
        case .node:
            return """
            # keg.yaml — container infra for this repo, run by the Keg app/CLI.
            # Detected a Node project; adjust the command to your real entrypoint.
            name: \(projectName)

            services:
              app:
                image: node:22-alpine
                workdir: /app
                volumes:
                  - .:/app
                ports:
                  - "3000:3000"        # host:container — set both to your app's port
                environment:
                  - NODE_ENV=production
                command: ["sh", "-c", "npm install --no-audit --no-fund && npm start"]
                # restart: unless-stopped

            # Then: keg project up   ·   keg project status   ·   keg project logs app

            """
        case .python:
            return """
            # keg.yaml — container infra for this repo, run by the Keg app/CLI.
            # Detected a Python project; adjust the command to your real entrypoint.
            name: \(projectName)

            services:
              app:
                image: python:3.12-slim
                workdir: /app
                volumes:
                  - .:/app
                ports:
                  - "8000:8000"        # host:container — set both to your app's port
                command: ["sh", "-c", "pip install -r requirements.txt && python main.py"]
                # restart: unless-stopped

            # Then: keg project up   ·   keg project status   ·   keg project logs app

            """
        case .go:
            return """
            # keg.yaml — container infra for this repo, run by the Keg app/CLI.
            # Detected a Go module; adjust the command to your real entrypoint.
            name: \(projectName)

            services:
              app:
                image: golang:1.23-alpine
                workdir: /src
                volumes:
                  - .:/src
                ports:
                  - "8080:8080"        # host:container — set both to your app's port
                command: ["go", "run", "."]
                # restart: unless-stopped

            # Then: keg project up   ·   keg project status   ·   keg project logs app

            """
        case .rust:
            return """
            # keg.yaml — container infra for this repo, run by the Keg app/CLI.
            # Detected a Rust crate; adjust the command to your real entrypoint.
            name: \(projectName)

            services:
              app:
                image: rust:1-slim
                workdir: /src
                volumes:
                  - .:/src
                ports:
                  - "8080:8080"        # host:container — set both to your app's port
                command: ["sh", "-c", 'cargo build --release && ./target/release/$(basename $(pwd))']
                # restart: unless-stopped

            # Then: keg project up   ·   keg project status   ·   keg project logs app

            """
        case .swift:
            return """
            # keg.yaml — container infra for this repo, run by the Keg app/CLI.
            # Detected a Swift package; adjust the command to your real executable.
            name: \(projectName)

            services:
              app:
                image: swift:6.2-noble
                workdir: /src
                volumes:
                  - .:/src
                ports:
                  - "8080:8080"        # host:container — set both to your app's port
                command: ["swift", "run"]
                # restart: unless-stopped

            # Then: keg project up   ·   keg project status   ·   keg project logs app

            """
        case .dockerfile:
            return """
            # keg.yaml — container infra for this repo, run by the Keg app/CLI.
            # Found a Dockerfile — this builds and runs it with Apple's container
            # runtime (linux/arm64). Adjust the published port to what the image
            # listens on.
            name: \(projectName)

            services:
              app:
                build: .
                ports:
                  - "8080:8080"
                # environment:
                #   - KEY=value          # ${SHELL_VAR} interpolation works
                # volumes:
                #   - ./data:/data       # relative paths anchor to this directory
                restart: unless-stopped

            # Then: keg project up   ·   keg project status   ·   keg project logs app

            """
        case .generic:
            return """
            # keg.yaml — container infra for this repo, run by the Keg app/CLI.
            #
            # One service = one container. Each service needs `image:` (a registry
            # image, pulled automatically) or `build:` (a Dockerfile in a context
            # directory). Comments show the full surface — delete what you don't
            # need. All images must be linux/arm64 or multi-arch (Apple Silicon).
            name: \(projectName)

            services:
              app:
                image: alpine:3.20            # TODO: your real image, or `build: .`
                # build:
                #   context: .
                #   dockerfile: Dockerfile
                #   args:
                #     FLAVOR: prod
                ports:
                  - "8080:8080"               # host:container
                # environment:
                #   - DATABASE_URL=${DB_URL}   # from your shell or the .env file
                # volumes:
                #   - ./data:/var/lib/app      # bind mount, anchored to this dir
                #   - appdata:/var/lib/state   # named volume
                command: ["sh", "-c", "echo 'edit keg.yaml, then keg project up' && sleep infinity"]
                # entrypoint: ["/usr/bin/app"]  # override the image's entrypoint
                # workdir: /app
                # platform: linux/arm64         # default; amd64 runs under Rosetta
                # depends_on: [other-service]   # start ordering (no in-VM DNS —
                #                                # talk to peers via published ports)
                restart: unless-stopped

              # second:
              #   image: redis:7-alpine
              #   ports: ["6379:6379"]

            # Then: keg project up   ·   keg project status   ·   keg project logs app

            """
        }
    }

    /// Write keg.yaml into `directory` unless one exists and `force` is false.
    @discardableResult
    public static func write(
        directory: URL,
        force: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        let target = directory.appendingPathComponent(KegProjectConfig.fileName)
        if fileManager.fileExists(atPath: target.path) && !force {
            throw KegProjectError(
                "\(target.path) already exists — edit it, or pass --force to overwrite"
            )
        }
        let name = KegProjectLoader.sanitizeName(directory.lastPathComponent)
        let stack = detect(directory: directory, fileManager: fileManager)
        let text = template(for: stack, projectName: name.isEmpty ? "keg-project" : name)
        try text.write(to: target, atomically: true, encoding: .utf8)
        return target
    }
}
