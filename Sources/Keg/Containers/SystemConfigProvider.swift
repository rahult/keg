import ContainerAPIClient
import ContainerPersistence

/// Loads the container system configuration (registry defaults, DNS domain,
/// vminit image, etc.) from the layered TOML config files, matching how the
/// `container` CLI resolves them.
enum SystemConfigProvider {
    private actor Cache {
        var config: ContainerSystemConfig?

        func current() async -> ContainerSystemConfig {
            if let config {
                return config
            }
            let loaded = (try? await ConfigurationLoader.load()) ?? ContainerSystemConfig()
            config = loaded
            return loaded
        }
    }

    private static let cache = Cache()

    /// Shared config loaded once per process. Falls back to built-in defaults
    /// if the config files cannot be read.
    static func current() async -> ContainerSystemConfig {
        await cache.current()
    }
}
