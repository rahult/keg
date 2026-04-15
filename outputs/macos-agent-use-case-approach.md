# macOS Agent Use-Case Approach

## Goal
Start from concrete Mac workflows, not generic chat. Build trust and habit through explicit entry points, reviewable actions, and local context.

## Starter use cases
1. **Downloads Desk Zero** — Finder-first file triage and cleanup.
2. **Local Coding Copilot** — active IDE + terminal context for debugging and patch drafting.
3. **Meeting Prep Router** — turn current page/notes into calendar-ready prep and reminders.
4. **Research Capture Desk** — collect browser + local file context into reusable briefs.
5. **Approval Inbox** — queue risky actions behind menu bar + notification review.

## Product principles
- Lead with Finder, menu bar, Shortcuts, notifications, and active-app context.
- Keep risky work human-in-loop.
- Prefer native/contextual flows first; layer deeper automation later.
- Seed strong templates now so later automation attaches to concrete jobs.

## First implementation tranche
- Add a dedicated **Use Cases** section in Agents.
- Surface 5 Mac-native starter use cases as cards.
- Let each use case prefill agent creation with a strong description/system prompt and metadata.
- Keep blank creation intact.

## Next tranche after this UI lands
- Add per-use-case capability checklists (Finder, active app, notifications, etc.).
- Add menu bar review queue and notification approval prototypes.
- Add app-aware context capture status and per-surface permission UX.
