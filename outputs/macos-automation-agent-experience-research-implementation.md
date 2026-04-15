# macOS Automation for Agent Experience — Implementation Research (T3)

## 1) Scope note
This round focuses on **technical implementation patterns** for a modern **agent-on-macOS** product: how a macOS app can expose actions into system automation, observe and control other apps, stay resident in the menu bar or background, and compose multiple automation transports into a reliable stack. It intentionally avoids broad product-market recommendations and instead concentrates on code examples, platform docs, and engineering evidence about **what is implementable now** and **how fragile each path is**.

## 2) Numbered source list with URLs
1. Apple Developer Documentation — **App Intents**: https://developer.apple.com/documentation/appintents
2. Apple Developer Documentation — **MenuBarExtra**: https://developer.apple.com/documentation/swiftui/menubarextra
3. Apple Developer Documentation — **User Notifications**: https://developer.apple.com/documentation/usernotifications
4. Apple Developer Documentation — **XPC**: https://developer.apple.com/documentation/xpc
5. x-callback-url specification: https://x-callback-url.com/specification/
6. AXSwift README: https://github.com/tmandry/AXSwift
7. AXSwift observer example (`Observer`, event subscriptions): https://raw.githubusercontent.com/tmandry/AXSwift/main/AXSwiftObserverExample/AppDelegate.swift
8. DFAXUIElement README: https://github.com/DevilFinger/DFAXUIElement
9. SwiftAutomation README: https://github.com/hhas/SwiftAutomation
10. Desktop Pilot MCP README: https://github.com/VersoXBT/desktop-pilot-mcp
11. MenuBarExtraAccess README: https://github.com/orchetect/MenuBarExtraAccess
12. LaunchAtLogin-Modern README: https://github.com/sindresorhus/LaunchAtLogin-Modern
13. Hammerspoon README: https://github.com/Hammerspoon/hammerspoon
14. Transaction History README (Shortcuts/App Intents usage): https://github.com/igorcferreira/TransactionHistory
15. `CreateTransactionIntent.swift` example (`AppIntent`, `supportedModes = .background`): https://raw.githubusercontent.com/igorcferreira/TransactionHistory/main/Sources/TransactionHistory/Intent/CreateTransactionIntent.swift

