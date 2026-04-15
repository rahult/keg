import Foundation

enum AgentAutomationCapability: String, CaseIterable, Identifiable, Sendable {
    case menuBar = "Menu Bar"
    case activeApp = "Active App"
    case finderSelection = "Finder Selection"
    case terminalSnapshot = "Terminal Snapshot"
    case pageContext = "Page Context"
    case notifications = "Notifications"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .menuBar: return "menubar.rectangle"
        case .activeApp: return "macwindow"
        case .finderSelection: return "folder"
        case .terminalSnapshot: return "terminal"
        case .pageContext: return "globe"
        case .notifications: return "bell.badge"
        }
    }
}

enum AgentCapabilityStatus: String, Sendable {
    case ready = "Ready"
    case attention = "Needs Attention"
    case unavailable = "Unavailable"

    var badgeText: String { rawValue }
}

struct AgentCapabilityCheck: Identifiable, Hashable, Sendable {
    let capability: AgentAutomationCapability
    let status: AgentCapabilityStatus
    let summary: String
    let remediation: String?

    var id: AgentAutomationCapability { capability }
}

enum AgentNotificationStatus: String, Sendable {
    case unknown
    case notDetermined
    case authorized
    case provisional
    case denied

    var summary: String {
        switch self {
        case .unknown: return "Notification access unknown"
        case .notDetermined: return "Notification access not requested yet"
        case .authorized: return "Notifications enabled"
        case .provisional: return "Notifications provisionally enabled"
        case .denied: return "Notifications denied"
        }
    }
}

struct AgentDesktopContextSnapshot: Hashable, Sendable {
    var activeAppName: String?
    var selectedFiles: [String]
    var terminalAppName: String?
    var terminalSnapshot: String?
    var pageTitle: String?
    var pageURL: String?
    var selectedText: String?
    var capturedAt: Date

    init(
        activeAppName: String? = nil,
        selectedFiles: [String] = [],
        terminalAppName: String? = nil,
        terminalSnapshot: String? = nil,
        pageTitle: String? = nil,
        pageURL: String? = nil,
        selectedText: String? = nil,
        capturedAt: Date = .now
    ) {
        self.activeAppName = activeAppName
        self.selectedFiles = selectedFiles
        self.terminalAppName = terminalAppName
        self.terminalSnapshot = terminalSnapshot
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.selectedText = selectedText
        self.capturedAt = capturedAt
    }

    var selectedFileCount: Int { selectedFiles.count }

    var hasPageContext: Bool {
        !(pageTitle?.isEmpty ?? true) || !(pageURL?.isEmpty ?? true) || !(selectedText?.isEmpty ?? true)
    }

    var hasTerminalSnapshot: Bool {
        !(terminalSnapshot?.isEmpty ?? true)
    }
}

struct AgentAutomationState: Hashable, Sendable {
    var context: AgentDesktopContextSnapshot
    var notificationStatus: AgentNotificationStatus
    var lastError: String?

    init(
        context: AgentDesktopContextSnapshot = .init(),
        notificationStatus: AgentNotificationStatus = .unknown,
        lastError: String? = nil
    ) {
        self.context = context
        self.notificationStatus = notificationStatus
        self.lastError = lastError
    }
}

enum AgentApprovalStatus: String, Codable, Sendable {
    case pending = "Pending"
    case approved = "Approved"
    case rejected = "Rejected"
}

struct AgentApprovalItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let useCaseID: String
    let title: String
    let summary: String
    let source: String
    let createdAt: Date
    var status: AgentApprovalStatus

    init(
        id: UUID = UUID(),
        useCaseID: String,
        title: String,
        summary: String,
        source: String,
        createdAt: Date = .now,
        status: AgentApprovalStatus = .pending
    ) {
        self.id = id
        self.useCaseID = useCaseID
        self.title = title
        self.summary = summary
        self.source = source
        self.createdAt = createdAt
        self.status = status
    }
}

