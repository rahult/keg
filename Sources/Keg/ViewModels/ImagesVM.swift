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
                        group.addTask { try await ClientImage.getFullImageSize(image: image) }
                        group.addTask {
                            try await Task.sleep(for: .seconds(15))
                            throw CancellationError()
                        }
                        let result = try await group.next()!
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

    func pull(reference: String) async throws {
        guard !reference.isEmpty else { return }
        let normalized = try ClientImage.normalizeReference(reference)
        _ = try await ClientImage.pull(reference: normalized)
        await refresh()
    }

    func delete(reference: String) async throws {
        try await ClientImage.delete(reference: reference)
        await refresh()
    }
}
