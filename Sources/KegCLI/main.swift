import Foundation
import KegCLICore

// keg — the companion CLI for the Keg app. Talks to Keg's Docker API
// socket (no Docker CLI required), manages its own PATH installation, and
// deep-links into the app's UI.

var stdout = FileHandle.standardOutput

let arguments = Array(CommandLine.arguments.dropFirst())
let exitCode = KegCLI.run(arguments) { text in
    stdout.write(Data((text + "\n").utf8))
}
exit(exitCode)