## 3) Evidence table
| Technique | Implementation path | Example repo/product | Strengths | Fragility / maintenance cost | Source refs |
|---|---|---|---|---|---|
| Expose agent actions to Shortcuts / Spotlight / Siri-like system surfaces | Define `AppIntent` types in Swift; model actions as parameterized intents; expose background-capable tasks where possible | Apple App Intents docs; `TransactionHistory` and `CreateTransactionIntent.swift` | Most native way to make an agent discoverable and composable in macOS automation surfaces; structured parameters; system-owned invocation UX; good for “ask agent to summarize folder / triage inbox / file issue” actions | Limited to actions your app explicitly models; less useful for arbitrary app control; requires thoughtful intent schema design; some behavior needs macOS-specific testing | [1] [14] [15] |
| Menu bar resident agent UI | SwiftUI `MenuBarExtra` for persistent menu bar presence; use `MenuBarExtraAccess` when SwiftUI defaults are too constrained | Apple `MenuBarExtra`; `MenuBarExtraAccess` | Natural Mac-native control point for an always-available agent; low-friction entry, status display, quick commands, permission prompts, and recent actions | Stock `MenuBarExtra` is limited; `MenuBarExtraAccess` exists because first-party API still lacks presentation/state control; `.menu` style can block runloop while open | [2] [11] |
| Launch at login / background availability | Use login-item registration (`LaunchAtLogin`) so the agent is present after user sign-in | `LaunchAtLogin-Modern` | Critical for agents that should react to file changes, notifications, or global shortcuts without explicit relaunch; low implementation overhead | Must be user-enabled; App Store review requires it to be enabled in response to user action; startup persistence does not itself solve task orchestration or permissions | [12] |
| Notification-based human-in-the-loop actions | Use `UserNotifications` to deliver local notifications and action buttons for approval, retry, or follow-up | Apple User Notifications docs | Good for “agent found a draft, approve/send?” workflows; keeps user in control; works even if main UI is not frontmost | Notification delivery/action UX is constrained by system policy; unsuitable for high-frequency control loops; needs per-action design to avoid spam | [3] |
| Split-privilege / helper-process architecture | Keep UI app small; move long-running or risky automation work into helper/XPC services | Apple XPC docs | Clean way to isolate automation engine from UI, reduce crash blast radius, and keep a stable local RPC boundary between agent core and app surface | XPC adds complexity, state synchronization, lifecycle issues, and entitlement/signing work; still requires careful permission choreography for automation features | [4] |
| Accessibility-tree reading and semantic UI automation | Use `AXUIElement` wrappers like AXSwift / DFAXUIElement to enumerate windows, controls, roles, titles, and attributes; act on semantic elements instead of pixels | AXSwift, DFAXUIElement | Strongest path for general-purpose app control when no app-specific API exists; can inspect UI tree, observe changes, move/resize windows, invoke actions semantically | Requires Accessibility permission; source evidence says non-sandboxing/App Store publication becomes harder; UI structures vary by app and version; apps with poor AX metadata are harder to automate | [6] [7] [8] |
| Event-driven accessibility observation | Register observers for window creation, window moves, main-window changes, and element lifecycle events instead of polling screenshots | AXSwift observer example | Better than screenshot polling for responsiveness and power use; enables stateful agent workflows (“wait until compose window appears, then fill fields”) | Event subscriptions are still only as good as the target app’s AX implementation; debugging event timing can be tricky across apps | [7] |
| Apple Events / AppleScript bridge for scriptable apps | Use an Apple-event bridge such as SwiftAutomation for apps that already expose scripting dictionaries | SwiftAutomation | Much more robust than UI scripting when target app is scriptable; can operate on app objects/commands directly; human-readable high-level commands | Coverage depends on whether target app is “AppleScriptable”; terminology can be faulty (`ascrgdte` / SDEF issues per README); modern future of Apple event automation remains less clear than App Intents | [9] |
| URL scheme / x-callback integrations | Trigger cooperating apps through custom URL schemes and `x-success` / `x-error` callbacks | x-callback-url spec | Lightweight, cross-app, user-visible handoff mechanism; good for jumping from agent to editor/task manager/browser and back with structured result callbacks | Only works when the target app implements a scheme; payload size and security are limited; capability discovery is inconsistent; often unsuitable for high-trust destructive actions | [5] |
| Local scripting host / shell-centric automation hub | Embed or interoperate with local scripting systems (for example Hammerspoon’s Lua bridge to OS functionality) as an extension layer around the app | Hammerspoon | Excellent for power-user extensibility and local-first automation; can let advanced users script agent triggers and custom workflows around your product | Scripting hosts increase support surface and user-config drift; cross-layer debugging becomes harder; not a substitute for a principled product API | [13] |
| Hybrid AX + AppleScript + CGEvent control plane | Use the cheapest most-semantic transport first; fall back from native/app-specific API → AppleScript/Apple Events → Accessibility tree → synthetic input only when needed | Desktop Pilot MCP | Practical architecture for an agent that must control arbitrary Mac apps; repo argues semantic UI tree access is dramatically faster than screenshot-based computer-use and shows direct refs instead of coordinates | Benchmarks come from one project and should be independently replicated; CGEvent/input synthesis is usually the most brittle tier; permission burden compounds when stacking mechanisms | [10] [6] [9] |

## 4) Architecture notes for a modern macOS agent app

