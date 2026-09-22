import Foundation
import ContainerAPIClient
import ContainerResource

@Observable
@MainActor
final class ImagesVM {
    var images: [ClientImage] = []
    var imageSizes: [String: String] = [:]
    var isLoading = false
    var errorMessage: String?
    var searchText = ""

    var filteredImages: [ClientImage] {
        guard !searchText.isEmpty else { return images }
        return images.filter {
            $0.reference.localizedCaseInsensitiveContains(searchText)
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            images = try await ClientImage.list()
            // Clear stale entries before reloading sizes
            imageSizes = [:]
            // Load sizes in background with timeout
            for image in images {
                do {
                    let size = try await withThrowingTaskGroup(of: Int64.self) { group in
                        group.addTask {
                            // Real on-disk footprint (blobs + unpacked snapshot),
                            // matching `container system df`.
                            let diskSize = try await ImageDiskUsage.diskSize(for: image)
                            if diskSize > 0 { return diskSize }
                            // Store not readable — fall back to the
                            // compressed manifest size.
                            return try await ClientImage.getFullImageSize(image: image)
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(15))
                            throw CancellationError()
                        }
                        let result = try await group.next() ?? 0
                        group.cancelAll()
                        return result
                    }
                    imageSizes[image.reference] = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                } catch {
                    imageSizes[image.reference] = "N/A"
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Pulls an image. `architecture` selects the image variant: "arm64"
    /// (native) or "amd64" (x86 images via Rosetta). The platform is always
    /// pinned — an unpinned pull unpacks every variant in the index.
    func pull(reference: String, architecture: String = "arm64") async throws {
        guard !reference.isEmpty else { return }
        let config = await SystemConfigProvider.current()
        let normalized = try ClientImage.normalizeReference(reference, containerSystemConfig: config)
        if architecture == "arm64" {
            _ = try await ClientImage.pull(reference: normalized, platform: .current, containerSystemConfig: config)
        } else {
            // Rosetta path: the CLI accepts an explicit platform and runs
            // amd64 images translated when the runtime has Rosetta enabled.
            let (code, output) = try await ContainerCLI.run([
                "container", "image", "pull", "--platform", "linux/\(architecture)", normalized,
            ], timeout: .seconds(1200))
            guard code == 0 else {
                throw ContainerCLIFailure(message: output.isEmpty ? "Pull failed" : output)
            }
        }
        await refresh()
    }

    func delete(reference: String) async throws {
        try await ClientImage.delete(reference: reference)
        await refresh()
    }

    /// Create an additional reference for an existing image.
    func tag(source: String, target: String) async throws {
        let (code, output) = try await ContainerCLI.run(["container", "image", "tag", source, target])
        guard code == 0 else {
            throw ContainerCLIFailure(message: output.isEmpty ? "Tag failed" : output)
        }
        await refresh()
    }

    /// Remove unused images, or all images when `all` is true.
    func prune(all: Bool) async throws {
        var args = ["container", "image", "prune"]
        if all { args.append("--all") }
        let (code, output) = try await ContainerCLI.run(args)
        guard code == 0 else {
            throw ContainerCLIFailure(message: output.isEmpty ? "Prune failed" : output)
        }
        await refresh()
    }
}

struct ContainerCLIFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
