import Foundation
import ContainerAPIClient

/// Computes the real on-disk footprint of an image, using the same store
/// layout that `container system df` reports on: compressed blobs in the
/// content store plus the unpacked snapshot(s) for each platform.
///
/// The framework's `ClientImage.getFullImageSize` only sums manifest
/// descriptor sizes (the compressed download size), which is a fraction of
/// the disk actually consumed — every pulled image is unpacked into an ext4
/// snapshot. Reading the store directly keeps the Images list consistent
/// with the Dashboard's disk usage figures.
enum ImageDiskUsage {
    /// Root of the container data store: the Data Location configured in
    /// Settings (the same root `AppState.startSystem` hands the apiserver),
    /// or the container-apiserver default when nothing is configured.
    static var storeRoot: URL {
        if let configured = ContainerCLI.configuredAppRoot {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.container", isDirectory: true)
    }

    /// On-disk bytes for `image`: allocated size of every referenced content
    /// blob plus the allocated size of the unpacked snapshot directory for
    /// each platform manifest.
    static func diskSize(for image: ClientImage) async throws -> Int64 {
        let blobsDir = storeRoot.appendingPathComponent("content/blobs/sha256", isDirectory: true)
        let snapshotsDir = storeRoot.appendingPathComponent("snapshots", isDirectory: true)

        var blobHexes: Set<String> = [hex(image.digest)]
        var snapshotHexes: Set<String> = []

        let index = try await image.index()
        for descriptor in index.manifests {
            blobHexes.insert(hex(descriptor.digest))

            guard descriptor.platform != nil else { continue }
            if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
               referenceType == "attestation-manifest" {
                continue
            }

            // One snapshot directory per platform manifest.
            snapshotHexes.insert(hex(descriptor.digest))

            // Config and layer blobs backing this manifest.
            if let platform = descriptor.platform,
               let manifest = try? await image.manifest(for: platform) {
                blobHexes.insert(hex(manifest.config.digest))
                for layer in manifest.layers {
                    blobHexes.insert(hex(layer.digest))
                }
            }
        }

        var total: UInt64 = 0
        for hexDigest in blobHexes {
            total += allocatedSize(of: blobsDir.appendingPathComponent(hexDigest, isDirectory: false))
        }
        for hexDigest in snapshotHexes {
            total += allocatedSize(of: snapshotsDir.appendingPathComponent(hexDigest, isDirectory: true))
        }
        return Int64(total)
    }

    /// Hex portion of a digest string ("sha256:abc…" -> "abc…"), matching the
    /// store's path component naming.
    private static func hex(_ digest: String) -> String {
        guard let separator = digest.lastIndex(of: ":") else { return digest }
        return String(digest[digest.index(after: separator)...])
    }

    /// Allocated on-disk size of a file or directory (recursive), mirroring
    /// the framework's FileManager.allocatedSize. Missing paths contribute 0.
    private static func allocatedSize(of url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            return UInt64(values?.totalFileAllocatedSize ?? 0)
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var size: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            size += UInt64(values?.totalFileAllocatedSize ?? 0)
        }
        return size
    }
}
