# Keg WASM Runtime — Implementation Plan

**Status:** Proposed
**Date:** 2026-09-15
**Parent decision:** [WASM-STRATEGY.md](WASM-STRATEGY.md) (D2 — native WASM engine as a fast lane)
**Design goal:** *seamless* — a user should never think about WASM as a separate system. Pull a `wasi/wasm` image, `compose up`, hit the URL. No flags to remember, no runtimes to install, no separate UI.

---

## 1. Seamlessness principles (the UX contract)

| # | Principle | What it means in practice |
|---|---|---|
| S1 | **Zero install** | Wasmtime is downloaded automatically on first wasm workload — pinned version, checksum-verified, into `~/.keg/bin/`. Settings shows version + "Update" only. |
| S2 | **Zero flags** | Never require `--runtime` or `--platform` in Keg's own UI/flows. Detection is automatic at pull/create time: image platform `wasi/wasm*` or wasm media types → WASM engine. The `runtime:`/`platform:` compose keys keep working for Docker-compat, but are advisory, not required. |
| S3 | **One surface** | WASM workloads appear in the existing Containers list, Images list, logs, port dashboard — with a small "WASM" badge. No separate section. Detail view shows engine instead of VM info where semantics differ. |
| S4 | **Ports just work** | `ports: ["8080:80"]` on a wasm service starts a local HTTP listener that dispatches to the module's `wasi:http` handler. User experience is identical to Linux containers; the proxy is invisible. |
| S5 | **Honest errors** | When a workload *can't* run on WASM (needs sockets/exec/GPU), the error says exactly that and offers "Run as Linux container" when the image is multi-platform. |

## 2. Architecture

```
                        ┌── EngineRouter ── "is this wasm?" ──┐
                        │                                   │
   DockerAPIServer ─────┤                                   ├──── ContainerBridge (existing,
   ComposeOrchestrator ─┤                                   │      Apple-VM engine, unchanged)
                        │                                   │
                        └── WasmBridge (new)                │
                                │                           │
        ┌───────────────────────┼───────────────────┐       │
        ▼                       ▼                   ▼       ▼
  WasmRuntimeManager      WasmProcess           WasmHTTPProxy
  (install/verify/        (wasmtime CLI        (host port →
   update wasmtime)        child process,       wasi:http
                           mirrors ContainerCLI  dispatch)
                           Process() pattern)
        │                       │
        ▼                       ▼
  WasmImageStore (OCI pull of wasi/wasm images + wasm artifacts,
                  reusing existing registry auth)
```

New files, all under `Sources/Keg/Wasm/`:

| File | Responsibility |
|---|---|
| `WasmRuntimeManager.swift` | Version-pinned wasmtime lifecycle: download → SHA-256 verify → `~/.keg/bin/wasmtime`; update check; used by both bridge and UI settings |
| `WasmProcess.swift` | `Process()` wrapper mirroring `ContainerCLI` (`run`/`makeProcess`): env, args, stdio pipes, termination. Engine = wasmtime CLI first |
| `WasmImageStore.swift` | Registry client for the two wasm packaging models: (a) `wasi/wasm32` OCI images (manifest platform detection → extract `.wasm` + entrypoint from config), (b) OCI artifacts (`application/wasm`, `application/vnd.wasm.content.layer.v1+wasm`). Content-addressed cache in `~/.keg/wasm/images/` |
| `WasmBridge.swift` | `actor` with the same operation shape as `ContainerBridge`: list/create/start/stop/remove/inspect/logs + stats (fuel/epoch, memory). Owns instance records; emits state for webhooks |
| `WasmHTTPProxy.swift` | Per-container host listener → dispatches HTTP to the running module's `wasi:http` incoming-handler via wasmtime serve-style invocation; maps `HostConfig.PortBindings` |
| `EngineRouter.swift` | Pure decision logic: given image ref / create request / compose service → `wasm` or `linux`. Testable in isolation |

## 3. Integration points in existing code