### A. Recommended capability stack: semantic-first, not screenshot-first
The strongest implementation pattern from the sources is a **semantic control stack**:
1. **Native app-owned actions** via `AppIntent` for anything your agent itself can do inside its own domain. Apple positions App Intents as the way to make app content/actions discoverable in system experiences like Spotlight, widgets, and Shortcuts [1].
2. **Target-app native integration** when available: URL schemes / x-callback-url [5], or Apple Events / script dictionaries for scriptable apps [9].
3. **Accessibility tree automation** for non-scriptable apps, using `AXUIElement` wrappers and observers [6] [7] [8].
4. **Synthetic input / CGEvent** only as a last resort, when neither direct app APIs nor useful AX metadata exist [10].

This tiering matters because the reliability gradient is clear in the evidence:
- **App Intents / app-owned APIs** are most robust because you control both schema and implementation [1] [15].
- **Apple Events** are robust when the target app is scriptable, but availability is app-dependent and terminology quality varies [9].
- **Accessibility** is broadest in app coverage, but metadata quality and OS/app updates can destabilize selectors [6] [7] [8].
- **Input synthesis / coordinate-based methods** are broad but most brittle; Desktop Pilot’s entire pitch is that semantic tree access is materially faster and more stable than screenshot-and-pixel loops [10].

### B. Product shape for an “agent on macOS”
A credible Mac agent product should probably be split into these layers:
- **Menu bar shell**: persistent entry point, quick status, recent actions, permission onboarding, and interruption surface via `MenuBarExtra` [2].
- **Main app**: settings, logs, action history, model/provider selection, permission repair, trust center.
- **Automation engine**: local actor/service that normalizes capabilities across App Intents, URL schemes, Apple Events, Accessibility, and shell tasks.
- **Optional helper/XPC boundary**: separate long-running automation work or unstable integrations from UI process using XPC [4].
- **Notification router**: local notifications with actionable approvals for destructive or high-confidence-but-user-visible tasks [3].
- **Login item**: optional start-at-login for always-ready presence [12].

### C. Capability registry per target app
A modern agent should maintain a **per-app capability registry**, not assume one universal transport. Example shape:
- Finder: Apple Events + AX fallback.
- Browser: URL scheme or extension bridge + AX fallback.
- Slack/Discord/Telegram: AX tree for compose/search UI, possibly URL scheme if exposed.
- Your own app: App Intents + internal RPC.

This follows directly from the diversity of mechanisms in the sources [5] [6] [9] [10]. The registry should rank transports by **semantic richness**, **permission burden**, and **historical reliability**.

### D. Treat Accessibility automation as a structured graph problem
The most useful code-centric evidence is AXSwift’s observer example: it subscribes to `windowCreated`, `mainWindowChanged`, and window destruction/move notifications, then reacts to those semantic events [7]. That suggests an agent architecture built around:
- semantic element references,
- cached UI tree snapshots,
- event subscriptions where available,
- idempotent retry logic when elements disappear.

This is materially different from screenshot automation. Desktop Pilot’s README argues the same point with benchmarks and element references (`e1`, `e2`, …) instead of coordinates [10]. For agent UX, that means:
- faster turnaround,
- less model inference overhead,
- clearer audit logs (“clicked Button ‘Send’ in Mail compose window”),
- better recoverability when UI changes.

### E. Use App Intents for inbound automation, not arbitrary outbound control
The TransactionHistory example is useful because it shows a concrete `AppIntent` with `supportedModes = .background`, typed parameters, and a perform method [15]. That is a good pattern for **user-initiated or workflow-initiated commands into your app**. It is **not** a replacement for controlling arbitrary third-party apps. In product terms:
- App Intents make your agent **callable by the OS**.
- Accessibility / Apple Events / URL schemes make your agent **able to call out into the OS and other apps**.

A differentiated agent on macOS likely needs both directions.

### F. Menu bar UX should assume first-party limitations
`MenuBarExtraAccess` is notable because it exists to work around missing first-party control over `MenuBarExtra` presentation and status item access [11]. It also documents a concrete known issue: `.menu` style popups block the runloop while open, limiting state observation and programmatic dismissal [11]. For an agent product, that implies:
- use the menu bar for status and launching flows, not for long-running interaction loops,
- prefer window-style presentations or separate windows for richer agent chats,
- keep automation execution outside the menu popup path.

