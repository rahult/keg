import Foundation

struct AgentUseCase: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let macAdvantage: String
    let surfaces: [AgentUseCaseSurface]
    let capabilities: [String]
    let samplePrompts: [String]
    let draft: AgentUseCaseDraft

    static let all: [AgentUseCase] = [
        .downloadsDeskZero,
        .localCodingCopilot,
        .meetingPrepRouter,
        .researchCaptureDesk,
        .approvalInbox
    ]

    static let blankDraft = AgentUseCaseDraft(
        name: "",
        modelID: "claude-sonnet-4-6",
        description: "",
        systemPrompt: "",
        metadata: nil
    )

    static func byID(_ id: String?) -> AgentUseCase? {
        guard let id else { return nil }
        return all.first(where: { $0.id == id })
    }
}

struct AgentUseCaseDraft: Hashable, Sendable {
    let name: String
    let modelID: String
    let description: String
    let systemPrompt: String
    let metadata: [String: String]?
}

enum AgentUseCaseSurface: String, CaseIterable, Hashable, Identifiable, Sendable {
    case menuBar = "Menu Bar"
    case finder = "Finder"
    case shortcuts = "Shortcuts"
    case notifications = "Notifications"
    case companionWindow = "Companion Window"
    case activeApp = "Foreground App"
    case terminal = "Terminal / IDE"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .menuBar: return "menubar.rectangle"
        case .finder: return "folder"
        case .shortcuts: return "command"
        case .notifications: return "bell.badge"
        case .companionWindow: return "rectangle.on.rectangle"
        case .activeApp: return "macwindow"
        case .terminal: return "terminal"
        }
    }
}

private extension AgentUseCase {
    static let downloadsDeskZero = AgentUseCase(
        id: "downloads-desk-zero",
        title: "Downloads Desk Zero",
        summary: "Triage Finder selections, rename files, and sort incoming documents with review before cleanup.",
        macAdvantage: "Leans on Finder context, local folders, Quick Actions, and notifications instead of a browser upload flow.",
        surfaces: [.finder, .shortcuts, .notifications],
        capabilities: [
            "Summarize selected files before filing",
            "Rename or tag documents consistently",
            "Ask for approval before move, trash, or archive"
        ],
        samplePrompts: [
            "Organize these downloads into sensible folders and flag anything ambiguous.",
            "Rename these PDFs using project name, date, and sender."
        ],
        draft: AgentUseCaseDraft(
            name: "Downloads Desk Zero",
            modelID: "claude-sonnet-4-6",
            description: "Finder-first file triage agent for downloads, screenshots, and incoming documents.",
            systemPrompt: "You are a macOS file triage agent. Start from the user's current Finder selection or chosen folder. Explain what you plan to do, group files by intent, summarize unknown documents before renaming or moving them, and ask for approval before destructive actions like trashing or overwriting files.",
            metadata: [
                "keg.use_case_id": "downloads-desk-zero",
                "keg.use_case_surface": "finder"
            ]
        )
    )

    static let localCodingCopilot = AgentUseCase(
        id: "local-coding-copilot",
        title: "Local Coding Copilot",
        summary: "Use active IDE and terminal context to explain failures, draft edits, and keep coding loops grounded in local state.",
        macAdvantage: "Foreground-app awareness and terminal capture make it feel native to Xcode, VS Code, and local shells.",
        surfaces: [.activeApp, .terminal, .companionWindow],
        capabilities: [
            "Read current editor and terminal context",
            "Draft reviewable code changes",
            "Summarize build failures without copy-paste"
        ],
        samplePrompts: [
            "Why did this build fail, and what file should I inspect first?",
            "Draft a patch for this compiler error and explain the tradeoff."
        ],
        draft: AgentUseCaseDraft(
            name: "Local Coding Copilot",
            modelID: "claude-sonnet-4-6",
            description: "App-aware coding assistant for IDE, terminal, and local project workflows.",
            systemPrompt: "You are a local coding copilot for macOS. Ground every recommendation in the current IDE, file selection, and terminal state. Prefer reviewable diffs, concise root-cause analysis, and explicit next steps. Do not claim to have changed code unless the user approves the patch or action.",
            metadata: [
                "keg.use_case_id": "local-coding-copilot",
                "keg.use_case_surface": "terminal-ide"
            ]
        )
    )

