# Cooper — the built-in agent

Cooper is Keg's built-in agent. It answers questions about your containers,
images, Compose projects, and the runtime — and it can *act* on them with
your permission. It runs **entirely on-device** using Apple's FoundationModels:
no cloud calls, no account, and your requests never leave the machine.

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