### G. Background and startup should be explicit and user-controlled
`LaunchAtLogin-Modern` shows the low-friction path for login startup, but also notes App Store review expects launch-at-login to be enabled only in response to user action [12]. So the implementation pattern should be:
- expose launch-at-login as a visible setting,
- explain why background presence helps the user,
- pair it with clear status (“running”, “paused”, “waiting for permission”).

### H. Human approval loops fit notifications better than modal prompts
Apple’s User Notifications framework is the right primitive for asynchronous approvals/retries [3]. For a macOS agent, likely uses include:
- “I drafted a response — approve/send?”
- “Could not access Mail because permission was denied — open settings?”
- “Calendar event changed — rerun travel prep workflow?”

This keeps the agent ambient instead of demanding foreground focus.

### I. Local-first extensibility is real, but should be bounded
Hammerspoon shows there is persistent demand for local automation layers that bridge OS capabilities into a scripting environment [13]. That is useful evidence for an agent product, but the implementation lesson is not “ship a giant scripting runtime first.” It is:
- design a stable internal action graph,
- optionally expose advanced hooks later,
- preserve auditability across user-authored automations.

### J. A practical transport ranking for production
Based on the sources, the clean ranking for an agent runtime is:
1. **Internal app API / App Intents** — best reliability for your own domain [1] [15]
2. **App-specific native interface** (URL scheme, documented integration) [5]
3. **Apple Events / AppleScript bridge** for scriptable apps [9]
4. **Accessibility tree** for general app automation [6] [7] [8]
5. **CGEvent / synthetic input** for last-resort interaction [10]
6. **Screenshot-based computer use** only when nothing semantic exists [10]

## 5) Unresolved gaps / claims needing verification
1. **Accessibility + sandbox / App Store restrictions need stronger primary sourcing.** DFAXUIElement explicitly says Accessibility-based control typically requires non-sandbox mode and is difficult for App Store distribution [8], but this should be cross-checked against Apple primary documentation before making policy claims.
2. **Desktop Pilot benchmark claims are informative but single-source.** The README claims 30–100x speedups versus screenshot-based computer-use and provides example numbers [10]. Useful directional evidence, but not enough for a definitive performance claim without independent reproduction.
3. **Need a primary Apple source on Apple Events permissions/entitlements for modern notarized apps.** SwiftAutomation gives strong implementation evidence [9], but modern permission and entitlement specifics should be verified from Apple docs.
4. **Need more macOS-specific App Intents examples.** `TransactionHistory` proves the implementation pattern [14] [15], but it is primarily iOS-focused; a stronger Mac-native example would tighten claims about background/headless behavior on macOS.
5. **Need empirical verification of notification action ergonomics on current macOS.** Apple docs confirm the framework [3], but practical limits for high-frequency agent approval loops should be validated in a prototype.
6. **Need direct testing across target apps with poor AX metadata.** AX-based approaches are promising, but robustness varies by app quality; source evidence shows capability, not guaranteed consistency across all major Mac apps [6] [7] [8] [10].

## Working conclusions from this round
- The most defensible implementation path for a distinctive Mac agent is **not** a browser-style chat app with occasional shell commands. It is a **resident local app** that combines **menu bar presence**, **system-callable intents**, **semantic app automation**, and **human approval via notifications** [1] [2] [3] [6] [7] [10] [11] [12].
- The best engineering pattern is a **hybrid automation router** that chooses the highest-semantic, lowest-fragility transport available for each app/action: internal API/App Intents first, then app-specific interfaces, then Apple Events, then Accessibility, then synthetic input [5] [9] [10].
- Accessibility is likely the key enabler for “agent on macOS” differentiation because it exposes the live UI graph and event stream of arbitrary apps, but it also carries the highest productization risk around permissions, app compatibility, and possible distribution constraints [6] [7] [8].
