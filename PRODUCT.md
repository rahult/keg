# Product

<!-- impeccable:product-schema 1 -->

## Platform

native (macOS 26+, Apple Silicon only) — schema's closest bucket is `ios`; this is an AppKit/SwiftUI desktop app, not mobile.

## Users

Two audiences on the same screens (DESIGN.md §0): people who have never touched containers, and experienced operators who want every knob. Primary situation: a developer on a Mac wanting Docker-Desktop-class container workflows without Docker Desktop; secondary: non-developers self-hosting open-source apps (Memos, Vaultwarden, Jellyfin…) via the Apps store.

## Product Purpose

Keg wraps Apple's `container` framework (apple/container) in a native macOS app to provide container management: container/image/volume/network CRUD, Dockerfile builds, Docker Engine API compatibility on a Unix socket, Compose orchestration, one-click self-hosted apps, loopback hostnames (Gateway), single-node Kubernetes, and a built-in on-device agent (Cooper). Success = a newcomer runs a container or installs an app without knowing what a container is; an operator never needs the Docker CLI.

## Positioning

One VM per container via Apple's Virtualization.framework (not a shared Linux VM), driven by the OS vendor's own container runtime — the mechanism a Docker-compatible product could not truthfully copy. Plus native affordances no Electron competitor matches: menu bar popover, Apple-Intelligence on-device agent, deep links, Sparkle updates.

## Operating Context

- The `container` CLI and `container-apiserver` (launchd XPC service) are the substrate; most operations shell out to the CLI with a pinned `--app-root` (data lives on a user-configured volume, e.g. `/Volumes/Atlas/Containers`).
- A Hummingbird HTTP server speaks the Docker Engine API on `~/.keg/docker.sock`; the real `docker` CLI works against it.
- `keg.yaml` in any repo + the `keg` companion CLI turn repos into container infra; an installed agent skill (`keg skill install`) teaches agents the workflow.
- Settings is where runtime health, data location, Docker API, Kubernetes, agent backend, Gateway DNS/TLS, CLI installers, and updates are managed — mostly state + action cards, few free-text preferences.
- Distribution: Homebrew cask + Sparkle appcast; website at the repo's `site/`.

## Capabilities and Constraints

- macOS 26+ Tahoe, Apple Silicon only; Swift 6.2 strict concurrency; SwiftUI `@Observable @MainActor` view models.
- Apple Container is pre-1.0; API may change between minor versions.
- No inter-container DNS; published ports are loopback-only (verified live) — affects what Settings may promise.
- Keg never runs sudo: privileged operations surface the exact command for the user to run (Gateway resolver, TLS trust).
- Compose/Apps naming contracts (`apps-<id>`, `kegapp-<id>-<service>`) are load-bearing; Settings changes must not break them.
- Cooper: on-device FoundationModels (~3B, tiny context) with an OpenAI-compatible remote fallback; permission-gated actions; destructive ops always require approval.
- Terminology: "Apple Containers" (the runtime), "Keg" (the app), "Compose" (multi-service stacks), "Apps" (curated one-click installs), "Gateway" (`*.keg` hostnames), "Cooper" (the agent).

## Brand Commitments

- Name: Keg. System accent color only — never hardcode colors (semantic colors only, DESIGN.md §14).
- Voice: sentence case, verb-first, plain language first with jargon defined (DESIGN.md §0.3, §16).
- macOS HIG conventions are binding: `.toolbar` not hand-rolled bars, `.searchable`, grouped `Form`, `ContentUnavailableView`, help ⓘ on every screen.
- SF Symbols for icons; SwiftUI-native components over custom chrome.

## Evidence on Hand

- `DESIGN.md` — the incumbent UX guide (18 sections incl. §18 Settings Screen rules).
- `docs/FEATURES.md`, `docs/ARCHITECTURE.md`, `README.md`, `CHANGELOG.md` — product truth.
- `site/` — marketing site with screenshots (may lag current UI).
- No user research, metrics, or testimonials exist; do not fabricate any.

## Product Principles

1. Never make the user guess — icon + text labels, help everywhere (§0.1).
2. One primary action per screen (§0.2).
3. Plain language first; domain terms only after the plain meaning is established (§0.3).
4. State lives next to the object it describes (§0.4).
5. Progressive disclosure — friendly summaries default, raw detail one disclosure away (§0.5).
6. Consistency is the contract (§0.6).

## Accessibility & Inclusion

No product-specific requirement established beyond macOS platform standards (Dynamic Type, VoiceOver via SwiftUI).
