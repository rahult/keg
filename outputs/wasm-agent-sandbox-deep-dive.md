# Why WASM Is Not the De-Facto Sandbox for Agent Harnesses — Deep Dive

**Date:** 2026-09-15
**Question:** WASM has 1–10 ms cold starts, MB-level memory, and a capability-based security model — theoretically ideal for running untrusted agent-generated code. Yet every serious agent harness chose containers, microVMs, or OS sandboxes instead. Why?

---

## TL;DR

WASM optimizes for the axis agent sandboxes *don't* need (startup latency) and constrains the axes they *do* need (arbitrary processes, native packages, sockets, threads, GPUs). The security problem WASM solved was already being solved from the other side: Firecracker-class microVMs got fast enough (≈125 ms boot, <5 MB overhead, snapshot-resume ≈ container speed) while keeping a *general-purpose Linux runtime*. Agent workloads are open-ended — "clone this repo, install deps, run the tests, start a server, drive a browser" — and WASI is, by design, a closed-ended system interface. Result: the industry converged on "microVM for the general runtime, WASM for narrow capability-scoped tools," and the evidence for that split is now overwhelming.

## 1. What an agent sandbox must actually do

Survey the requirements stated by the vendors themselves:

- **E2B** (the de-facto agent sandbox cloud): "AI-generated Python, JavaScript, Ruby, or C++? Popular framework or custom library? **If you can run it on a Linux box, you can run it in the E2B sandbox.**" — install packages at runtime, use terminals, browsers, run up to 24-hour sessions, snapshot/resume.
- **Genspark** (via E2B): "A general-purpose agent needs a general-purpose runtime… execute arbitrary code, install packages on the fly, run long-running workflows, access the web, maintain persistent state."
- **Anthropic** (across Claude.ai / Claude Code / Cowork): gVisor for the hosted product, Seatbelt (macOS) + Bubblewrap (Linux) locally, full VMs for Cowork. Layers: process sandboxes, VMs, filesystem boundaries, egress controls.

The common denominator: **open-ended execution of an unpredictable workload.** The agent doesn't know what it'll need; the sandbox must be able to become anything. That is the exact opposite of WASM's design goal (a minimal, statically declared capability set).

## 2. What the market actually chose

| Vendor / product | Sandbox mechanism | WASM? |
|---|---|---|
| E2B (Devin Outposts, Genspark, Lindy, Vapi…) | Firecracker microVM, per-sandbox kernel, snapshot-resume | No |
| Anthropic Claude.ai | gVisor (user-space kernel) | No |
| Anthropic Claude Code (local) | Seatbelt (macOS), Bubblewrap (Linux) | No |
| Anthropic Cowork | Full VM (Apple Virtualization.framework / HCS) | No |
| Retool code executor | nsjail; agent sandbox = gVisor + seccomp | No |
| OpenAI Code Interpreter family | Container-based isolated envs | No |
| NearAI IronClaw (agent framework) | WASM — **but only for individual tools**, explicitly zero-system-access capability grants | Partial |

