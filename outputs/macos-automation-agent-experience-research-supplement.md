# Supplemental research — macOS automation agent experience

## Scope
Targeted gap-fill after round 1. Covers two missing areas:
1. verified official OpenAI ChatGPT macOS product features relevant to agent-on-Mac product patterns
2. Apple guidance on sandboxing/automation tradeoffs for scriptable and automation-heavy macOS apps

## Numbered sources
1. OpenAI Help — Work with Apps on macOS: https://help.openai.com/en/articles/10119604-work-with-apps-on-macos
2. OpenAI Help — ChatGPT macOS app release notes: https://help.openai.com/en/articles/9703738-chatgpt-macos-app-release-notes
3. Apple Technical Q&A QA1888 — Sandboxing and Automation in OS X: https://developer.apple.com/library/archive/qa/qa1888/_index.html

## Findings

### A. Official OpenAI evidence now available
1. ChatGPT for macOS officially supports **Work with Apps**, including coding tools, terminals, and notes apps, with app-specific permissions or extensions as needed. It can include content from supported foreground apps in prompts, and for IDEs it can generate diffs and optionally auto-apply edits. This is direct evidence of a shipping Mac agent product using app-aware context capture plus reviewable edits instead of invisible full autonomy. [S1]
2. OpenAI says most compatible apps use the **macOS Accessibility API** for querying content, while VS Code uses a dedicated extension path. Supported apps include Apple Notes, Notion, TextEdit, Xcode, Script Editor, VS Code-family editors, JetBrains IDEs, Terminal, iTerm, Warp, and Prompt. This reinforces hybrid architecture: native/extension integration where available, Accessibility elsewhere. [S1]
3. The product exposes a **menubar icon**, **Option+Space** chat bar, **companion window**, **launch at login**, and background completion notifications. These are strong evidence that shipping desktop AI products already converge on Mac-native surfaces: menu bar, global hotkey, sidecar window, notifications, and persistent presence. [S1][S2]
4. OpenAI also added **Handoff** support and app-working during Advanced Voice mode, showing a broader desktop orchestration pattern rather than a plain chat client. [S2]

### B. Apple sandbox/automation guidance
5. Apple QA1888 states sandboxing is required for Mac App Store distribution and explicitly says sandboxed apps cannot send Apple events to other apps unless they request a **scripting-targets entitlement** or an **apple-events temporary exception entitlement**. This directly supports the conclusion that deep inter-app automation has real entitlement and review cost. [S3]
6. QA1888 also recommends avoiding temporary entitlements when possible and using APIs like `NSFileManager` instead of automating Finder for file operations. This is important product guidance: prefer direct native APIs over inter-app automation whenever possible. [S3]
7. QA1888 notes Automator actions run in the context of the host app and, when run by Automator or the OS, run outside a sandbox. This helps explain why legacy automation surfaces can behave differently from modern sandboxed app architectures. [S3]

## Impact on overall research
- Round-1 product survey should now treat ChatGPT macOS as a verified product example, not a blocked source.
- Round-1 platform analysis gains stronger Apple backing for claims about Mac App Store/sandbox tension with broad automation.
- Stronger synthesis rule: prefer native APIs and explicit app integrations first; use Apple Events and Accessibility only when value justifies permission/review cost.
