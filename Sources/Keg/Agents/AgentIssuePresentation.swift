import Foundation

struct AgentIssuePresentation {
    enum Kind: Equatable {
        case auth
        case offline
        case timeout
        case generic
    }

    let kind: Kind
    let message: String

    init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    init(error: Error) {
        if let managedError = error as? ManagedAgentsError {
            switch managedError {
            case .missingAPIKey:
                self.init(kind: .auth, message: "Authentication failed. Reconnect your Claude API key in Account.")
                return
            case .httpError(let statusCode, _):
                if statusCode == 401 || statusCode == 403 {
                    self.init(kind: .auth, message: "Authentication failed. Reconnect your Claude API key in Account.")
                    return
                }
                if statusCode == 408 {
                    self.init(kind: .timeout, message: "The Claude Agents service timed out. Retry in a moment.")
                    return
                }
            default:
                break
            }
        }

        if error is AgentAuthError {
            self.init(kind: .auth, message: "Authentication failed. Reconnect your Claude API key in Account.")
            return
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .dnsLookupFailed,
                 .internationalRoamingOff,
                 .callIsActive,
                 .dataNotAllowed:
                self.init(kind: .offline, message: "Claude Agents is offline or unreachable. Check your connection and retry.")
                return
            case .timedOut:
                self.init(kind: .timeout, message: "The Claude Agents service timed out. Retry in a moment.")
                return
            default:
                break
            }
        }

        self = AgentIssuePresentation(message: error.localizedDescription) ?? AgentIssuePresentation(kind: .generic, message: error.localizedDescription)
    }

    init?(message: String?) {
        guard let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        let lowercased = trimmed.lowercased()

        if lowercased.contains("http 401") ||
            lowercased.contains("http 403") ||
            lowercased.contains("not authenticated") ||
            lowercased.contains("authentication") ||
            lowercased.contains("api key not found") ||
            lowercased.contains("missing api key") {
            self.init(kind: .auth, message: "Authentication failed. Reconnect your Claude API key in Account.")
        } else if lowercased.contains("timed out") || lowercased.contains("timeout") {
            self.init(kind: .timeout, message: "The Claude Agents service timed out. Retry in a moment.")
        } else if lowercased.contains("offline") ||
                    lowercased.contains("unreachable") ||
                    lowercased.contains("not connected to the internet") ||
                    lowercased.contains("network connection was lost") ||
                    lowercased.contains("could not connect") ||
                    lowercased.contains("cannot connect") ||
                    lowercased.contains("cannot find host") ||
                    lowercased.contains("dns") {
            self.init(kind: .offline, message: "Claude Agents is offline or unreachable. Check your connection and retry.")
        } else {
            self.init(kind: .generic, message: trimmed)
        }
    }

    var actionTitle: String {
        switch kind {
        case .auth:
            return "Open Account"
        case .offline, .timeout, .generic:
            return "Retry"
        }
    }

    var showsUnavailableState: Bool {
        switch kind {
        case .offline, .timeout:
            return true
        case .auth, .generic:
            return false
        }
    }
}

enum AgentServiceReachability: Equatable {
    case unknown
    case reachable
    case unreachable
}

extension AppState {
    var isAgentServiceUnavailable: Bool {
        agentServiceReachability == .unreachable
    }

    func updateAgentServiceReachability(for message: String?) {
        guard let issue = AgentIssuePresentation(message: message) else {
            agentServiceReachability = .reachable
            return
        }

        switch issue.kind {
        case .offline, .timeout:
            agentServiceReachability = .unreachable
        case .auth, .generic:
            agentServiceReachability = .reachable
        }
    }
}
