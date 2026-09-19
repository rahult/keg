import Foundation
import Hummingbird
import ContainerAPIClient

// MARK: - Container CLI Bridge

actor ContainerBridge {
    /// Platform pinned for image pulls. Without --platform, `container image pull`
    /// unpacks EVERY platform variant in the index — each becomes a 512 GiB-capacity
    /// ext4 snapshot (~1.1 GB allocated metadata even for alpine). Keg targets
    /// Apple Silicon only, so linux/arm64 is always the host platform.
    static let hostPlatform = "linux/arm64"

    /// Shared XPC connection to container-apiserver. Used for operations the
    /// CLI can't express: real exit codes, exec process control, stats.
    static let xpc = ContainerClient()

    /// Exit-code futures for containers started through the Docker API, so
    /// `POST /wait` can report the actual exit code. Stored as a task (not
    /// the process) so exactly one XPC wait happens per container — the
    /// pump's EOF handler and the wait route both await the same future.
    var startedProcesses: [String: Task<Int32, Never>] = [:]

    /// Retained stdio per API-started container: output lands in a bounded
    /// ring so clients can attach late and still see recent history.
    var attachBuffers: [String: AttachBuffer] = [:]

    /// Connections that attached before the container started (docker run);
    /// wired to the buffer the moment start succeeds.
    var pendingAttaches: [String: [(HijackedConnection, Bool)]] = [:]

    /// Container ids the user explicitly stopped through the API; their
    /// restart policy (if any) must not trigger an automatic restart.
    var userStoppedIDs: Set<String> = []

    /// Consecutive auto-restart count per container (crash-loop cap).
    var restartAttempts: [String: Int] = [:]

    /// Live exec pumps, keyed by exec id — resize routes look processes up
    /// here; entries are removed when the pump completes.
    var activeExecPumps: [String: ExecPump] = [:]

    /// Cache of on-disk image sizes keyed by index digest ("sha256:…").
    /// Computing these walks the content + snapshot stores, so keep a short TTL.
    private var imageSizeCache: (timestamp: Date, sizes: [String: Int64])?
    private let imageSizeCacheTTL: TimeInterval = 30

    func runCLI(_ args: [String], timeout: Duration = .seconds(30)) async throws -> (exitCode: Int32, output: String) {
        let (code, output) = try await ContainerCLI.run(args, timeout: timeout)
        return (code, output)
    }

    func runCLIStreaming(_ args: [String]) async throws -> Process {
        let process = try ContainerCLI.makeProcess(args)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        return process
    }

    // MARK: - Container Operations

    func listContainers(all: Bool) async throws -> [DockerContainer] {
        var args = ["container", "list", "--format", "json"]
        if all { args.append("-a") }
        let (code, output) = try await runCLI(args)
        guard code == 0, let data = output.data(using: .utf8) else { return [] }

        if let entries = try? JSONDecoder().decode([ContainerListEntry].self, from: data) {
            return entries.map { $0.toDocker() }
        }
        return []
    }

    func createContainer(from request: DockerContainerCreateRequest, name: String?) async throws -> DockerContainerCreateResponse {
        let id = name ?? "keg-\(UUID().uuidString.prefix(12).lowercased())"

        // Pull image if specified (pinned to the requested platform, defaulting
        // to the host — an unpinned pull unpacks all variants, ~1.1 GB each).
        // Skip it when the image is already stored: an unconditional pull
        // refetches the registry index and re-unpacks on EVERY create.
        if let image = request.image, !image.isEmpty {
            if try await imageExists(image) {
                // already stored locally — nothing to fetch
            } else {
                let platform = (request.platform?.isEmpty == false) ? request.platform! : Self.hostPlatform
                let _ = try await runCLI(["container", "image", "pull", "--platform", platform, image], timeout: .seconds(1200))
            }
        }

        // Real `container create` so the container exists before start —
        // the docker CLI issues POST /wait?condition=next-exit BEFORE
        // /start (to avoid racing short-lived exits), and a wait on a
        // not-yet-created container must simply block, not 500.
        // 120s: on a container's first-ever start the apiserver unpacks the
        // image seed server-side, which can exceed the 30s default — and
        // killing the CLI mid-create leaves a half-built container behind.
        var args = ["container", "create", "--name", id]
        args += Self.containerArgs(from: request)
        let (code, output) = try await runCLI(args, timeout: .seconds(120))
        guard code == 0 else {
            throw DockerAPIError.containerStartFailed(output)
        }

        return DockerContainerCreateResponse(id: id, warnings: [])
    }

    /// Flags shared by `container create`/`container run` for a Docker
    /// create request (env, binds, memory, ports, labels, workdir, cmd).
    private static func containerArgs(from req: DockerContainerCreateRequest) -> [String] {
        var args: [String] = []

        if let env = req.env {
            for e in env {
                args += ["-e", e]
            }
        }

        if let hostConfig = req.hostConfig {
            if let binds = hostConfig.binds {
                for b in binds {
                    args += ["-v", b]
                }
            }
            if let memory = hostConfig.memory, memory > 0 {
                // Apple's container runtime enforces a 200 MiB minimum;
                // docker accepts smaller values, so clamp instead of failing.
                let mb = max(memory / (1024 * 1024), 200)
                args += ["--memory", "\(mb)M"]
            }
            // A named network mode (compose sends the stack network) maps to
            // a real runtime network; pseudo-modes mean "default".
            if let networkMode = hostConfig.networkMode,
               !networkMode.isEmpty,
               !["default", "bridge", "host", "none"].contains(networkMode) {
                args += ["--network", networkMode]
            }
            if let portBindings = hostConfig.portBindings {
                for (containerPort, bindings) in portBindings {
                    for binding in bindings {
                        let containerPortClean = containerPort.components(separatedBy: "/").first ?? containerPort
                        // docker CLI sends HostIp "0.0.0.0" or "" for
                        // unspecified binds — an empty IP would build the
                        // invalid publish spec ":port:port".
                        let hostIP = binding.hostIP.flatMap { $0.isEmpty ? nil : $0 }
                            .flatMap { $0 == "0.0.0.0" ? nil : $0 }
                        if let hostPort = binding.hostPort, let hostIP {
                            args += ["-p", "\(hostIP):\(hostPort):\(containerPortClean)"]
                        } else if let hostPort = binding.hostPort {
                            args += ["-p", "\(hostPort):\(containerPortClean)"]
                        }
                    }
                }
            }
        }

        if let labels = req.labels {
            for (k, v) in labels {
                args += ["-l", "\(k)=\(v)"]
            }
        }

        // Persist the restart policy as a label so the event bus can honor
        // it even across Keg restarts (docker's restart=always semantics).
        if let policy = req.hostConfig?.restartPolicy?.name,
           ["always", "unless-stopped", "on-failure"].contains(policy) {
            args += ["-l", "keg.restart-policy=\(policy)"]
        }

        // --rm: the runtime has no native auto-remove, so the container is
        // labeled and the event bus removes it on the die transition
        // (docker forbids combining --rm with a restart policy).
        if req.hostConfig?.autoRemove == true {
            args += ["-l", "keg.auto-remove=1"]
        }

        if let workingDir = req.workingDir {
            args += ["-w", workingDir]
        }

        // A requested platform different from the host selects the image
        // variant AND enables Rosetta translation for amd64.
        if let platform = req.platform, !platform.isEmpty, platform != Self.hostPlatform {
            args += ["--platform", platform]
        }

        if let image = req.image {
            args.append(image)
        }

        if let cmd = req.cmd {
            args += cmd
        }

        return args
    }

    func startContainer(id: String) async throws {
        // The container already exists (created via `container create`); start it.
        let (code, output) = try await runCLI(["container", "start", id])
        if code != 0 {
            throw DockerAPIError.containerStartFailed(output)
        }
    }

    func stopContainer(id: String) async throws {
        let _ = try await runCLI(["container", "stop", id])
    }

    func killContainer(id: String) async throws {
        let _ = try await runCLI(["container", "kill", id])
    }

    func removeContainer(id: String, force: Bool) async throws {
        var args = ["container", "delete"]
        if force { args.append("-f") }
        args.append(id)
        let _ = try await runCLI(args)
    }

    func inspectContainer(id: String) async throws -> DockerContainerInspect {
        let (code, output) = try await runCLI(["container", "inspect", id])
        guard code == 0 else {
            throw DockerAPIError.containerNotFound(id)
        }

        // Parse the inspect output and convert to Docker format
        let data = output.data(using: .utf8) ?? Data()
        return try parseContainerInspect(data, id: id)
    }

    func containerLogs(id: String, tail: Int?, follow: Bool) async throws -> String {
        var args = ["container", "logs"]
        if let tail = tail {
            args += ["-n", "\(tail)"]
        }
        if follow {
            args.append("-f")
        }
        args.append(id)
        let (code, output) = try await runCLI(args)
        guard code == 0 else { return "" }
        return output
    }

    /// Block until the container stops, then return its exit code (0 when the
    /// CLI doesn't report one). Backs the Docker `POST /containers/{id}/wait`
    /// route — `docker run` and `docker wait` depend on it.
    func waitContainer(id: String) async throws -> Int32 {
        while true {
            let (code, output) = try await runCLI(["container", "inspect", id])
            if code != 0 {
                throw DockerAPIError.containerNotFound(id)
            }
            guard let data = output.data(using: .utf8),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let entry = entries.first
            else {
                throw DockerAPIError.containerNotFound(id)
            }
            let state = (entry["status"] as? [String: Any])?["state"] as? String
            if state != "running" {
                return 0
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Image Operations

    /// Real on-disk size per image (blobs + unpacked snapshots), keyed by
    /// image digest — the same numbers the Images screen shows.
    private func onDiskImageSizes() async -> [String: Int64] {
        if let cache = imageSizeCache,
           Date().timeIntervalSince(cache.timestamp) < imageSizeCacheTTL {
            return cache.sizes
        }
        var sizes: [String: Int64] = [:]
        if let images = try? await ClientImage.list() {
            for image in images {
                if let size = try? await ImageDiskUsage.diskSize(for: image), size > 0 {
                    sizes[image.digest] = size
                }
            }
        }
        imageSizeCache = (Date(), sizes)
        return sizes
    }

    /// Looks up a cached size tolerating digest-format differences
    /// (with/without the "sha256:" prefix).
    private func imageSize(_ sizes: [String: Int64], forDigest digest: String) -> Int64? {
        if let size = sizes[digest] { return size }
        let hex = digest.split(separator: ":").last.map(String.init) ?? digest
        return sizes.first(where: { $0.key.split(separator: ":").last.map(String.init) == hex })?.value
    }

    func listImages() async throws -> [DockerImage] {
        let (code, output) = try await runCLI(["container", "image", "list", "--format", "json"])
        guard code == 0, let data = output.data(using: .utf8) else { return [] }

        guard let entries = try? JSONDecoder().decode([ImageListEntry].self, from: data) else { return [] }
        let sizes = await onDiskImageSizes()
        return entries.map { entry in
            let override = entry.configuration?.descriptor?.digest.flatMap { imageSize(sizes, forDigest: $0) }
            return entry.toDocker(sizeOverride: override)
        }
    }

    func pullImage(from input: String) async throws {
        // Parse image reference from input like "fromImage=nginx:latest"
        var imageRef = input
        if input.hasPrefix("fromImage=") {
            imageRef = String(input.dropFirst("fromImage=".count))
        }

        let (code, output) = try await runCLI(["container", "image", "pull", "--platform", Self.hostPlatform, imageRef], timeout: .seconds(1200))
        if code != 0 {
            throw DockerAPIError.imagePullFailed(output)
        }
    }

    /// Whether the reference is already in the local image store — lets
    /// createContainer skip the pull instead of refetching and re-unpacking
    /// on every create.
    func imageExists(_ ref: String) async throws -> Bool {
        let (code, _) = try await runCLI(["container", "image", "inspect", ref])
        return code == 0
    }

    func inspectImage(name: String) async throws -> DockerImageInspect {
        let (code, output) = try await runCLI(["container", "image", "inspect", name])
        guard code == 0 else {
            throw DockerAPIError.imageNotFound(name)
        }
        let image = try parseImageInspect(output, name: name)
        let sizes = await onDiskImageSizes()
        guard let size = imageSize(sizes, forDigest: image.id) else {
            return image
        }
        return DockerImageInspect(
            id: image.id,
            repoTags: image.repoTags,
            repoDigests: image.repoDigests,
            created: image.created,
            size: size,
            architecture: image.architecture,
            os: image.os,
            config: image.config
        )
    }

    func removeImage(name: String) async throws {
        let _ = try await runCLI(["container", "image", "delete", name])
    }

    // MARK: - Network Operations

    /// Created networks are real runtime networks (`container network
    /// create`); the in-memory registry below is only a fallback for
    /// clients that create networks while the runtime refuses (e.g. a name
    /// collision with the built-in NAT), keeping compose flows alive.
    private var virtualNetworks: [String: DockerNetwork] = [:]

    func createNetwork(name: String, labels: [String: String]?) async throws -> DockerNetwork {
        var args = ["container", "network", "create"]
        if let labels {
            for (key, value) in labels {
                args += ["--label", "\(key)=\(value)"]
            }
        }
        args.append(name)
        let (code, output) = try await runCLI(args)
        if code == 0 {
            return DockerNetwork(
                name: name,
                id: output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? name
                    : output.trimmingCharacters(in: .whitespacesAndNewlines),
                created: ISO8601DateFormatter().string(from: Date()),
                scope: "local",
                driver: "bridge",
                enableIPv6: false,
                ipam: DockerIPAM(driver: "default", config: nil),
                internal: false,
                attachable: false,
                ingress: false,
                options: nil,
                labels: labels
            )
        }

        // Fallback: bookkeeping-only network (all containers stay on NAT).
        let formatter = ISO8601DateFormatter()
        let created = formatter.string(from: Date())
        let network = DockerNetwork(
            name: name,
            id: "kegnet-\(UUID().uuidString.prefix(12).lowercased())",
            created: created,
            scope: "local",
            driver: "bridge",
            enableIPv6: false,
            ipam: DockerIPAM(driver: "default", config: nil),
            internal: false,
            attachable: false,
            ingress: false,
            options: nil,
            labels: labels
        )
        virtualNetworks[network.id] = network
        // Also index by name so name-based lookups find it.
        virtualNetworks[name] = network
        return network
    }

    func removeNetwork(id: String) async throws {
        // Real runtime networks delete by name or id; virtual bookkeeping
        // entries remove from the dictionary.
        if let network = virtualNetworks[id] {
            virtualNetworks.removeValue(forKey: id)
            virtualNetworks.removeValue(forKey: network.name)
            return
        }
        let _ = try await runCLI(["container", "network", "delete", id])
        // The built-in network can't be removed; mirror Docker's error by
        // simply reporting success for unknown ids (compose prunes eagerly).
    }

    func network(id: String) async -> DockerNetwork? {
        if let network = virtualNetworks[id] { return network }
        if let network = virtualNetworks.values.first(where: { $0.name == id }) { return network }
        return nil
    }

    func listNetworks() async throws -> [DockerNetwork] {
        let (code, output) = try await runCLI(["container", "network", "list", "--format", "json"])
        guard code == 0, let data = output.data(using: .utf8) else {
            // Return a default bridge network if CLI doesn't support network listing
            return [defaultBridgeNetwork()] + uniqueVirtualNetworks()
        }

        if let entries = try? JSONDecoder().decode([NetworkListEntry].self, from: data) {
            return entries.map { $0.toDocker() } + uniqueVirtualNetworks()
        }

        // If parsing fails, return a default bridge network
        return [defaultBridgeNetwork()] + uniqueVirtualNetworks()
    }

    private func uniqueVirtualNetworks() -> [DockerNetwork] {
        var seen = Set<String>()
        return virtualNetworks.values.compactMap { network in
            guard !seen.contains(network.id) else { return nil }
            seen.insert(network.id)
            return network
        }
    }

    private func defaultBridgeNetwork() -> DockerNetwork {
        DockerNetwork(
            name: "bridge",
            id: "bridge",
            created: "",
            scope: "local",
            driver: "bridge",
            enableIPv6: false,
            ipam: DockerIPAM(driver: "default", config: [
                DockerIPAMConfig(subnet: "172.17.0.0/16", gateway: "172.17.0.1")
            ]),
            internal: false,
            attachable: false,
            ingress: false,
            options: nil,
            labels: nil
        )
    }

    // MARK: - Volume Operations

    func listVolumes() async throws -> DockerVolumeListResponse {
        let (code, output) = try await runCLI(["container", "volume", "list", "--format", "json"])
        guard code == 0, let data = output.data(using: .utf8) else {
            return DockerVolumeListResponse(volumes: [], warnings: nil)
        }

        if let entries = try? JSONDecoder().decode([VolumeListEntry].self, from: data) {
            return DockerVolumeListResponse(
                volumes: entries.map { $0.toDocker() },
                warnings: nil
            )
        }

        return DockerVolumeListResponse(volumes: [], warnings: nil)
    }

    /// Creates a real runtime volume via the CLI.
    func createVolume(name: String) async throws -> DockerVolume {
        let (code, output) = try await runCLI(["container", "volume", "create", name])
        guard code == 0 else {
            throw DockerAPIError.badRequest("volume create failed: \(output)")
        }
        let created = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return DockerVolume(
            name: created.isEmpty ? name : created,
            driver: "local",
            mountpoint: "",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            scope: "local",
            labels: nil,
            options: nil
        )
    }

    func removeVolume(name: String) async throws {
        let (code, output) = try await runCLI(["container", "volume", "delete", name])
        guard code == 0 else {
            throw DockerAPIError.badRequest("volume delete failed: \(output)")
        }
    }

    // MARK: - System

    /// Disk usage for `docker system df`, translated from
    /// `container system df --format json`.
    func systemDiskUsage() async throws -> DockerSystemDF {
        let (code, output) = try await runCLI(["container", "system", "df", "--format", "json"])
        guard code == 0, let data = output.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DockerSystemDF(layersSize: 0, images: nil, containers: nil, volumes: nil, buildCache: nil)
        }

        let images = (raw["images"] as? [[String: Any]])?.map { entry in
            DockerDFImage(
                size: (entry["size"] as? Int64) ?? (entry["size"] as? Int).map(Int64.init) ?? 0,
                containers: (entry["containers"] as? Int64) ?? 0
            )
        }
        let containers = (raw["containers"] as? [[String: Any]])?.map { entry in
            DockerDFContainer(
                id: (entry["id"] as? String) ?? "",
                image: (entry["image"] as? String) ?? "",
                sizeRw: nil,
                sizeRootFs: nil
            )
        }
        let layersSize = images?.reduce(Int64(0)) { $0 + $1.size } ?? 0
        let volumes = (try? await listVolumes())?.volumes
        return DockerSystemDF(layersSize: layersSize, images: images, containers: containers, volumes: volumes, buildCache: nil)
    }

    /// Stops and deletes every stopped container; returns what was removed.
    func pruneContainers() async throws -> [DockerContainer] {
        let stopped = try await listContainers(all: true).filter { $0.state != "running" }
        for container in stopped {
            let _ = try? await runCLI(["container", "delete", "-f", container.id])
        }
        return stopped
    }

    /// Removes dangling images, or every image unused by a container when
    /// `all` is set — the `docker image prune` vs `docker image prune -a`
    /// split, mapped onto the runtime's own prune flag. Returns the refs
    /// the CLI reported removing (best-effort; its output format isn't
    /// stable enough to parse sizes from).
    func pruneImages(all: Bool) async throws -> [String] {
        var args = ["image", "prune"]
        if all { args.append("--all") }
        let (code, output) = try await runCLI(args, timeout: .seconds(300))
        guard code == 0 else {
            throw ContainerCLIFailure(message: output.isEmpty ? "image prune failed" : output)
        }
        return Self.removedRefs(from: output)
    }

    /// Removes volumes with no container references (`docker volume prune`).
    func pruneVolumes() async throws -> [String] {
        let (code, output) = try await runCLI(["volume", "prune"], timeout: .seconds(300))
        guard code == 0 else {
            throw ContainerCLIFailure(message: output.isEmpty ? "volume prune failed" : output)
        }
        return Self.removedRefs(from: output)
    }

    /// One removed ref per line of prune output, minus the "Reclaimed …"
    /// summary line the CLI always prints.
    private static func removedRefs(from output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().contains("reclaimed") }
    }

    // MARK: - System

    func systemInfo() async throws -> DockerInfo {
        let (_, containerOutput) = try await runCLI(["container", "list", "--format", "json"])
        let (_, allContainerOutput) = try await runCLI(["container", "list", "-a", "--format", "json"])
        let (_, imageOutput) = try await runCLI(["container", "image", "list", "--format", "json"])

        let runningCount = countJSONArrayEntries(containerOutput)
        let totalCount = countJSONArrayEntries(allContainerOutput)
        let imageCount = countJSONArrayEntries(imageOutput)

        // Get kernel version from uname
        var kernelVersion = "Darwin"
        let (unameCode, unameOutput) = try await runCLI(["uname", "-r"])
        if unameCode == 0 {
            kernelVersion = unameOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Get architecture
        var arch = "arm64"
        let (archCode, archOutput) = try await runCLI(["uname", "-m"])
        if archCode == 0 {
            arch = archOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return DockerInfo(
            id: UUID().uuidString,
            containers: totalCount,
            containersRunning: runningCount,
            containersStopped: totalCount - runningCount,
            images: imageCount,
            operatingSystem: "macOS (Apple Container)",
            architecture: arch,
            kernelVersion: kernelVersion,
            serverVersion: "keg-0.1.0",
            dockerRootDir: NSHomeDirectory() + "/.keg"
        )
    }

    func systemVersion() async throws -> DockerVersion {
        let (_, output) = try await runCLI(["container", "system", "version", "--format", "json"])
        let apiVersion = output.contains("\"version\"") ? "1.45" : "1.45"

        return DockerVersion(
            version: "0.1.0",
            apiVersion: apiVersion,
            minAPIVersion: "1.24",
            gitCommit: "keg",
            goVersion: "swift",
            os: "darwin",
            arch: "arm64",
            kernelVersion: "Darwin",
            buildTime: ""
        )
    }

    // MARK: - Parsing Helpers

    private func parseContainerInspect(_ data: Data, id: String) throws -> DockerContainerInspect {
        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let entry = jsonArray.first else {
            throw DockerAPIError.containerNotFound(id)
        }

        let cfg = entry["configuration"] as? [String: Any]
        // CLI ≥ 1.x: runtime state is an object, not a plain string.
        let statusObj = entry["status"] as? [String: Any]
        let status = (statusObj?["state"] as? String) ?? ""
        let networks = (statusObj?["networks"] as? [[String: Any]]) ?? []
        let firstNet = networks.first

        let state = DockerContainerState(
            status: status,
            running: status == "running",
            paused: false,
            restarting: false,
            dead: status == "stopped",
            pid: nil,
            exitCode: nil,
            startedAt: (statusObj?["startedDate"] as? String) ?? "",
            finishedAt: ""
        )

        let initProc = cfg?["initProcess"] as? [String: Any]
        let imgRef = (cfg?["image"] as? [String: Any])?["reference"] as? String

        return DockerContainerInspect(
            id: cfg?["id"] as? String ?? id,
            created: cfg?["creationDate"] as? String ?? "",
            path: initProc?["executable"] as? String ?? "",
            args: initProc?["arguments"] as? [String] ?? [],
            state: state,
            image: imgRef ?? "",
            name: "/" + (cfg?["id"] as? String ?? id),
            config: DockerContainerConfig(
                image: imgRef,
                cmd: initProc?["arguments"] as? [String],
                env: initProc?["environment"] as? [String],
                labels: cfg?["labels"] as? [String: String],
                tty: initProc?["terminal"] as? Bool,
                openStdin: nil,
                workingDir: initProc?["workingDirectory"] as? String
            ),
            networkSettings: DockerInspectNetworkSettings(
                ipAddress: firstNet?["ipv4Address"] as? String,
                gateway: firstNet?["ipv4Gateway"] as? String,
                ports: nil,
                networks: nil
            )
        )
    }

    private func parseImageInspect(_ output: String, name: String) throws -> DockerImageInspect {
        guard let data = output.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let entry = jsonArray.first else {
            throw DockerAPIError.imageNotFound(name)
        }

        let cfg = entry["configuration"] as? [String: Any]
        let descriptor = cfg?["descriptor"] as? [String: Any]
        let digest = descriptor?["digest"] as? String
        let size = (descriptor?["size"] as? Int).map { Int64($0) } ?? Int64(0)
        let annotations = descriptor?["annotations"] as? [String: String]
        let imgName = cfg?["name"] as? String
            ?? annotations?["com.apple.containerization.image.name"]
            ?? name

        // Created must be an RFC 3339 string for Docker clients (see
        // DockerImageInspect); fall back to the epoch when unknown.
        let created: String
        if let iso = cfg?["creationDate"] as? String, !iso.isEmpty {
            created = iso
        } else {
            created = "1970-01-01T00:00:00Z"
        }

        // Variant config (architecture / os / image config) lives per-platform.
        let variant = (entry["variants"] as? [[String: Any]])?.first
        let variantConfig = variant?["config"] as? [String: Any]
        let imageConfig = variantConfig?["config"] as? [String: Any]

        return DockerImageInspect(
            id: digest ?? "sha256:" + name,
            repoTags: [imgName],
            repoDigests: digest.map { ["\(imgName)@\($0)"] },
            created: created,
            size: size,
            architecture: variantConfig?["architecture"] as? String,
            os: variantConfig?["os"] as? String,
            config: DockerContainerConfig(
                image: imgName,
                cmd: imageConfig?["Cmd"] as? [String],
                env: imageConfig?["Env"] as? [String],
                labels: imageConfig?["Labels"] as? [String: String] ?? annotations,
                tty: imageConfig?["Tty"] as? Bool,
                openStdin: nil,
                workingDir: imageConfig?["WorkingDir"] as? String
            )
        )
    }
}

// MARK: - Intermediate parsing types

private struct ContainerListEntry: Codable {
    let configuration: Configuration
    let status: Status?

    struct Configuration: Codable {
        let id: String
        let creationDate: String?
        let labels: [String: String]?
        let image: ContainerImageRef?
        let initProcess: InitProcess?
        let publishedPorts: [PublishedPort]?

        struct ContainerImageRef: Codable {
            let reference: String
        }

        struct InitProcess: Codable {
            let executable: String?
            let arguments: [String]?
        }

        struct PublishedPort: Codable {
            let containerPort: Int
            let hostPort: Int?
            let hostAddress: String?
            let proto: String?
        }
    }

    /// CLI ≥ 1.x nests runtime state here; `state` is "running" / "stopped".
    struct Status: Codable {
        let state: String?
        let startedDate: String?
    }

    func toDocker() -> DockerContainer {
        let running = status?.state == "running"
        let created = Self.epochSeconds(from: configuration.creationDate)
        let started = Self.epochSeconds(from: status?.startedDate)
        let command = ([configuration.initProcess?.executable] + (configuration.initProcess?.arguments ?? []))
            .compactMap { $0 }
            .joined(separator: " ")
        let ports: [DockerPort]? = configuration.publishedPorts?.map { p in
            DockerPort(
                ip: p.hostAddress,
                privatePort: p.containerPort,
                publicPort: p.hostPort,
                type: p.proto ?? "tcp"
            )
        }
        let statusText: String
        if running {
            statusText = started > 0 ? "Up \(Self.humanDuration(since: started))" : "Up"
        } else {
            statusText = "Exited (0)"
        }
        return DockerContainer(
            id: configuration.id,
            names: ["/" + configuration.id],
            image: configuration.image?.reference ?? "",
            imageID: "",
            command: command,
            created: created,
            startedAt: started,
            state: running ? "running" : "exited",
            status: statusText,
            ports: ports,
            labels: configuration.labels,
            networkSettings: nil
        )
    }

    private static func epochSeconds(from isoDate: String?) -> Int64 {
        guard let isoDate else { return 0 }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoDate) else { return 0 }
        return Int64(date.timeIntervalSince1970)
    }

    private static func humanDuration(since epoch: Int64) -> String {
        let seconds = Int(Date().timeIntervalSince1970) - Int(epoch)
        guard seconds >= 0 else { return "less than a second" }
        let units: [(String, Int)] = [("day", 86400), ("hour", 3600), ("minute", 60)]
        for (name, unit) in units where seconds >= unit {
            let value = seconds / unit
            return "\(value) \(name)\(value == 1 ? "" : "s")"
        }
        return "less than a minute"
    }
}

private struct ImageListEntry: Codable {
    let id: String
    let configuration: Configuration?

    struct Configuration: Codable {
        let name: String?
        let creationDate: String?
        let descriptor: Descriptor?

        struct Descriptor: Codable {
            let digest: String?
            let size: Int64?
        }
    }

    func toDocker(sizeOverride: Int64? = nil) -> DockerImage {
        let reference = configuration?.name ?? id
        let digest = configuration?.descriptor?.digest
        let formatter = ISO8601DateFormatter()
        let created = configuration?.creationDate.flatMap { formatter.date(from: $0) }
            .map { Int64($0.timeIntervalSince1970) } ?? 0
        return DockerImage(
            id: digest ?? id,
            repoTags: [reference],
            repoDigests: digest.map { ["\(reference)@\($0)"] },
            created: created,
            size: sizeOverride ?? configuration?.descriptor?.size ?? 0,
            labels: nil
        )
    }
}

private struct NetworkListEntry: Codable {
    let id: String?
    let configuration: Configuration?

    struct Configuration: Codable {
        let name: String?
        let creationDate: String?
        let labels: [String: String]?
    }

    func toDocker() -> DockerNetwork {
        // `docker network ls` parses Created as a timestamp — never emit "".
        let formatter = ISO8601DateFormatter()
        let created = configuration?.creationDate.flatMap { formatter.date(from: $0) }
            .map { ISO8601DateFormatter.string(from: $0, timeZone: .current, formatOptions: .withInternetDateTime) }
            ?? ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: .withInternetDateTime)
        return DockerNetwork(
            name: configuration?.name ?? id ?? "unknown",
            id: id ?? UUID().uuidString,
            created: created,
            scope: "local",
            driver: "bridge",
            enableIPv6: false,
            ipam: DockerIPAM(driver: "default", config: nil),
            internal: false,
            attachable: false,
            ingress: false,
            options: nil,
            labels: configuration?.labels
        )
    }
}

private struct VolumeListEntry: Codable {
    let id: String?
    let configuration: Configuration?

    struct Configuration: Codable {
        let name: String?
        let driver: String?
        let source: String?
        let creationDate: String?
        let labels: [String: String]?
    }

    func toDocker() -> DockerVolume {
        DockerVolume(
            name: configuration?.name ?? id ?? "unknown",
            driver: configuration?.driver ?? "local",
            mountpoint: configuration?.source ?? "",
            createdAt: configuration?.creationDate,
            scope: "local",
            labels: configuration?.labels,
            options: nil
        )
    }
}

// MARK: - Helpers

private func countJSONArrayEntries(_ output: String) -> Int {
    guard let data = output.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
        return 0
    }
    return array.count
}

// MARK: - Errors

enum DockerAPIError: Error, CustomStringConvertible {
    case containerNotFound(String)
    case imageNotFound(String)
    case containerStartFailed(String)
    case imagePullFailed(String)
    case badRequest(String)
    case webhookNotFound(String)

    var description: String {
        switch self {
        case .containerNotFound(let id): return "Container not found: \(id)"
        case .imageNotFound(let name): return "Image not found: \(name)"
        case .containerStartFailed(let msg): return "Container start failed: \(msg)"
        case .imagePullFailed(let msg): return "Image pull failed: \(msg)"
        case .badRequest(let msg): return "Bad request: \(msg)"
        case .webhookNotFound(let id): return "Webhook not found: \(id)"
        }
    }
}
