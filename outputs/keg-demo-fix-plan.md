# Keg Quick-Start Demo — Fix & Validation Plan

Date: 2026-09-18 · Scope: make the "Try a 5-second demo" / "Run a web server" quick starts actually work end-to-end, and land the uncommitted fixes.

## Where things stand

**Done (code, uncommitted — 4 modified, 3 new files):**
- `ContainerRunPreset` — hello-world and nginx quick starts open the Run sheet fully prefilled (name, ports `8080:80`, right-sized resources) with an expectations banner.
- `RunContainerView` — PATH-safe exec via `ContainerCLI.makeProcess` (was `/usr/bin/env`, broken for Finder-launched apps), spinner + status + working Cancel during pulls, success views (hello-world greeting shown in-sheet; nginx offers "Open http://localhost:8080"), posts `.kegRefresh` so the list updates after a first run.
- `VolumeMountField` (shared by Run + Edit & Recreate) — plain-language helper text, real example placeholder, Choose Folder… picker, `~` expansion, live human-readable validation (named volumes, relative paths, missing container path); Run disabled while invalid.
- Tests: 17 new (presets, volume validation, arg building); full suite 415 passed / 0 failures; debug + signed release builds verified; app launches and renders.

**Blocked (environment):** image pulls hang forever with zero output — CLI and app alike. Reproduced with raw `container run hello-world`. Network to Docker Hub is fine (registry-1.docker.io → 401 in 0.7s). Hours-old stuck `image pull` / `rm -f keg-*` processes predate this session. No proxy involved.

## Plan

### 1. Reboot the Mac
The container runtime stack is wedged at the launchd/XPC level: `container system stop` and `system start` hang at "Testing access to container-apiserver…" even after full bootout/bootstrap recycles, on both container 1.3.1 and 1.4.1, on macOS 27.0 (26A428). A reboot is the standard remaining remedy for stale mach-service state. (Already done during this session: homebrew container upgraded 1.3.1 → 1.4.1; all three launchd labels booted out and respawned; stuck clients killed.)

### 2. Verify the pull path after reboot
```bash
container system status                      # should answer, not hang
time container run hello-world               # should print the greeting in seconds
```
If pulls work: proceed to step 3. If they still hang: sample the CLI (`sample <pid> 2` — expect it parked in its run loop waiting on an XPC reply), then file an apple/container issue with: macOS 27.0 build 26A428, container 1.4.1, the silent-hang symptom, the sample stack, and the observation that list queries answer while pull/machine-creation requests never do.

### 3. End-to-end the quick starts through Keg
- Launch Keg → Containers empty state → **Try a 5-second demo** → sheet prefilled (name `hello-world`, 1 CPU / 512M, detached off) → Run → greeting appears in-sheet → Done → exited container visible in list.
- **Run a web server** → sheet prefilled (name `web-server`, ports `8080:80`) → Run → "Open http://localhost:8080" → nginx serving in browser.
- Edit & Recreate on the nginx container → volume field shows the shared component; type `mydata:/data` → orange plain-language warning, Run disabled.
- Cancel path: start a run, hit Cancel during a slow pull → "Cancelled." shown, sheet usable.

### 4. Land the changes
Review the diff (4 modified: ContainerRunArguments, ContainerListView, RecreateContainerView, RunContainerView; 3 new: ContainerRunPreset.swift, RunFormFields.swift, QuickStartPresetTests.swift), then commit once step 3 passes — the quick-start promise ("5 seconds") should not ship until a pull has actually completed on this machine.

### 5. Follow-ups (not this round)
- Stream pull progress lines into the Run sheet instead of a bare spinner.
- Same style of inline validation for the Ports field.
- Consider surfacing "runtime is not answering" in the UI when `container` health checks hang, instead of an eternal spinner.
