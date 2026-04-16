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
            // Load sizes in background
            for image in images {
                if let size = try? await ClientImage.getFullImageSize(image: image) {
                    await MainActor.run {
                        imageSizes[image.reference] = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                    }
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
