# macOS automation opportunities for an agent product

## 1) Scope note
This note focuses on **product opportunities** for a distinctive **agent-on-macOS** experience, not an exhaustive API survey. It is grounded in a mix of Apple platform docs, shipping Mac automation products, and practitioner/product documentation. Where the recommendation goes beyond what a source states directly, it is labeled **Inference**.

## 2) Numbered source list with URLs
1. Apple Developer Documentation — App Intents: https://developer.apple.com/documentation/appintents
2. Apple Developer Documentation — AppShortcutsProvider: https://developer.apple.com/documentation/appintents/appshortcutsprovider
3. Apple Developer Documentation — NSWorkspace: https://developer.apple.com/documentation/appkit/nsworkspace
4. Apple Human Interface Guidelines — The menu bar: https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
5. Apple Human Interface Guidelines — Notifications: https://developer.apple.com/design/human-interface-guidelines/notifications
6. Apple Support — Intro to Shortcuts on Mac: https://support.apple.com/guide/shortcuts-mac/intro-to-shortcuts-apdf22b0444c/mac
7. Apple Support — Perform quick actions in the Finder on Mac: https://support.apple.com/guide/mac-help/use-quick-actions-on-mac-mchl97ff9142/mac
8. Apple Support — Allow accessibility apps to access your Mac: https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac
9. Raycast — AI that works with your OS: https://www.raycast.com/ai
10. Raycast Manual — AI: https://manual.raycast.com/ai
11. Shortcat Docs — Introduction: https://shortcat.app/docs
12. Shortcat Docs — Common Issues: https://shortcat.app/docs/common-issues
13. Shortcat Changelog: https://shortcat.app/changelog
14. Keyboard Maestro — product overview: https://www.keyboardmaestro.com/main/
15. Alfred — Workflows: https://www.alfredapp.com/workflows/

## 3) Opportunity matrix
| Concept | Why Mac-specific | Enabling primitives | User value | Trust / permission cost | Reliability risk | Source refs |
|---|---|---|---|---|---|---|
| **Menu-bar agent with app-aware quick actions** | The menu bar is a persistent, OS-native coordination surface; NSWorkspace exposes app/file context; App Intents and App Shortcuts expose actions across system surfaces. | Menu bar UI, NSWorkspace, App Intents, App Shortcuts, notifications | Very fast invocation, low-friction “what can I do here?” entry point, natural foreground-app awareness. Strong fit for a personal desktop agent. | Low to medium if limited to app/file context; higher if it starts inspecting cross-app content. | Low to medium if implemented with native APIs; mostly product risk is deciding how much context to surface automatically. | [S1][S2][S3][S4][S5] |
| **System-wide action verbs via Shortcuts / Spotlight / Siri** | macOS can surface app actions through Shortcuts and system experiences, which makes the agent feel built into the OS rather than trapped in its own window. | App Intents, App Shortcuts, Shortcuts app | High discoverability; reusable agent skills become callable from other workflows and apps. Lets users chain agent capabilities into their existing Mac habits. | Low. Permission burden is relatively low compared with accessibility-driven control. | Low when the action can stay inside the app or supported system integrations. | [S1][S2][S6] |
| **Finder-first file triage and transformation agent** | Finder Quick Actions are a very Mac-native pattern for acting on selected files in-place. This makes the agent useful without requiring a chat-first workflow. | Finder Quick Actions, Shortcuts, app extensions, notifications | High value for “summarize this folder,” “rename these files,” “extract action items from PDFs,” “prepare upload package,” etc. | Low to medium depending on file access scope. Usually easier to explain than broad computer control. | Low to medium; file workflows are generally more stable than UI automation. | [S6][S7][S5] |
| **Trigger graph for local personal automations with agent steps** | Mac users already adopt trigger-based automation tools like Keyboard Maestro and Alfred. An agent can add reasoning/planning on top of that established pattern. | Shortcuts, scheduled/background triggers, app/file events, local models or local execution, notifications | High for power users: converts repetitive personal workflows into automations with agent decision-making. Strong retention potential. | Medium because background automation raises trust questions even without full UI control. | Medium; triggers can be robust, but downstream actions vary in reliability. | [S6][S14][S15] |
| **Foreground-app copilot that hands off, not hijacks** | Mac apps and documents are local, stateful, and usually the real work surface. A copilot that detects the active app and offers context-specific help is more desktop-native than a generic chat pane. | NSWorkspace, menu bar, App Intents, notifications, optional selected-text/file capture | High: “help me with what I’m already doing” beats asking users to re-explain context. | Medium, because users may worry about passive monitoring. Needs obvious boundaries and user-controlled context sharing. | Medium; app detection is reliable, but deep semantic context depends on explicit capture methods. | [S3][S4][S5][S9][S10] |
| **Human-in-loop review inbox for risky actions** | Notifications and menu-bar presence make it natural to queue proposed actions, ask for approval, and show status without stealing focus. | Notifications, menu bar, local history/audit UI | High trust payoff: user can review, approve, edit, or reject actions. Good fit for an “agent but not autopilot” positioning. | Low to medium. Approval flow reduces trust cost versus silent automation. | Low if approval is required before side effects. | [S4][S5] |
| **Accessibility-powered universal app control as an expert mode / fallback** | macOS Accessibility enables cross-app UI interaction where no native integration exists; tools like Shortcat already use it to index UI elements, click buttons, switch windows, and search menus. | Accessibility API, UI scripting, optional keyboard automation | Potentially very high because it expands coverage to arbitrary apps. This is the nearest path to “computer use” on Mac. | High. Accessibility permission is sensitive, user-visible, and broad. | High. Shortcat documents broken labels, performance dependence on target apps, and permission resets after signing changes; this is evidence of brittleness and maintenance cost. | [S8][S11][S12][S13] |
| **Cross-app natural-language action routing through installed tools/extensions** | Raycast shows demand for AI that can invoke installed extensions and MCP-backed capabilities from one command surface. On macOS, that can feel like a universal command bus for the user’s machine. | Command palette, extension system, MCP/tool adapters, App Intents, menu bar | High differentiation if the agent can route to native tools, local scripts, and app actions from one place. | Medium. Tool invocation is easier to trust than broad screen control, but still needs permission and provenance UX. | Medium; depends on quality of adapters and contracts. | [S9][S10][S14][S15] |

