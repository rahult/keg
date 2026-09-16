# Keg + WebAssembly — Position Paper (ADR)

**Status:** Proposed
**Date:** 2026-09-15
**Deep dives:** [WASM containers research](/Volumes/Atlas/Code/projects/meadow/outputs/webassembly-containers-research.md) (build options) · [Agent-sandbox deep dive](/Volumes/Atlas/Code/projects/meadow/outputs/wasm-agent-sandbox-deep-dive.md) (market analysis)

---

## Context

Three facts frame this decision:

1. **Docker deprecated WASM.** Docker Desktop's Wasm workloads ("enable Wasm" + containerd image store) are officially deprecated and unmaintained. The ecosystem energy moved to Kubernetes shims (SpinKube, runwasi, KWasm). There is no maintained *desktop* developer experience for wasm workloads — the exact class of product Keg is.
2. **Apple's `container` framework cannot run WASM.** It runs Linux containers as lightweight VMs; no pluggable executor exists, and runwasi itself requires Linux namespaces and doesn't build on macOS. A wasm path in Keg is a new engine, not an extension of the `container` CLI bridge.
3. **The agent-sandbox market — the loudest "WASM will replace containers" audience — chose microVMs.** E2B (Firecracker, powering Devin/Genspark), Anthropic (gVisor / Seatbelt / full VMs), Retool (nsjail/gVisor) all run general-purpose Linux. WASM appears only as capability-scoped tool isolation (e.g. IronClaw). Firecracker-class microVMs got fast enough (~125 ms boot, snapshot-resume at container speed) while keeping full POSIX — which erased WASM's startup advantage without its restrictions.

## Decision

**D1 — Keg's one-VM-per-container architecture is validated, not legacy.**
The market independently converged on microVM-per-workload for untrusted, open-ended code. Keg is architecturally aligned with where agent/harness infrastructure went. No change; this is the core engine.

**D2 — Build a native macOS WASM engine as a *fast lane*, exposed through the existing Docker-compatible API.**
WASM runs natively on macOS — no VM, millisecond starts, KB–MB images. Keg should run `wasi/wasm` OCI images and wasm OCI artifacts via an embedded runtime (Wasmtime first: CLI-as-child-process, then C API; WasmKit as the pure-Swift long-term option), routed by `platform: wasi/wasm` + `runtime:` — the same keys Docker Desktop used, so Compose files and muscle memory transfer. Reuse `DockerAPIServer`, registry auth, and `ComposeOrchestrator`; add a `WasmBridge` actor parallel to `ContainerBridge`.

**D3 — WASM is a complement, never the general-runtime story.**
Do not position or architect Keg-for-WASM as a container replacement, and do not chase the agent-sandbox use case with WASM. The blockers are structural, not maturity: no fork/exec/subprocess (a design decision), no dynamic loading (Python's native stack is dead on WASI), no threads/GPU, sockets only via preview2 components. Reversal conditions are listed below; none are on a near-term track.

## Consequences

- **Product:** Keg becomes the natural home for wasm workloads on macOS the moment Docker Desktop removes its feature — a "pull a `wasi/wasm` image and run it" experience that currently has no first-party owner.
- **Engineering:** the hybrid router (platform/runtime keys → Linux-VM engine or WASM engine) becomes a permanent part of `DockerAPIServer`. Port publishing for wasm services is a host-side HTTP proxy to `wasi:http` handlers — document this semantic difference; it is not IP plumbing.
- **Security:** the wasm sandbox *replaces* the VM boundary on this path — supply-chain rigor matters more (see the runwasi precompiled-layer advisory: never execute precompiled artifacts from untrusted image layers).
- **Non-goals:** no WASM Kubernetes story (Keg's k8s path stays Linux), no WASM build support beyond `FROM scratch` + COPY, no general-process emulation.

## Execution plan (from the research note)

1. Spike: Wasmtime CLI child process; pull `secondstate/rust-example-hello`; run; stream logs.
2. Vertical slice: `WasmBridge` + Docker API create/start/logs/stop/list + a "Wasm" section in the UI.
3. Distribution breadth: ORAS-style artifact pulls (`application/wasm` media types), `wasi:http` port proxy.
4. Compose: `platform: wasi/wasm` services, mixed stacks with Linux services.
5. Hardening: fuel/epoch + memory limits, artifact verification, embedded-runtime evaluation.

## Reversal conditions for D3

Revisit the "complement, not replacement" stance only if *all* of: (a) WASI gains a standardized process/IPC story, (b) dynamic loading lands for the scientific Python stack, (c) general GPU compute exists in WASI, (d) preview2 components become the uncontested default. (a) contradicts the sandboxing design goal and (b) is called a platform limitation by the PyO3 maintainers — treat this list as a decade-scale horizon, not a roadmap input.

## Sources

Primary sources for every claim are inline in the two deep-dive notes linked at the top. Key ones: [Docker wasm deprecation](https://docs.docker.com/desktop/features/wasm/), [runwasi](https://github.com/containerd/runwasi), [WasmKit](https://github.com/swiftwasm/WasmKit), [CPython WASM limitations](https://docs.python.org/3/library/intro.html), [E2B architecture](https://e2b.dev/security), [Anthropic sandbox overview](https://simonwillison.net/2026/May/30/how-we-contain-claude/).
