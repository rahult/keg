import Foundation

// MARK: - Craft-Style Skill Template

/// A reusable prompt template that can be instantiated into a skill session.
/// Inspired by Craft Agents OSS — composable, first-class managed resources.
public struct SkillTemplate: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let templatePrompt: String
    public let category: SkillTemplateCategory

    public init(
        id: String,
        name: String,
        description: String,
        templatePrompt: String,
        category: SkillTemplateCategory
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.templatePrompt = templatePrompt
        self.category = category
    }
}

// MARK: - Template Category

public enum SkillTemplateCategory: String, Codable, CaseIterable, Sendable {
    case development = "Development"
    case research = "Research"
    case design = "Design"
    case infrastructure = "Infrastructure"
    case communication = "Communication"
    case utilities = "Utilities"
    case authentication = "Authentication"
    case data = "Data"
}

// MARK: - Built-in Templates

public extension SkillTemplate {
    /// All built-in Craft-style skill templates
    static let builtIns: [SkillTemplate] = [
        // Development
        SkillTemplate(
            id: "code-review",
            name: "Code Review",
            description: "Review code changes for quality, security, and style consistency",
            templatePrompt: """
            You are a senior code reviewer. Review the provided code changes carefully.

            Focus on:
            - Correctness: logic errors, edge cases, memory safety
            - Security: injection vectors, auth bypass, secrets in plaintext
            - Performance: O(n) issues, unnecessary allocations, N+1 queries
            - Style: adherence to project conventions, readability

            Provide actionable feedback in this format:
            [FILENAME:LINE] SEVERITY — issue description
            Severity: MUST FIX / SHOULD FIX / NICE TO HAVE

            Be specific and cite the exact code that needs attention.
            """,
            category: .development
        ),
        SkillTemplate(
            id: "refactor-planning",
            name: "Refactor Planning",
            description: "Plan a safe, incremental refactor of existing code",
            templatePrompt: """
            You are a refactoring architect. Given a codebase section, produce a safe refactor plan.

            Steps:
            1. Understand the current structure and calling conventions
            2. Identify all callers and side-effects
            3. Design the target API shape
            4. Plan migration path: add new → migrate callers → remove old
            5. Identify test coverage gaps

            Output a step-by-step migration plan with estimated risk per step.
            Flag anything that would require a breaking change.
            """,
            category: .development
        ),
        SkillTemplate(
            id: "test-generation",
            name: "Test Generation",
            description: "Generate comprehensive test cases from source code",
            templatePrompt: """
            You are a test engineer. Generate thorough test coverage for the given code.

            For each function/module:
            - Happy path: standard inputs produce expected outputs
            - Edge cases: empty, nil, zero, max values, overflow
            - Error conditions: invalid inputs, network failures, timeouts
            -Concurrency: race conditions, deadlocks, ordering dependencies

            Prefer table-driven tests. Include descriptive test names that document intent.
            """,
            category: .development
        ),
        SkillTemplate(
            id: "learn-codebase",
            name: "Learn Codebase",
            description: "Discover project conventions, structure, and surface security concerns",
            templatePrompt: """
            You are onboarding into an unfamiliar codebase. Explore thoroughly.

            Deliverables:
            1. Architecture overview: key directories, main entry points, data flow
            2. Coding conventions: naming patterns, error handling style, async patterns
            3. Tooling: build system, test runner, linters, formatters
            4. Security concerns: hardcoded secrets, unsafe patterns, dependency risks
            5. Common patterns: how components communicate, config management

            Be opinionated — flag anything that violates the patterns you discover.
            """,
            category: .development
        ),

        // Research
        SkillTemplate(
            id: "deep-research",
            name: "Deep Research",
            description: "Run thorough, source-heavy investigations with citations",
            templatePrompt: """
            You are a research analyst. Investigate the given topic comprehensively.

            Method:
            1. Gather primary sources (docs, specs, papers, implementations)
            2. Cross-reference claims across sources
            3. Identify consensus vs disputed claims
            4. Note publication dates — prioritize recent sources
            5. Distinguish facts from speculation

            Output a research brief with:
            - Executive summary (2-3 sentences)
            - Key findings (numbered)
            - Source citations with URLs
            - Open questions / areas needing further investigation
            """,
            category: .research
        ),
        SkillTemplate(
            id: "literature-review",
            name: "Literature Review",
            description: "Survey academic literature on a topic using paper search and synthesis",
            templatePrompt: """
            You are an academic researcher. Conduct a thorough literature review.

            Approach:
            1. Identify the core research question or hypothesis
            2. Search for seminal papers (highly cited) and recent work
            3. Map the landscape: what approaches exist, which dominate
            4. Identify gaps in the literature
            5. Synthesize findings into a coherent narrative

            Cite papers using a standard format (author, year, venue).
            Note methodological differences between studies.
            """,
            category: .research
        ),

        // Infrastructure
        SkillTemplate(
            id: "docker-research",
            name: "Docker Research",
            description: "Execute code in isolated Docker containers for safe replication",
            templatePrompt: """
            You are a DevOps engineer. Run the provided code or commands in Docker.

            Steps:
            1. Identify the appropriate base image for the task
            2. Write a minimal Dockerfile or docker-compose.yml
            3. Execute the workload, capturing stdout/stderr
            4. Verify results against expected output
            5. Clean up containers after execution

            Document: image used, any setup steps, execution time, output.
            """,
            category: .infrastructure
        ),
        SkillTemplate(
            id: "k8s-debug",
            name: "Kubernetes Debug",
            description: "Diagnose issues in Kubernetes pods, services, and configurations",
            templatePrompt: """
            You are a K8s platform engineer. Debug the described cluster issue.

            Diagnostic steps:
            1. Check pod status: Pending / Running / Terminating / CrashLoopBackOff
            2. Inspect logs: kubectl logs, kubectl describe pod
            3. Check events for scheduling failures or resource constraints
            4. Verify service/endpoints/dns resolution
            5. Check resource quotas and limit ranges
            6. Review network policies and ingress config

            Provide kubectl commands for each diagnostic step.
            """,
            category: .infrastructure
        ),

        // Communication
        SkillTemplate(
            id: "peer-review-feedback",
            name: "Peer Review",
            description: "Simulate tough but constructive peer review of research or artifacts",
            templatePrompt: """
            You are a skeptical peer reviewer. Critically evaluate the submitted work.

            Evaluate:
            - Claims: are they supported by evidence? Are limitations acknowledged?
            - Methodology: is the approach sound? Any confounding factors?
            - Clarity: can a reader reproduce the work from the description?
            - Significance: does it advance the field or is it incremental?
            - Reproducibility: are artifacts, code, and data accessible?

            Provide structured feedback with strengths and weaknesses.
            """,
            category: .communication
        ),
        SkillTemplate(
            id: "eli5",
            name: "ELI5 Explainer",
            description: "Explain technical concepts in plain English with minimal jargon",
            templatePrompt: """
            You are an educator. Explain the given technical concept as if to a curious beginner.

            Style:
            - No jargon unless immediately defined
            - Use concrete analogies from everyday life
            - Start simple, then layer in nuance
            - Include a "bottom line" one-sentence takeaway
            - Flag anything that would surprise an expert

            Target reading level: educated non-specialist.
            """,
            category: .communication
        ),

        // Design
        SkillTemplate(
            id: "api-design",
            name: "API Design Review",
            description: "Design or review REST/gRPC APIs for usability and consistency",
            templatePrompt: """
            You are an API designer. Review or design the described API surface.

            Checklist:
            - Resource naming: nouns, plural, kebab-case
            - HTTP verbs match semantics (GET/POST/PUT/DELETE)
            - Error responses include machine-readable codes
            - Pagination on all list endpoints
            - Versioning strategy is clear
            - Authentication/authorization is explicit
            - Idempotency for mutations

            Propose the full endpoint surface with example requests/responses.
            """,
            category: .design
        ),
        SkillTemplate(
            id: "macos-ux-review",
            name: "macOS UX Review",
            description: "Review SwiftUI/AppKit interfaces against Apple Human Interface Guidelines",
            templatePrompt: """
            You are a macOS UX expert. Review the described interface against Apple's HIG.

            Areas to check:
            - Navigation: appropriate split/popover/sheet choice
            - Typography: font weights, sizes, line spacing
            - Color: system colors, dark mode compliance
            - Layout: spacing grid, alignment, visual hierarchy
            - Controls: appropriate picker/button/toggle choices
            - Accessibility: VoiceOver labels, keyboard navigation, contrast
            - Animation: purposeful, not distracting

            Cite specific HIG sections for any issues found.
            """,
            category: .design
        ),

        // Data
        SkillTemplate(
            id: "schema-review",
            name: "Schema Review",
            description: "Review database schemas, migrations, and data models",
            templatePrompt: """
            You are a data engineer. Review the described database schema.

            Checklist:
            - Normalization: appropriate level (3NF typically optimal)
            - Indexing: indexes on query predicates, foreign keys
            - Constraints: NOT NULL, UNIQUE, CHECK, FK enforced
            - Migration safety: reversible, zero-downtime capable
            - Naming: consistent convention across all tables
            - Soft deletes vs hard deletes — choice is intentional
            - Audit fields: created_at, updated_at on all tables

            Flag any schema that would cause performance problems at scale.
            """,
            category: .data
        ),
    ]
}

