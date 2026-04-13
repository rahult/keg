import SwiftUI
import ContainerResource
import ContainerAPIClient

// Wrapper types for SwiftUI Table conformance

struct IdentifiableContainer: Identifiable {
    let id: String
    let snapshot: ContainerSnapshot

    init(_ snapshot: ContainerSnapshot) {
        self.id = snapshot.id
        self.snapshot = snapshot
    }
}

struct IdentifiableImage: Identifiable {
    let id: String
    let image: ClientImage

    init(_ image: ClientImage) {
        self.id = image.reference
        self.image = image
    }
}