extension AgentApprovalItem {
    static func preview(for useCase: AgentUseCase, context: AgentDesktopContextSnapshot) -> AgentApprovalItem {
        let source = context.activeAppName ?? "Mac desktop"
        let summary: String

        switch useCase.id {
        case "downloads-desk-zero":
            let count = max(context.selectedFileCount, 3)
            summary = "Review a proposed cleanup plan for \(count) Finder items before any files move or trash."
        case "local-coding-copilot":
            summary = "Approve a draft patch and terminal-guided fix based on current editor and shell context."
        case "meeting-prep-router":
            summary = "Review a prep brief and proposed reminder actions generated from current notes or page context."
        case "research-capture-desk":
            summary = "Approve a captured research brief and supporting source bundle from current desktop context."
        default:
            summary = "Review a queued desktop action before it changes files, messages, or app state."
        }

        return AgentApprovalItem(
            useCaseID: useCase.id,
            title: "\(useCase.title) review",
            summary: summary,
            source: source
        )
    }
}

extension AgentUseCase {
    var requiredCapabilities: [AgentAutomationCapability] {
        switch id {
        case "downloads-desk-zero":
            return [.finderSelection, .notifications]
        case "local-coding-copilot":
            return [.activeApp, .terminalSnapshot]
        case "meeting-prep-router":
            return [.activeApp, .pageContext, .notifications]
        case "research-capture-desk":
            return [.activeApp, .finderSelection, .pageContext]
        case "approval-inbox":
            return [.menuBar, .notifications]
        default:
            return [.activeApp]
        }
    }

    func capabilityChecks(using automation: AgentAutomationState) -> [AgentCapabilityCheck] {
        requiredCapabilities.map { capability in
            switch capability {
            case .menuBar:
                return AgentCapabilityCheck(
                    capability: capability,
                    status: .ready,
                    summary: "Keg menu bar surface is available for lightweight approvals and quick actions.",
                    remediation: nil
                )
            case .activeApp:
                if let app = automation.context.activeAppName {
                    return AgentCapabilityCheck(
                        capability: capability,
                        status: .ready,
                        summary: "Foreground app detected: \(app).",
                        remediation: nil
                    )
                }
                return AgentCapabilityCheck(
                    capability: capability,
                    status: .attention,
                    summary: "No foreground app context captured yet.",
                    remediation: "Open target app, then refresh live context."
                )
            case .finderSelection:
                if automation.context.selectedFileCount > 0 {
                    return AgentCapabilityCheck(
                        capability: capability,
                        status: .ready,
                        summary: "\(automation.context.selectedFileCount) Finder item(s) available for context.",
                        remediation: nil
                    )
                }
                return AgentCapabilityCheck(
                    capability: capability,
                    status: .attention,
                    summary: "No Finder selection captured.",
                    remediation: "Select files in Finder to give this use case live input."
                )
            case .terminalSnapshot:
                if let app = automation.context.terminalAppName,
                   automation.context.hasTerminalSnapshot {
                    return AgentCapabilityCheck(
                        capability: capability,
                        status: .ready,
                        summary: "Terminal snapshot captured from \(app).",
                        remediation: nil
                    )
                }
                return AgentCapabilityCheck(
                    capability: capability,
                    status: .attention,
                    summary: "No terminal transcript captured.",
                    remediation: "Bring Terminal or iTerm to the front, then refresh live context."
                )
            case .pageContext:
                if automation.context.hasPageContext {
                    let label = automation.context.pageTitle ?? automation.context.pageURL ?? "Current page"
                    return AgentCapabilityCheck(
                        capability: capability,
                        status: .ready,
                        summary: "Page context available from \(label).",
                        remediation: nil
                    )
                }
                return AgentCapabilityCheck(
                    capability: capability,
                    status: .attention,
                    summary: "No browser page context captured.",
                    remediation: "Bring Safari or a Chromium browser to the front, then refresh live context."
                )
            case .notifications:
                switch automation.notificationStatus {
                case .authorized, .provisional:
                    return AgentCapabilityCheck(
                        capability: capability,
                        status: .ready,
                        summary: automation.notificationStatus.summary,
                        remediation: nil
                    )
                case .denied:
                    return AgentCapabilityCheck(
                        capability: capability,
                        status: .unavailable,
                        summary: automation.notificationStatus.summary,
                        remediation: "Enable notifications for Keg in System Settings to use approval alerts."
                    )
                case .notDetermined, .unknown:
                    return AgentCapabilityCheck(
                        capability: capability,
                        status: .attention,
                        summary: automation.notificationStatus.summary,
                        remediation: "Request notification access to power review prompts and approval alerts."
                    )
                }
            }
        }
    }
}