    static let meetingPrepRouter = AgentUseCase(
        id: "meeting-prep-router",
        title: "Meeting Prep Router",
        summary: "Turn webpages, notes, and selected text into calendar events, prep briefs, and follow-up drafts.",
        macAdvantage: "Combines active window context, Quick Actions, and local notifications into a low-friction planning loop.",
        surfaces: [.activeApp, .shortcuts, .notifications],
        capabilities: [
            "Extract action items from the current window",
            "Draft meeting briefs from local notes and documents",
            "Queue reminders or approval prompts before sending"
        ],
        samplePrompts: [
            "Create a prep brief from this agenda and remind me 30 minutes before.",
            "Turn this flight table into calendar holds and a packing note."
        ],
        draft: AgentUseCaseDraft(
            name: "Meeting Prep Router",
            modelID: "claude-sonnet-4-6",
            description: "Context-aware planning agent for turning pages, notes, and selections into calendar-ready follow-through.",
            systemPrompt: "You are a meeting preparation agent for macOS. Use the user's current page, note, or selected content to extract commitments, draft concise prep notes, and propose calendar or reminder actions. Keep everything reviewable and highlight missing details before making changes.",
            metadata: [
                "keg.use_case_id": "meeting-prep-router",
                "keg.use_case_surface": "active-app"
            ]
        )
    )

    static let researchCaptureDesk = AgentUseCase(
        id: "research-capture-desk",
        title: "Research Capture Desk",
        summary: "Collect evidence from open windows and local files into reusable briefs, notes, and source bundles.",
        macAdvantage: "Works across browser tabs, local documents, and Finder selections without forcing everything into one web app.",
        surfaces: [.activeApp, .finder, .companionWindow],
        capabilities: [
            "Capture sources from the current window or folder",
            "Draft briefs with explicit provenance",
            "Bundle supporting files for follow-up work"
        ],
        samplePrompts: [
            "Summarize these notes and PDFs into a brief with open questions.",
            "Pull the key claims from this page and save a research snapshot."
        ],
        draft: AgentUseCaseDraft(
            name: "Research Capture Desk",
            modelID: "claude-sonnet-4-6",
            description: "Research agent for collecting local context into reusable notes, briefs, and source bundles.",
            systemPrompt: "You are a research capture agent for macOS. Collect context from the user's current window and selected local files, preserve provenance, separate facts from inferences, and produce concise briefs that can be reused later. Ask before creating or moving files outside the user's current workspace.",
            metadata: [
                "keg.use_case_id": "research-capture-desk",
                "keg.use_case_surface": "companion-window"
            ]
        )
    )

    static let approvalInbox = AgentUseCase(
        id: "approval-inbox",
        title: "Approval Inbox",
        summary: "Queue risky actions, drafts, and handoffs into a review inbox instead of silently acting on the desktop.",
        macAdvantage: "Menu bar presence plus actionable notifications make human-in-loop approval feel native, ambient, and fast.",
        surfaces: [.menuBar, .notifications, .companionWindow],
        capabilities: [
            "Collect pending actions into one review queue",
            "Explain why each action is proposed",
            "Require approval before side effects"
        ],
        samplePrompts: [
            "Draft these replies and queue them for approval.",
            "Watch for follow-ups, but ask me before sending or filing anything."
        ],
        draft: AgentUseCaseDraft(
            name: "Approval Inbox",
            modelID: "claude-sonnet-4-6",
            description: "Human-in-loop agent pattern for reviewing proposed actions before they touch apps, files, or messages.",
            systemPrompt: "You are an approval-first macOS agent. Draft actions, explain why each one matters, batch them into a review queue, and wait for explicit approval before changing files, sending messages, or mutating external systems. Optimize for trust, auditability, and quick yes/no review.",
            metadata: [
                "keg.use_case_id": "approval-inbox",
                "keg.use_case_surface": "menu-bar"
            ]
        )
    )
}
