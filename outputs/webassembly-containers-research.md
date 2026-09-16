# Keg for WebAssembly Containers — Research

**Date:** 2026-09-15
**Question:** How could Keg (a Docker Desktop–class macOS container manager wrapping Apple's `container` framework) be built for WebAssembly containers?

---

## TL;DR

- **WASM containers are real, OCI-compatible, and Docker just abandoned them.** Docker Desktop's Wasm workloads feature is officially deprecated ("deprecated and will be removed in a future Docker Desktop release… no longer actively maintained") — this is precisely the gap a Keg-class tool could own.
- **Apple's `container` framework cannot run WASM.** It runs *Linux* containers as lightweight VMs via Virtualization.framework; there is no pluggable runtime or wasm path. A Keg-for-WASM engine must bring its own WASM runtime — which is an *advantage*: WASM runs natively on macOS with no VM at all, giving millisecond starts and tiny footprints that Keg's one-VM-per-container model can't match.
- **Two OCI packaging conventions exist** for wasm: (1) `wasi/wasm32` *platform images* (a `FROM scratch` image whose entrypoint is a `.wasm` file, run via a containerd shim like `io.containerd.wasmtime.v1`), and (2) pure OCI *artifacts* with wasm media types (`application/wasm`, `application/vnd.wasm.content.layer.v1+wasm`) pushed via `oras`/`wkg`. Keg should support both.
- **Recommended architecture: a native macOS WASM runtime embedded in Keg, exposed through the existing Docker-API-compatible socket.** Runtimes to evaluate: **WasmKit** (pure Swift, embeddable, but interpreter-speed and WASI-preview1-focused) vs **Wasmtime via its C API** (fast, preview2/component-model, but Rust build + C shim in SwiftPM) vs **WasmEdge C SDK** (AOT, cloud-native focus).
- **Skip the containerd/runwasi path for the host.** runwasi shims require Linux namespaces and do not build or run on macOS. Keep containerd+runwasi only as the "full Linux compat" fallback inside a VM (same pattern as Keg's K8s support).

---

## 1. Background: what "WASM containers" means

There are two ways wasm workloads are packaged and run in the container ecosystem today:

### 1.1 `wasi/wasm32` OCI images + containerd shims

A wasm app is packaged as a minimal OCI image (typically `FROM scratch` with just the `.wasm` file) built for the `wasi/wasm32` platform. containerd dispatches these images to a pluggable **shim** instead of `runc`:

```
Kubernetes → containerd → runwasi shim (containerd-shim-wasmtime-v1) → Wasmtime
```

- Docker Desktop installed shims for `io.containerd.wasmedge.v1`, `io.containerd.wasmtime.v1`, `io.containerd.wasmer.v1`, `io.containerd.spin.v2`, `io.containerd.slight.v1`, `io.containerd.lunatic.v1`, `io.containerd.wws.v1`.
- Usage: `docker run --runtime=io.containerd.wasmedge.v1 --platform=wasi/wasm32 myimage`.
- This is the **runwasi** model (github.com/containerd/runwasi, a Rust library `containerd-shim-wasm` used by `containerd-shim-spin` (SpinKube) and `deislabs/containerd-wasm-shims`).
- Alternative OCI-runtime models: `crun` and `youki` embed WasmEdge and switch on image annotations (wasm32 vs linux) — this gets you the whole CRI-O/Podman/kind stack, but is Linux-only.

### 1.2 OCI artifacts with wasm media types

Pure wasm modules distributed as OCI artifacts (no rootfs at all):

- Layer media type: `application/wasm` (Microsoft's variant) or `application/vnd.wasm.content.layer.v1+wasm`
- Config media type: `application/vnd.wasm.config.v0+json` / `v1+json`
- Tools: `oras push`, the legacy `wasm-to-oci`, and the Bytecode Alliance's **`wasm-pkg-tools` / `wkg`** (the converged standard; the Warg registry project was archived July 2025 and removed from wkg v0.16.0 — **OCI is the primary protocol**).

For Keg, (1.1) maximizes Docker-tooling compatibility; (1.2) is what the wasm-native ecosystem (components, WIT) is converging on. Supporting both is cheap — both are just OCI manifests over HTTP.

## 2. Market signal: Docker is walking away

- Docker docs: *"Wasm workloads are deprecated and will be removed in a future Docker Desktop release. This feature is no longer actively maintained."* (docs.docker.com/desktop/features/wasm)
- The ecosystem energy moved to Kubernetes-side projects: SpinKube (`containerd-shim-spin`, `spin-operator`), KWasm installer, Azure AKS wasi node pools — i.e., server-side, not desktop.
- **Implication for Keg:** there is no maintained desktop developer experience for wasm workloads. A Keg variant that runs wasm workloads natively on macOS with a Docker-compatible API fills a real hole — and Docker's deprecation means no first-party competition.

## 3. Why Apple's `container` framework is not the vehicle

- apple/container runs **Linux** containers as lightweight VMs on Apple Silicon; the Containerization package does low-level container/image/process management for Linux guests. No wasm runtime, no pluggable executor.
- runwasi doesn't help either: it builds on Linux namespaces (`setns`/`unshare`/mount), and community attempts to build it on macOS fail at compile time.
- **Conclusion:** Keg-for-WASM is a *new execution engine*, not an extension of the `container` CLI path. Keg's reusable assets are the app shell, the Docker-API-compatible Hummingbird server (`DockerAPIServer` + `DockerTypes.swift`), registry auth, Compose orchestration, and the VM-based engine for Linux containers.

## 4. Runtime options for a macOS-native engine

| Runtime | Language / integration | WASI support | Performance | Notes |
|---|---|---|---|---|
| **WasmKit** (swiftwasm/WasmKit) | Pure Swift, SwiftPM-friendly; depends only on swift-system; no Foundation | WASI 0.1 majority of syscalls; WASI threads; **component model in progress** (not landed) | Interpreter (register machine). CoreMark ~291 iter/s vs wasmtime ~11,527 iter/s — ~40x slower | Cleanest fit for a Swift 6.2 app; embeddable, compact; macOS 10.13+ |
| **Wasmtime** (Bytecode Alliance) | Rust; official C API (`wasmtime.h`); embeds via a C target in SwiftPM; child-process CLI also viable | Preview 1 + Preview 2 + component model; `wasi:sockets`, `wasi:http` | Cranelift JIT, near-native | The reference runtime; biggest ecosystem; Swift bindings would be hand-written C wrappers |
| **WasmEdge** | C++ with C API; Rust/Go/Java/Python SDKs | WASI + extensions (net, AI/WASI-NN) | AOT via LLVM, near-zero cold start | Cloud-native positioning, k8s pedigree; heavier dependency |
| **WAMR** (wasm-micro-runtime) | C, simple embed APIs; runs on macOS | WASI, interpreter + AOT | Small footprint (~85K interp) | Best for constrained/embedded; least "container ecosystem" tooling |
| **wazero** | Pure Go — not applicable to a Swift app except via child process | — | — | Zero-dependency; relevant only if Keg shells out |

**Recommendation:** prototype with **Wasmtime** (CLI as child process first, then C API embedded) for performance and WASI preview2/component-model coverage; keep **WasmKit** as the pure-Swift long-term option if its component-model support matures. Wasmtime-as-child-process mirrors Keg's existing `Process()` + CLI architecture (`ContainerBridge`), so it's the fastest path to a working vertical slice.

## 5. Architecture options

### Option A — Native WASM engine, embedded (recommended)

```
Keg app ──► WasmEngine (embedded Wasmtime/WasmKit)
                │  pull OCI image/artifact (reuse registry auth)
                │  detect wasi/wasm32 platform or wasm media types
                │  instantiate, wire stdio/logs/stats
                ▼
         macOS process (no VM)
```

- New `WasmBridge` actor parallel to `ContainerBridge`; reuse `DockerAPIServer` routes, translating "container" ops to wasm instance lifecycle.
- Docker API surface: `HostConfig.Runtime = "io.containerd.wasmtime.v1"` selects the wasm engine; `platform=wasi/wasm32` images route automatically.
- Compose: `platform: wasi/wasm` + `runtime:` keys already exist in compose semantics (Docker Desktop used them), so `ComposeOrchestrator` maps naturally.
- **Pros:** no VM, ~1–5 ms cold starts, MB-level memory, works on macOS natively. **Cons:** you own sandboxing semantics (wasm sandbox only — no second layer; note runwasi's precompile-cache CVE shows supply-chain care is needed), and preview1 has no sockets.

### Option B — Linux VM with containerd + runwasi (compat mode)

Reuse Keg's VM expertise: boot one lightweight Linux VM, run containerd with runwasi shims inside, proxy the Docker API.

- **Pros:** full fidelity with Docker/k8s RuntimeClass semantics; existing shim binaries. **Cons:** a VM per workload kills wasm's core value (startup, memory); heavy. Only worth it as a "compat" tier, and Keg's existing k8s-in-container already covers adjacent ground.

### Option C — Hybrid (recommended end-state)

Option A as the primary engine; Linux-container workloads keep going through the existing Apple-VM engine. The Docker API socket fronts both, routing by platform/runtime — exactly how Docker Desktop structured wasm alongside Linux containers.

## 6. Docker API compatibility mapping (for Keg's Hummingbird server)

| Docker API concept | WASM engine mapping |
|---|---|
| `POST /containers/create` (`Image`, `HostConfig.Runtime`, `Env`, `Cmd`, port bindings) | Resolve image; if `platform=wasi/wasm32` or wasm artifact → create wasm "container" record; else existing Linux path |
| `POST /containers/{id}/start` | Instantiate module with WASI ctx (args/env/preopen dirs) |
| Logs / attach | Capture stdout/stderr from WASI stdio streams |
| Stats | Wasmtime `Store` fuel/epoch + memory size; host RSS of instance (approximation — document it) |
| Exec | Not meaningful for preview1 command modules; reject or map to component exports later |
| Networks / port publishing | Preview1 has no sockets. Host-side proxy required: run an HTTP listener in Keg and dispatch to `wasi:http` incoming handlers (like `wasmtime serve` / Spin) — i.e., port mappings become "HTTP route → wasm component", not IP plumbing. Document this semantic difference. |
| Build (`docker build`) | BuildKit path stays Linux-only; wasm images are just `FROM scratch` + COPY, so a minimal builder (or calling `docker buildx --platform wasi/wasm32`) suffices |

## 7. Key gaps and risks

1. **Networking semantics.** WASI preview1 modules can't open sockets; preview2 `wasi:sockets`/`wasi:http` support varies by runtime (Wasmtime yes, WasmKit no yet). Port-mapping UX needs an explicit host-proxy design.
2. **Runtime maturity skew.** WasmKit's component model is unfinished; WasmEdge/Wasmtime are the safe execution bets but are C/Rust dependencies in a SwiftPM world (build complexity, signing/notarization of embedded libs).
3. **Security model is different.** Wasm sandbox *replaces* the VM boundary; supply-chain matters more (see runwasi GHSA-cc25-vq59-rcjx: forged precompiled layers executed native code). Only compile from trusted wasm bytes; never load precompiled artifacts from images unless verified.
4. **No exec/filesystem-as-container semantics.** Preopened directories are the filesystem story; there's no general "ssh into the container".
5. **Ecosystem churn.** Docker's deprecation could slow image availability; the `wasi/wasm` platform convention vs component-artifact convention may still shift (OCI image-spec wasm guidance is young).

## 8. Suggested phased plan

1. **Spike (1–2 wks):** Wasmtime CLI as child process; pull a `wasi/wasm32` image from Docker Hub (e.g. `secondstate/rust-example-hello`); run it, stream logs. No UI.
2. **Vertical slice:** `WasmBridge` actor + Docker API routes for create/start/logs/stop/list + a minimal list row in the Keg UI behind a "Wasm" section.
3. **Distribution breadth:** ORAS-style artifact pulls (`application/wasm` media types), registry auth reuse, `wasi/http` host proxy for port publishing.
4. **Compose:** `platform: wasi/wasm` services in `ComposeOrchestrator`, mixed with Linux services.
5. **Hardening:** resource limits (fuel/epoch interruption, memory caps), supply-chain verification, then evaluate embedded Wasmtime C API vs WasmKit for the engine.

## Sources

- runwasi (containerd sub-project, Rust shim library): https://github.com/containerd/runwasi
- WasmEdge docs — three k8s integration models (containerd-shim/crun/youki): https://github.com/WasmEdge/docs/blob/main/docs/develop/deploy/intro.md
- Docker Desktop Wasm workloads (deprecated notice + installed runtimes): https://docs.docker.com/desktop/features/wasm/
- docker/docs issue confirming deprecation: https://github.com/docker/docs/issues/24183
- Docker containerd image store (wasm requires containerd store): https://docs.docker.com/engine/storage/containerd/
- runwasi security advisory (precompiled layer sandbox bypass): https://github.com/containerd/runwasi/security/advisories/GHSA-cc25-vq59-rcjx
- runwasi does not build on macOS (Finch issue, nix setns/unshare): https://github.com/runfinch/finch/issues/162
- SpinKube containerd-shim-spin (runwasi-based): https://github.com/spinkube/containerd-shim-spin
- WasmKit (pure-Swift WASM runtime, WASI status): https://github.com/swiftwasm/WasmKit
- WasmKit CoreMark benchmark vs wasmtime: https://github.com/swiftwasm/WasmKit/blob/main/Documentation/RegisterMachine.md
- Wasmtime (features, language embeddings incl. C API): https://wasmtime.dev/
- Wasmtime-wasi preview2 bindings: https://docs.wasmtime.dev/api/wasmtime_wasi/p2/bindings/index.html
- Microsoft — distributing Wasm components via OCI registries (media types): https://opensource.microsoft.com/blog/2024/09/25/distributing-webassembly-components-using-oci-registries/
- wasm-pkg-tools / wkg releases (Warg removed in v0.16.0): https://github.com/bytecodealliance/wasm-pkg-tools/releases
- Warg registry archived in favor of wasm-pkg-tools (July 2025): https://github.com/zeroclaw-labs/zeroclaw/issues/7497
- Apple container (Linux containers as VMs; no wasm path): https://github.com/apple/container
- Docker+Wasm usage examples (`--runtime`, `--platform wasi/wasm`): https://thorsten-hans.com/webassembly-and-containers-with-docker-desktop-hello-world-and-beyond/
- wasmdock (measured wasm image sizes, Docker-native wasm toolkit): https://github.com/hariharanragothaman/wasmdock
