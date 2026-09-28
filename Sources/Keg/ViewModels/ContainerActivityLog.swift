import Foundation
import ContainerResource

/// One observed lifecycle transition for a container.
struct ContainerEvent: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case started
        case stopped
        case stopping
        case unknown

        var label: String {
            switch self {
            case .started: return "Started"
            case .stopped: return "Stopped"
            case .stopping: return "Stopping…"
            case .unknown: return "Runtime lost track of this container"
            }
        }
    }

    let id = UUID()
    let containerID: String
    let date: Date
    let kind: Kind
}

/// Session-scoped log of container lifecycle transitions, derived by
/// diffing list snapshots (the runtime exposes no event stream Keg can
/// subscribe to). Shared so events survive inspector open/close while Keg
/// runs. The first sighting seeds the baseline without logging — a fresh
/// launch must not read as 65 simultaneous "started" events.
@Observable
@MainActor
final class ContainerActivityLog {
    static let shared = ContainerActivityLog()

    private(set) var events: [ContainerEvent] = []
    private var lastStatuses: [String: RuntimeStatus] = [:]
    private var seeded = false

    private let totalCap = 500

    /// Diff `containers` against the previous sighting; append events for
    /// every status transition. Call after each list refresh.
    func observe(_ containers: [ContainerSnapshot]) {
        defer {
            seeded = true
            trimIfNeeded()
        }
        guard seeded else {
            lastStatuses = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0.status) })
            return
        }

        let now = Date()
        for container in containers {
            let previous = lastStatuses[container.id]
            lastStatuses[container.id] = container.status
            // nil previous = first sighting this session; not a transition.
            guard let previous, previous != container.status else { continue }
            let kind: ContainerEvent.Kind
            switch container.status {
            case .running: kind = .started
            case .stopped: kind = .stopped
            case .stopping: kind = .stopping
            case .unknown: kind = .unknown
            }
            events.insert(ContainerEvent(containerID: container.id, date: now, kind: kind), at: 0)
        }

        // Containers that no longer exist can't transition again.
        let live = Set(containers.map(\.id))
        lastStatuses = lastStatuses.filter { live.contains($0.key) }
    }

    func events(for containerID: String) -> [ContainerEvent] {
        events.filter { $0.containerID == containerID }
    }

    private func trimIfNeeded() {
        guard events.count > totalCap else { return }
        events.removeLast(events.count - totalCap)
    }
}
