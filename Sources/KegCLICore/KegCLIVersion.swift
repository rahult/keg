import Foundation

/// Version reporting for the `keg` CLI. Inside Keg.app (the normal case)
/// the app bundle's marketing version is authoritative; a binary in
/// SharedSupport/bin doesn't get Bundle.main for the app, so the bundle is
/// found by walking up from the executable. Standalone dev builds fall
/// back to a dev marker.
public enum KegCLIVersion {
    public static var current: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for _ in 0..<6 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                let plist = url.appendingPathComponent("Contents/Info.plist")
                if let dict = NSDictionary(contentsOf: plist),
                   let version = dict["CFBundleShortVersionString"] as? String, !version.isEmpty {
                    return version
                }
            }
        }
        return "0.0.0-dev"
    }
}