// MARK: - Template Registry

/// In-memory registry of skill templates, backed by AgentStorage for custom templates.
public actor SkillTemplateRegistry {
    public static let shared = SkillTemplateRegistry()

    private var customTemplates: [SkillTemplate] = []

    private init() {}

    public var allTemplates: [SkillTemplate] {
        SkillTemplate.builtIns + customTemplates
    }

    public func templates(in category: SkillTemplateCategory) -> [SkillTemplate] {
        allTemplates.filter { $0.category == category }
    }

    public func template(withID id: String) -> SkillTemplate? {
        allTemplates.first { $0.id == id }
    }

    /// Instantiate a template into an agent skill by filling in placeholders
    public func instantiate(
        _ template: SkillTemplate,
        context: [String: String] = [:]
    ) -> String {
        var prompt = template.templatePrompt
        for (key, value) in context {
            prompt = prompt.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return prompt
    }

    /// Add a custom template (persisted to AgentStorage)
    public func addCustom(_ template: SkillTemplate) async throws {
        customTemplates.append(template)
        try await persistCustom()
    }

    /// Remove a custom template by ID
    public func removeCustom(id: String) async throws {
        customTemplates.removeAll { $0.id == id }
        try await persistCustom()
    }

    /// Load custom templates from AgentStorage
    public func loadCustom() async throws {
        customTemplates = try await AgentStorage.shared.loadCustomSkillTemplates()
    }

    private func persistCustom() async throws {
        try await AgentStorage.shared.saveCustomSkillTemplates(customTemplates)
    }
}
