import Foundation

/// Emits Docker Engine API events by diffing `container list -a` snapshots
/// once per second, and feeds the same events to the webhook manager.
/// Apple's runtime has no event stream in CLI 1.3.x, so polling is the
/// honest mechanism; the bus starts on first subscription and stops when
/// the last subscriber goes away.
actor ContainerEventBus {
    private let bridge: ContainerBridge
    private let webhooks: WebhookManager

    private var subscribers: [UUID: AsyncStream<DockerEvent>.Continuation] = [:]
    private var pollTask: Task<Void, Never>?
    /// Snapshot of (state, startedDate, image) per container id from the
    /// last poll. startedDate matters: a stop+start that completes between
    /// two polls leaves the state unchanged at "running".
    private var lastStates: [String: (state: String, started: String, image: String)] = [:]
    private var didFirstSnapshot = false

    private let pollInterval: TimeInterval

    init(bridge: ContainerBridge, webhooks: WebhookManager, pollInterval: TimeInterval = 1.0) {
        self.bridge = bridge
        self.webhooks = webhooks
        self.pollInterval = pollInterval
    }

    /// Subscribes to the event stream. The stream ends when the bus
    /// deinitializes or the consumer drops it.
    func subscribe() -> AsyncStream<DockerEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DockerEvent>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id: id) }
        }
        subscribers[id] = continuation
        startPollingIfNeeded()
        return stream
    }

    func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
        if subscribers.isEmpty {
            pollTask?.cancel()
            pollTask = nil
            // Forget state so the next subscriber doesn't get a burst of
            // synthetic transitions from a stale snapshot.
            didFirstSnapshot = false
            lastStates = [:]
        }
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func pollOnce() async {
        guard let containers = try? await bridge.listContainers(all: true) else { return }

        var seen = Set<String>()
        for container in containers {
            seen.insert(container.id)
            let image = container.image
            let state = container.state
            // startedDate (epoch seconds) distinguishes a fresh start from
            // an old one when the state didn't observably change.
            let started = String(container.startedAt ?? 0)

            guard didFirstSnapshot else {
                lastStates[container.id] = (state, started, image)
                continue
            }

            guard let previous = lastStates[container.id] else {
                // New container appeared: emit create, then start if running.
                lastStates[container.id] = (state, started, image)
                emit(containerID: container.id, image: image, action: "create", status: "create", name: container.names.first)
                if state == "running" {
                    emit(containerID: container.id, image: image, action: "start", status: "start", name: container.names.first)
                }
                continue
            }

            let stateChanged = previous.state != state
            // A restart that finishes between polls: still running, but a
            // newer startedDate. Surface it as start (after the die).
            let restarted = state == "running" && previous.state == "running" && previous.started != started
            if stateChanged || restarted {
                lastStates[container.id] = (state, started, image)
                if restarted {
                    emit(containerID: container.id, image: image, action: "die", status: "die", name: container.names.first)
                    emit(containerID: container.id, image: image, action: "start", status: "start", name: container.names.first)
                    continue
                }
                switch state {
                case "running":
                    emit(containerID: container.id, image: image, action: "start", status: "start", name: container.names.first)
                case "exited", "dead":
                    emit(containerID: container.id, image: image, action: "die", status: "die", name: container.names.first)
                default:
                    break
                }
            } else if previous.image != image {
                lastStates[container.id] = (state, started, image)
            }
        }

        // Containers that vanished were destroyed.
        if didFirstSnapshot {
            for (id, info) in lastStates where !seen.contains(id) {
                emit(containerID: id, image: info.image, action: "destroy", status: "destroy", name: nil)
                lastStates.removeValue(forKey: id)
            }
        }

        didFirstSnapshot = true
    }

    private func emit(
        containerID: String,
        image: String,
        action: String,
        status: String,
        name: String?
    ) {
        let now = Date()
        let event = DockerEvent(
            status: status,
            id: containerID,
            from: image.isEmpty ? nil : image,
            type: "container",
            action: action,
            actor: DockerEventActor(
                id: containerID,
                attributes: [
                    "name": name?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? containerID,
                    "image": image,
                ].filter { !$0.value.isEmpty }
            ),
            scope: "local",
            time: Int64(now.timeIntervalSince1970),
            timeNano: Int64(now.timeIntervalSince1970 * 1_000_000_000)
        )

        for continuation in subscribers.values {
            continuation.yield(event)
        }

        // Feed the same transition to registered webhooks.
        let webhookEvent: WebhookEvent?
        switch action {
        case "start": webhookEvent = .containerStart
        case "die": webhookEvent = .containerStop
        case "destroy": webhookEvent = .containerDestroy
        default: webhookEvent = nil
        }
        if let webhookEvent {
            let dockerContainer = DockerContainer(
                id: containerID,
                names: name.map { ["/" + $0] } ?? [],
                image: image,
                imageID: "",
                command: "",
                created: 0,
                startedAt: nil,
                state: action == "start" ? "running" : "exited",
                status: "",
                ports: nil,
                labels: nil,
                networkSettings: nil
            )
            Task {
                await webhooks.dispatch(event: webhookEvent, container: dockerContainer, image: nil)
            }
        }
    }
}
