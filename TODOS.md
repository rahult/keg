# Keg — TODOS

## P0: Post-demo critical

### Docker API contract tests
Write integration tests that start DockerAPIServer on a Unix socket, connect with the real `docker` CLI, and verify `docker ps`, `docker images`, `docker network ls` return correct data. Requires docker CLI on test machine. Proves the Docker replacement claim. Depends on: Docker API stub routes wired to ContainerBridge.
**Status:** done (2026-09-18) — `Scripts/docker-cli-contract-test.sh` runs the real docker CLI against the socket: 15/15 checks incl. run/exec/exec -i exit codes, streaming pull, stats, events, volumes, df, classic build.
**Added:** 2026-04-16 (eng review)

### BuildKit session support for `docker build`
docker 29 dropped the classic builder client-side; the CLI now always negotiates BuildKit (`GET /containers/buildx_buildkit_default/json` probe, then `/session` + `/build` with session forwarding). Classic `POST /build` still works for API clients (Testcontainers, docker-java). Full CLI build support means implementing the session attach protocol.
**Status:** not started
**Added:** 2026-09-18

## P1: Ship polish

### Launch-at-login + socket cleanup
Add "Launch at Login" toggle in Settings using SMAppService (macOS native). Add socket cleanup on app quit (remove stale ~/.keg/docker.sock). Add crash recovery (detect and clean stale sockets on launch). Makes Keg invisible infrastructure like Docker Desktop. Requires proper code signing for SMAppService. Depends on: Docker API auto-start setting.
**Status:** done (2026-09-18) — LoginItemController (SMAppService) in Settings → Docker API; socket unlinked in applicationWillTerminate and stopDockerAPI; launch-time stale-socket cleanup already guarded by ping liveness.
**Added:** 2026-04-16 (eng review)

### Cross-area references in sidebar
Show agent container count badge in the Keg sidebar when agents are running containers. Show running container count in the Agent dashboard. Bridges the dual identity so users see that agents USE containers. Decision from design review Pass 1.
**Status:** not started
**Added:** 2026-04-16 (design review)

### Agent interaction states
Specify and implement empty, loading, error, and success states for all agent views: agent list (no agents, no API key), agent dashboard (no sessions), session streaming (connecting, running, complete, failed), MCP connection (connecting, connected, failed). Follow existing DESIGN.md patterns (ContentUnavailableView for empty, overlay banners for errors). Decision from design review Pass 2.
**Status:** not started
**Added:** 2026-04-16 (design review)

### Agent discovery card on container dashboard
When in Keg area with 0 agents configured, show a dismissable card on the system dashboard: "Run AI agents in isolated containers. Switch to Agents to get started." Bridges the user journey from Docker replacement to agent platform. Decision from design review Pass 3.
**Status:** not started
**Added:** 2026-04-16 (design review)

### Menu bar dual status
Add agent status to menu bar popover: "Active Agents: N" and "Running Sessions: N" below container info. The menu bar is the always-visible heartbeat. Both tracks should be visible. Decision from design review Pass 7.
**Status:** not started
**Added:** 2026-04-16 (design review)

### Docker API streaming responses
Implement streaming responses for pull, build, logs, and events endpoints. Currently these return synchronous responses or empty arrays, but real `docker pull` expects chunked JSON streaming. Significant work: Hummingbird streaming + ContainerBridge streaming integration. Blocks real Docker CLI usage beyond `docker ps`/`docker images`.
**Status:** done (2026-09-18) — pull/push/build stream Docker JSON progress; logs follow streams raw chunks; events stream from the poll-differed ContainerEventBus; exec/attach hijack (101 + splice) makes `docker exec`/`docker run` work end-to-end with real exit codes via XPC.
**Added:** 2026-04-16 (eng review)
