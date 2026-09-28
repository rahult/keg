# Cooper — the built-in agent

Cooper is Keg's built-in agent. It answers questions about your containers,
images, Compose projects, and the runtime — and it can *act* on them with
your permission. It prefers Apple's **on-device** model (Apple's
FoundationModels): no cloud calls, no account, and your requests never leave
the machine. On Macs where Apple Intelligence is off or unavailable, Cooper
runs on an OpenAI-compatible model server instead — see
[Runs without Apple Intelligence](#runs-without-apple-intelligence).

## Open it

- Toolbar → the Cooper button (top-right of the main window).
- Right-click any container or image → **Ask Cooper About This…** to start a
  conversation with context preloaded.

## Permission modes

Cooper's agency is controlled by one switch — Settings → Cooper →

| Mode | What Cooper may do |
|------|--------------------|
| **Explore** | Look around and answer questions; never changes anything |
| **Ask** | Proposes actions and confirms every change with you |
| **Execute** | Applies routine actions on its own |

**Destructive actions** (deleting a container or image, stopping the runtime,
deleting a cluster) require your approval in *every* mode — approval cards
appear right in the conversation.

## What it can do

- Answer "what's running?", "how many images do I have?", "why did my
  container fail?"
- Start/stop containers, pull images, run compose projects — per permission
  mode
- Navigate Keg ("open the logs view")
- Answer questions about Keg itself from its built-in knowledge base

## Conversation

- The transcript persists on-device at `~/.keg/cooper` and returns on the
  next launch.
- **Settings → Cooper → Clear Conversation** erases it and starts fresh.
- The first turn after opening the panel can take a few seconds while the
  on-device model loads; later turns are fast.

## Runs without Apple Intelligence

Cooper doesn't stop working when Apple Intelligence does. If the on-device
model is unavailable — turned off, this Mac isn't eligible, or the model
assets are still downloading — Cooper automatically runs on any
**OpenAI-compatible model server** instead:

- **One-click provider presets**: OpenAI, OpenRouter, Groq, DeepSeek,
  Mistral, Together, Fireworks, and local Ollama / LM Studio / vLLM —
  or any custom `chat/completions` endpoint.
- **Same agent, same guardrails**: tool calling, permission modes, and
  approval cards work identically; only the brain changes. Cooper gets
  every tool at once on this path (no per-topic tool subsets).
- **Thinking models**: Cooper requests reasoning (low/medium/high) for
  models that support it, separates thinking from the answer (shown as a
  collapsible "Thinking" section), and never lets `<think>` tags leak into
  the reply. Provider-specific switches (Qwen's `enable_thinking`,
  temperature, `max_tokens`) fit in the Advanced *Extra Request JSON* field.
- **Privacy**: the API key is stored in this Mac's Keychain — never in
  plain preferences — and requests go only to the server you choose.
  Pointing Cooper at a local Ollama keeps everything on this machine.
- **Set it up**: Settings → Cooper → Model backend → *Remote server* (or
  leave *Automatic*, which uses on-device first and falls back). Cooper's
  panel shows which model is answering.
