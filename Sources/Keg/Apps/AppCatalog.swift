import Foundation
import Yams

// MARK: - Catalog Types

/// One form field the install wizard shows the user. Field ids become
/// `{{.FieldID}}` placeholders inside the app's compose template.
struct CatalogField: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable, Hashable {
        case text
        case password
        case number
        case port
        case directory
        case select
    }

    let id: String
    let label: String
    var kind: Kind = .text
    /// Pre-filled value. May reference `{{.KegDataDir}}`, expanded by the
    /// wizard before display.
    var defaultValue: String = ""
    var required: Bool = true
    /// Pre-fill with a generated secret; the user can reveal and regenerate.
    var generate: Bool = false
    /// Hidden behind the Advanced disclosure.
    var advanced: Bool = false
    var options: [String] = []
    var helpText: String?

    enum CodingKeys: String, CodingKey {
        case id, label, kind
        case defaultValue = "default"
        case required, generate, advanced, options
        case helpText = "help"
    }

    init(id: String, label: String, kind: Kind = .text, defaultValue: String = "",
         required: Bool = true, generate: Bool = false, advanced: Bool = false,
         options: [String] = [], helpText: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.defaultValue = defaultValue
        self.required = required
        self.generate = generate
        self.advanced = advanced
        self.options = options
        self.helpText = helpText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        generate = try container.decodeIfPresent(Bool.self, forKey: .generate) ?? false
        advanced = try container.decodeIfPresent(Bool.self, forKey: .advanced) ?? false
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        helpText = try container.decodeIfPresent(String.self, forKey: .helpText)
    }
}

/// Where the app's web interface lives after install. The wizard substitutes
/// the chosen host port for `{{.KegWebPort}}`; `path` is appended to
/// `http://127.0.0.1:<port>` for the Open button.
struct CatalogWebUI: Hashable, Codable, Sendable {
    var port: Int
    var path: String
}

/// One installable app in the catalog: friendly metadata plus a compose
/// template with `{{.Placeholder}}` slots. Templates must only use compose
/// keys Keg's orchestrator honors (image, environment, ports, volumes,
/// depends_on, networks, labels, container_name).
struct CatalogApp: Identifiable, Hashable, Codable, Sendable {
    /// Kebab-case unique id; doubles as the compose project namespace.
    let id: String
    let name: String
    let tagline: String
    let category: String
    /// SF Symbol shown on cards and in the detail header.
    let icon: String
    /// One-paragraph "what is this" for the install sheet.
    let summary: String
    /// Official website, shown on the tile menu and the detail page.
    var homepage: String?
    /// Upstream source repository (GitHub), same surfaces.
    var source: String?
    /// Setup facts the user must know (default logins, first-run notes).
    var note: String?
    var webUI: CatalogWebUI?
    var fields: [CatalogField]
    /// Set by a registry entry to retire an app (e.g. a broken image):
    /// hidden entries stay resolvable for installed apps but the browse
    /// grid doesn't offer them. A higher-precedence catalog tier can clear
    /// it by re-declaring the app with `hidden: false`.
    var hidden: Bool = false
    /// Raw compose YAML containing `{{.Placeholder}}` slots.
    let compose: String

    private enum CodingKeys: String, CodingKey {
        case id, name, tagline, category, icon, summary
        case homepage, source, note
        case webUI
        case fields
        case hidden
        case compose
    }

    init(id: String, name: String, tagline: String, category: String, icon: String,
         summary: String, homepage: String? = nil, source: String? = nil,
         note: String? = nil, webUI: CatalogWebUI? = nil,
         fields: [CatalogField] = [], hidden: Bool = false, compose: String) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.category = category
        self.icon = icon
        self.summary = summary
        self.homepage = homepage
        self.source = source
        self.note = note
        self.webUI = webUI
        self.fields = fields
        self.hidden = hidden
        self.compose = compose
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tagline = try container.decode(String.self, forKey: .tagline)
        category = try container.decode(String.self, forKey: .category)
        icon = try container.decode(String.self, forKey: .icon)
        summary = try container.decode(String.self, forKey: .summary)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        webUI = try container.decodeIfPresent(CatalogWebUI.self, forKey: .webUI)
        fields = try container.decodeIfPresent([CatalogField].self, forKey: .fields) ?? []
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        compose = try container.decode(String.self, forKey: .compose)
    }
}

// MARK: - Catalog Loading

enum AppCatalogError: Error, CustomStringConvertible {
    case parseFailed(String)
    case duplicateID(String)
    case invalidFieldID(app: String, field: String)

    var description: String {
        switch self {
        case .parseFailed(let message): return "App definition failed to parse: \(message)"
        case .duplicateID(let id): return "Two app definitions share the id '\(id)'"
        case .invalidFieldID(let app, let field): return "App '\(app)' has an invalid field id '\(field)'"
        }
    }
}

enum AppCatalog {
    /// Loads a catalog from YAML definitions, rejecting duplicates and
    /// malformed field ids so bad entries can never reach the wizard.
    static func load(yamlContents: [String]) throws -> [CatalogApp] {
        var apps: [CatalogApp] = []
        var seen = Set<String>()
        for yaml in yamlContents {
            let app: CatalogApp
            do {
                app = try YAMLDecoder().decode(CatalogApp.self, from: yaml)
            } catch {
                throw AppCatalogError.parseFailed(error.localizedDescription)
            }
            guard !seen.contains(app.id) else { throw AppCatalogError.duplicateID(app.id) }
            for field in app.fields {
                guard field.id.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                    throw AppCatalogError.invalidFieldID(app: app.id, field: field.id)
                }
            }
            seen.insert(app.id)
            apps.append(app)
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
