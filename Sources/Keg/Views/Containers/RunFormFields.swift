import SwiftUI
import UniformTypeIdentifiers

/// The "Volumes" row shared by the Run and Edit & Recreate sheets.
///
/// A bare text field with a `host:container` prompt confused people — it
/// reads like Docker named volumes are a thing (they aren't; Keg shares real
/// Mac folders), and the CLI's own error for a bad mount is a raw failure.
/// This wraps the field with a plain-language helper line, a folder picker,
/// and live validation so problems surface before the run, in human terms.
struct VolumeMountField: View {
    @Binding var text: String

    @State private var showImporter = false

    private var problems: [String] {
        ContainerRunArguments.volumeMountProblems(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Volumes")
                    .font(.callout)
                Spacer()
                Button {
                    showImporter = true
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                .controlSize(.small)
                .help("Pick a folder on your Mac to share into the container")
            }

            TextField(
                "Volumes",
                text: $text,
                prompt: Text("~/websites:/usr/share/nginx/html — share a Mac folder inside the container")
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Volume mounts — folders shared from your Mac into the container")

            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let folder = urls.first else { return }
            appendMount(hostPath: folder.path)
        }
    }

    /// Appends `<picked folder>:/<folder name>`, matching how people actually
    /// use mounts (serve or work on that folder) — they can edit the
    /// container side afterwards if they want it somewhere else.
    private func appendMount(hostPath: String) {
        let entry = "\(hostPath):/\(URL(fileURLWithPath: hostPath).lastPathComponent)"
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        text = trimmed.isEmpty ? entry : "\(trimmed), \(entry)"
    }
}