Pattern: WASM appears in agent stacks *only at the tool/plugin layer* — single functions with explicit host-granted capabilities, fresh instance per call (IronClaw's design: compile once, instantiate per execution, no state reuse). Nobody ships a general-purpose agent runtime on WASM.

## 3. The technical blockers, in order of severity

### 3.1 No process model — the killer

Agents live and die by `subprocess`. Testing a repo means spawning the test runner; building means spawning the compiler; serving means a long-lived process tree. WASI has **no fork/exec, no `waitpid`, no signals, no IPC**. CPython's own docs are blunt: on wasm32, "process-related APIs are not available or always fail… `subprocess` is importable but does not work." An agent that can't spawn a child process can't do most of what agents are hired to do. This is a *design* decision (POSIX `fork()` is considered unsandboxable), not an implementation gap that's about to close.

### 3.2 No dynamic loading → the Python ecosystem is crippled

Python is the agent language. On WASI:

- **CPython cannot dynamically load extension modules** — a platform-level limitation, not a tooling bug (PyO3/maturin: "CPython on WASI cannot dynamically load .so/.wasm extension modules at runtime"). NumPy, pandas, lxml, cryptography — the scientific stack agents reach for constantly — are native extensions.
- Only pure-Python (`py3-none-any`) wheels are viable, and even then only if they avoid sockets/threads/processes (Brett Cannon's WASI testing write-up).
- `pip install` at runtime — the single most common agent recovery move — barely works: sockets are missing, native builds impossible.
- CPython-on-WASI is Tier 2, startup is slow, and big chunks of the stdlib are stubs. Even enthusiastic experiments (RustPython on wasmer) conclude: *"I don't see this being a viable, general-purpose AI code sandbox anytime soon."*

### 3.3 Networking has been "almost there" for years

WASI preview1 has essentially no sockets (only inherited file descriptors). Preview2 added `wasi:sockets`/`wasi:http` — but only for **components**, meaning every existing preview1 binary and every native library is stuck without recompilation. Preview2 went GA in Jan 2024; full runtime support only landed across Wasmtime/WasmEdge/Wasmer through 2025. By then, microVMs had already won the sandbox market.

### 3.4 Threads and parallelism

The Wasm threads proposal is still in progress; per-instance execution is effectively single-threaded. Agents run pytest -n, parallel builds, multi-process servers. WASIX (Wasmer) adds fork/sockets/pthreads — but it's a single-vendor extension, undermining WASM's core portability pitch, and adds a native-code trust surface of its own.

### 3.5 No GPU story

Agent sandboxes increasingly need GPUs (local inference, vision, RL rollouts — E2B explicitly runs "RL rollouts"). WASM has `wasi-nn` (experimental, inference-only, no general compute) and nothing else. Firecracker itself lacks PCIe passthrough, which pushes GPU workloads to full VMs — still a more complete answer than WASM's.

### 3.6 Debugging, observability, ecosystem gravity

When an agent's `npm install` fails in a container, you can `docker exec` in, strace it, read dmesg, inspect /proc. The OCI ecosystem — registries, scanning, SBOMs, cosign, decades of Unix tooling — is the debugging substrate agent harnesses are built on. Server-side WASM debugging is still "logging and trap messages." For harness builders, the ecosystem *is* the product.

## 4. Why WASM's security advantage didn't close the deal

WASM's pitch was: safer than containers because the sandbox is the VM boundary itself, no shared kernel, capability-default-deny. But the security race was won from the other direction:

- **Firecracker**: boots in ~125 ms, <5 MB per-VM overhead, 50k lines of Rust VMM code, built by AWS to run untrusted multi-tenant code (Lambda/Fargate) — a *hardware* boundary with a *general-purpose* runtime inside.
- **Snapshot-resume** (E2B's layer) erases the cold-start gap entirely: "VMs are slow to start. Ours boot from a snapshot, so every session gets its own kernel at container speed."
- Recent kernel CVEs (e.g. Copy Fail) illustrate why vendors pay for per-sandbox kernels: container tenants sharing a host kernel share the blast radius; microVM tenants don't.

So the choice became: **hardware isolation + full Linux** vs **software sandbox + restricted WASI**. For open-ended agent workloads, the first dominates. WASM's capability model is the right abstraction for *composable, trusted-interface plugins* — and that's exactly where it landed (IronClaw tools, Extism, Shopify Functions, Cloudflare Workers).

## 5. The honest scorecard

| Requirement | MicroVM (Firecracker) | WASM (WASI p2) |
|---|---|---|
| Cold start | ~100–300 ms (≈0 with snapshot resume) | 1–10 ms ✅ |
| Memory overhead | 5–20 MB | 1–5 MB ✅ |
| Run arbitrary binaries | ✅ anything that runs on Linux | ❌ must recompile to wasm32 |
| `subprocess` / process trees | ✅ | ❌ design-level absence |
| Native packages (pip/apt) | ✅ | ❌ no dynamic loading, no sockets |
| Sockets / servers | ✅ | ⚠️ preview2 components only |
| Threads | ✅ | ⚠️ proposal in progress |
| GPU | ⚠️ via full VM passthrough | ❌ wasi-nn only |
| Debug/observability | ✅ full Unix + OCI tooling | ❌ logging/traps |
| Isolation strength | hardware boundary | software sandbox + host runtime CVEs (e.g. runwasi precompile-cache advisory) |
| Session length | 24 h+, snapshot/resume | instance-scoped, no hibernation |

WASM wins the two rows that matter for *edge functions* and loses every row that matters for *agent runtimes*.

## 6. Where WASM *is* the right answer in agent stacks

- **Tool/plugin isolation**: narrow, capability-scoped functions with host-granted imports (IronClaw's per-call fresh instances; Extism; Shopify Functions). Deterministic, fast, safe — because the workload is *defined*, not open-ended.
- **Edge/serverless functions**: Cloudflare Workers, Fastly Compute@Edge — stateless request handlers, exactly WASM's shape.
- **MCP-style capability surfaces**: if a tool's authority can be enumerated up front, WASM's default-deny model is superior to giving it a Linux box.

Rule of thumb from the field: **WASM for functions, containers/microVMs for services.**

## 7. What would change the calculus (and why it's years out)

1. **A process/IPC story in WASI** — contradicts the sandboxing design goal; WASIX is single-vendor. Not on any standards track that matters.
2. **Dynamic linking for native extensions** — would require wasm targets for the entire scientific Python stack; the PyO3 issue calls it a platform limitation.
3. **GPU compute in WASI** — wasi-nn is inference-shaped; no general path.
4. **Component-model maturity + preview1 deprecation** — the ecosystem's 2024–2025 retooling is still mid-flight; agent harness builders don't bet platforms on toolchain churn.
5. **If** wasm ever gets a full POSIX-compatible, GPU-capable, dynamically-linkable hosted profile, it stops being WASM — it becomes a slower Linux you have to cross-compile for.

## 8. Implication for Keg

Keg's one-VM-per-container model is architecturally aligned with where the agent-sandbox market actually went (E2B-style microVMs). The WASM engine research (`webassembly-containers-research.md`) is still worth building — but positioned as a **fast lane for wasm-packaged workloads and tools** (the rows WASM wins), not as a general container replacement. The hybrid thesis holds: Docker-compatible API, Linux-VM engine for general workloads, WASM engine for `wasi/wasm` artifacts.

## Sources

- E2B architecture & positioning: https://e2b.dev/ , https://e2b.dev/security , https://e2b.dev/blog/not-affected-by-copy-fail-heres-why , https://e2b.dev/blog/genspark , https://e2b.dev/blog/devin-outposts
- E2B on Firecracker: https://e2b.dev/resources/firecracker-vs-qemu
- Anthropic sandbox overview (via Simon Willison): https://simonwillison.net/2026/May/30/how-we-contain-claude/
- Retool sandboxing (nsjail/gVisor comparison): https://docs.retool.com/self-hosted/self-managed/concepts/custom-code-execution-security
- CPython docs — WebAssembly platform limitations: https://docs.python.org/3/library/intro.html
- PyO3/maturin — no dynamic loading on WASI: https://github.com/PyO3/maturin/issues/2338
- Brett Cannon — testing Python on WASI CPython: https://snarky.ca/testing-a-project-using-the-wasi-build-of-cpython-with-pytest/
- Python WASI distribution discussion (no extension modules): https://discuss.python.org/t/wasi-distribution-poc/108168
- RustPython-on-WASM experiment ("not a viable general-purpose AI code sandbox anytime soon"): https://notes.alexkehayias.com/rustpython-with-wasm/
- WASIX docs (POSIX gaps WASI doesn't fill): https://wasix.org/docs/
- eunomia — WASI/component model status (no fork/exec/signals/IPC): https://eunomia.dev/blog/2025/02/16/wasi-and-the-webassembly-component-model-current-status/
- Zylos — WASM sandboxing for agent runtime isolation (no fork/exec as feature): https://zylos.ai/research/2026-03-12-wasm-sandboxing-ai-agent-runtime-isolation/
- IronClaw (NearAI) — WASM tool sandbox design: https://nearai-ironclaw.mintlify.app/security/wasm-sandbox
- WASM vs Docker cold-start comparison: https://vimm0.github.io/webassembly/backend/2026/05/11/webassembly-2026-beyond-the-browser-and-into-the-stack.html
- 2026 server-side WASM landscape survey: https://www.youngju.dev/blog/culture/2026-05-25-webassembly-wasi-spin-wasmtime-wasmer-wasmedge-component-model-2026-deep-dive.en
- runwasi precompiled-layer security advisory: https://github.com/containerd/runwasi/security/advisories/GHSA-cc25-vq59-rcjx
