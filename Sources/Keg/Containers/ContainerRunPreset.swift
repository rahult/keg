import Foundation

/// Quick-start presets for well-known demo images. When the Run sheet opens
/// for a matching image (from the containers quick start, the welcome sheet,
/// or "Run" on an image), every field is prefilled so a first-time user can
/// just press Return instead of decoding an empty form.
struct ContainerRunPreset: Sendable, Equatable {
    var image: String
    var name: String
    var ports: String
    var command: String = ""
    var envVars: String = ""
    /// `nil` leaves the sheet's default resources in place.
    var cpus: Int?
    var memory: String?
    var detached = true
    /// Shown as a banner at the top of the Run sheet — sets expectations
    /// (e.g. "prints a greeting and exits") so the result isn't a surprise.
    var blurb: String
    /// URL to offer once the container is running (web-server style demos).
    var successURL: String?

    /// hello-world exits immediately after printing — run it in the
    /// foreground so the greeting lands in the sheet instead of vanishing
    /// into a detached container nobody sees.
    static let helloWorld = ContainerRunPreset(
        image: "hello-world",
        name: "hello-world",
        ports: "",
        cpus: 1,
        memory: "512M",
        detached: false,
        blurb: "Downloads a tiny test image, prints a greeting, and exits. Nothing keeps running and nothing touches your Mac.",
        successURL: nil
    )

    static let webServer = ContainerRunPreset(
        image: "nginx",
        name: "web-server",
        ports: "8080:80",
        cpus: nil,
        memory: nil,
        detached: true,
        blurb: "Runs the nginx web server. When it's up, open http://localhost:8080 in your browser.",
        successURL: "http://localhost:8080"
    )

    /// The preset for an image reference, if it's a known quick start.
    /// Tolerates tags and registry hosts: "docker.io/library/nginx:latest"
    /// matches the web-server preset just like bare "nginx".
    static func matching(image: String) -> ContainerRunPreset? {
        let lastPath = image.lowercased().split(separator: "/").last.map(String.init) ?? image.lowercased()
        let bare = lastPath.split(separator: ":").first.map(String.init) ?? lastPath
        switch bare {
        case "hello-world": return .helloWorld
        case "nginx": return .webServer
        default: return nil
        }
    }
}