## 4) Prioritized recommendations with rationale

### Priority 1 — Build a **menu-bar, app-aware, human-in-loop agent**
This is the strongest near-term product bet. Apple’s menu-bar guidance and notification guidance support a lightweight, always-available coordination surface [S4][S5]. NSWorkspace gives a native basis for foreground app and file-awareness [S3]. App Intents / App Shortcuts make actions discoverable from system surfaces like Spotlight and Shortcuts instead of only inside the app [S1][S2].

**Why this should come first:** it creates a distinctly Mac feel without immediately paying the reliability and trust cost of accessibility-driven control. **Inference:** a menu-bar agent that knows the active app, surfaces a few context-relevant actions, and asks for explicit approval before side effects would likely feel much more “desktop native” than a chat window with tools bolted on.

### Priority 2 — Make the agent **callable from Finder and Shortcuts**, not just chat
Apple’s Shortcuts and Finder Quick Actions already train users to run transformations on selected content and files [S6][S7]. That means the agent should expose things like “summarize selected files,” “prepare shipment,” “clean up download folder,” or “draft reply from selected documents” directly in those surfaces.

**Why this matters:** it turns the agent from “a place you go ask questions” into “an action layer inside existing Mac workflows.” This also lowers trust cost because the scope is explicit: the user selected the files or invoked the shortcut [S6][S7].

### Priority 3 — Treat **automation graphs with agent steps** as a product layer for power users
Keyboard Maestro and Alfred show that advanced Mac users already value trigger-based automation, scheduled actions, hotkeys, and composable workflows [S14][S15]. Raycast AI adds evidence that users also want AI in the same command surface as other OS actions [S9][S10].

**Recommendation:** offer a simple trigger/action system where the “agent” is one node among deterministic steps, not a black box that owns the whole workflow. **Inference:** this creates a differentiated product because most AI desktop tools begin with chat, while Mac power users often think in triggers, selections, and commands.

### Priority 4 — Use **Accessibility/UI control only as a bounded fallback**, not the default value proposition
Accessibility-powered control is the clearest route to universal cross-app action, and Shortcat is proof that users want this capability [S11]. But the same docs and changelog show the tradeoff: Accessibility permission is sensitive [S8], app labeling quality varies, performance depends on target apps, and even signing changes can require users to reset permissions [S12][S13].

**Recommendation:** keep this behind explicit opt-in, expert labeling, and per-action approval. It should rescue unsupported workflows, not define the core experience.

### Priority 5 — Differentiate on **local context + explicit handoff**, not secret observation
Raycast’s current positioning is “AI that works with your OS” and natural-language routing into extensions/MCP-like capabilities [S9][S10]. Competing head-on with a generic command palette is hard. The stronger opportunity is to combine:
- active-app awareness [S3]
- explicit user selection or Finder context [S6][S7]
- a persistent menu-bar review surface [S4][S5]
- optional local execution for sensitive tasks (**Inference**, supported directionally by Mac-local workflow expectations and existing automation tools [S14][S15])

That combination yields a clearer product story: **an agent that helps with what is already on your Mac, in the app you are already using, with review before action**.

## Suggested evaluation rubric
Score each candidate feature 1-5 on each dimension:

| Dimension | What to ask |
|---|---|
| User value | Does this remove a frequent desktop pain point, or is it merely impressive? |
| Differentiation | Would this feel meaningfully more Mac-native than the same feature in a browser tab? |
| Trust cost | How uncomfortable will users feel granting the required visibility/control? |
| Permission burden | Does it require Accessibility, Full Disk Access, always-on background presence, or broad file scope? |
| Reliability | Is it built on native contracts (better) or UI interpretation / brittle automation (worse)? |
| Maintenance cost | Will OS updates, app redesigns, or signing changes frequently break it? |
| Composability | Can this capability be reused in Shortcuts, Finder, hotkeys, or workflows? |

**Practical weighting recommendation:** prioritize features with high user value, high differentiation, and low-to-medium trust/permission burden. Penalize anything that depends on Accessibility unless it unlocks outsized value.

## 5) Open questions / assumptions
1. I have enough evidence to recommend **where** the product opportunities are, but not yet enough to rank every primitive by implementation effort; that belongs in the implementation-focused track.
2. I did not verify modern Apple guidance for every possible background trigger type in this note; recommendations here focus on product shape, not exhaustive trigger support.
3. **Inference:** local execution is likely a differentiator for sensitive desktop workflows, but this note does not independently verify the exact current Apple or hardware constraints around on-device model deployment.
4. I did not include a broad competitive survey of every desktop AI app; this note relies mainly on Raycast plus established Mac automation products as proof of user demand patterns.
5. Accessibility-driven automation is clearly powerful, but current evidence here is stronger on its **risk and brittleness** than on long-term production-safe mitigations.