1. **`DockerAPIServer.swift`** — every handler currently calls `bridge.*`. Insert `EngineRouter` at the top of `containers/create`, `containers/{id}/start`, `images/create`: resolve the image platform (cheap: HEAD the manifest via `WasmImageStore` when unsure), then dispatch to `ContainerBridge` or `WasmBridge`. `containers/json`, `logs`, `stop`, `remove` merge results from both bridges. `/_ping`/`/info` advertise wasm runtime availability (mirrors Docker's `Runtimes` map).
2. **`ContainerBridge.swift`** — the `pendingContainers` create→start handoff pattern (create stores `DockerContainerCreateRequest`, start consumes it) is exactly what `WasmBridge` replicates; no bridge changes needed.
3. **`ComposeOrchestrator.swift`** — add `platform` and `runtime` to `ComposeService` (two decode lines + CodingKeys); the topological sort/`depends_on` logic is engine-agnostic already. Mixed stacks fall out naturally.
4. **`DockerTypes.swift`** — add `platform` to `DockerContainerCreateRequest` decoding (Docker sends it under a `Platform` field); `DockerContainer` gains a label-based wasm marker (`keg.engine=wasm`) so the UI badge survives list/inspect round-trips.
5. **`AppState.swift` / Settings** — one row: "WASM runtime: Wasmtime x.y.z ✓ (Update)". Auto-install triggers lazily from `ensureReady()` only when a wasm workload is requested (no first-launch network, no gate).
6. **UI (Containers list & detail)** — badge via the `keg.engine=wasm` label; detail view swaps VM-specific rows (VM memory, kernel) for wasm rows (module size, fuel consumed, host port proxy targets). Logs view unchanged (stdio capture).

## 4. Phases

**Phase 0 — Spike (2–3 days).** No UI, no API. `WasmProcess` + `WasmImageStore` + hardcoded pull of `secondstate/rust-example-hello:latest`; run with wasmtime CLI; capture stdout. Success = a Swift test that pulls, runs, and asserts "Hello WasmEdge!" in output. Validates registry auth assumptions and CLI latency.

**Phase 1 — Engine core (1 wk).** `WasmRuntimeManager` (install/verify/update), full `WasmBridge` (create/start/stop/remove/list/inspect/logs), image cache, instance records. Unit-tested actor; no server wiring yet.

**Phase 2 — Seamless routing (1 wk).** `EngineRouter` + `DockerAPIServer` integration per §3.1. `docker run` / `docker compose`-client compatibility for wasm images with no flags. Badge label plumbing.

**Phase 3 — Ports & parity (1 wk).** `WasmHTTPProxy` (wasi:http dispatch), stats (memory + fuel), events/webhook parity, `HostConfig` limits (memory cap; fuel-based CPU interrupt).

**Phase 4 — Compose & UI (1 wk).** `platform`/`runtime` compose keys, mixed-stack orchestration, UI badge + detail rows, Settings runtime row.

**Phase 5 — Hardening (ongoing).** Never execute precompiled artifacts from image layers (runwasi GHSA-cc25-vq59-rcjx lesson — compile from wasm bytes only, or verify cwasm provenance); per-container disk quotas on the preopen root; evaluate embedded Wasmtime C API vs CLI to cut per-invocation process overhead; WasmKit re-evaluation once its component model lands.

## 5. Testing

- **Unit:** `EngineRouter` decision table (platform string, media type, runtime hint, multi-platform index fallback); `WasmImageStore` manifest parsing against recorded registry responses.
- **Integration:** Phase 0 spike test as the anchor; Docker-API-level test hitting create/start/logs on the local socket for a wasm image; compose up of a mixed stack (wasm + `alpine` sidecar).
- **Manual QA:** `docker run` parity checklist — pull, run, logs, stop, rm, port browse — for 3 reference images (hello-world, wasi-http service, Spin app).

## 6. Risks & open questions

| Risk | Mitigation |
|---|---|
| wasmtime CLI-per-container overhead (~10–20 ms spawn) | Acceptable for v1; embedded engine is the Phase 5 answer. CLI also matches Keg's existing Process() architecture |
| Registry auth for artifact pulls (some registries treat artifacts differently) | Reuse existing `container` CLI auth state where possible; fall back to keychain-based token flow |
| `wasi:http` handler shape varies (component vs preview1 CGI-style) | v1 supports component-model `wasi:http` only; preview1 http services get S5's honest error + Linux fallback suggestion |
| Snapshot/pause semantics (VM engine has them; wasm doesn't) | v1: pause = suspend proxy only. Document; don't fake it |
| Docker Desktop removal timeline could shift expectations | Detection keys follow Docker's conventions (`io.containerd.wasmtime.v1`), so files keep working either way |
