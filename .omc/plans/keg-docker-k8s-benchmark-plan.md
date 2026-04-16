# Keg Docker & Kubernetes Benchmark Plan

**Goal:** Verify Keg can serve as a complete Docker Desktop replacement by benchmarking and testing every Docker and Kubernetes capability end-to-end.

**Date:** 2026-04-16
**Branch:** main

---

## Requirements Summary

After this plan is executed, the user should be able to:
1. Uninstall Docker Desktop and use Keg for all container workflows
2. Have benchmark numbers proving Keg's performance (boot time, container start, image pull)
3. Have passing tests for every Docker API endpoint they'd use daily
4. Have a working K8s cluster for local dev (deploy, service, ingress)
5. Know exactly what works, what doesn't, and what's a known limitation

---

## Acceptance Criteria

| # | Criterion | Verification |
|---|-----------|-------------|
| AC1 | `docker ps`, `docker images`, `docker run` work via Keg socket | Run commands, compare output to Docker Desktop |
| AC2 | `docker compose up/down` works for a real multi-service stack | Test with nginx+redis+postgres compose file |
| AC3 | Container boot time < 2 seconds | Timed benchmark, 10 runs averaged |
| AC4 | Image pull speed within 20% of Docker Desktop | Pull nginx, alpine, node side-by-side |
| AC5 | K8s cluster creates in < 90 seconds | Timed benchmark |
| AC6 | `kubectl get pods`, `kubectl apply`, `kubectl logs` work | Deploy nginx, verify pods, check logs |
| AC7 | Volume persistence works across container restarts | Write data, restart, read back |
| AC8 | Network isolation works (custom networks) | Two containers on separate networks can't talk |
| AC9 | Container logs stream correctly | Long-running container, verify log capture |
| AC10 | All 26 Docker API routes return valid responses | Hit each route, validate JSON schema |

---

## Implementation Steps

### Phase 1: Docker CLI Compatibility Benchmark (Sources/Keg/DockerAPI/)

**What:** Verify every `docker` CLI command works through Keg's Unix socket.

| Step | Command to test | Expected | File |
|------|----------------|----------|------|
| 1.1 | `docker ps` | Lists running containers | DockerAPIServer.swift:212 |
| 1.2 | `docker ps -a` | Lists all containers | DockerAPIServer.swift:212 |
| 1.3 | `docker images` | Lists local images | DockerAPIServer.swift:281 |
| 1.4 | `docker run -d --name test nginx` | Creates + starts container | DockerAPIServer.swift:218,226 |
| 1.5 | `docker stop test` | Stops container | DockerAPIServer.swift:232 |
| 1.6 | `docker rm test` | Removes container | DockerAPIServer.swift:251 |
| 1.7 | `docker logs test` | Returns container logs | DockerAPIServer.swift:264 |
| 1.8 | `docker inspect test` | Returns container details | DockerAPIServer.swift:258 |
| 1.9 | `docker pull alpine` | Pulls image | DockerAPIServer.swift:286 |
| 1.10 | `docker network ls` | Lists networks | DockerAPIServer.swift:313 |
| 1.11 | `docker volume ls` | Lists volumes | DockerAPIServer.swift:327 |
| 1.12 | `docker info` | Returns system info | DockerAPIServer.swift:206 |
| 1.13 | `docker version` | Returns version | DockerAPIServer.swift:191 |

**Test file:** `Tests/KegTests/DockerCLIBenchmarkTests.swift` (new)

### Phase 2: Performance Benchmarks

**What:** Measure and compare Keg's performance against known Docker Desktop numbers.

| Benchmark | Method | Target | Docker Desktop baseline |
|-----------|--------|--------|------------------------|
| 2.1 Container start time | Time `container run` 10x, average | < 2s | ~3-5s |
| 2.2 Container stop time | Time `container stop` 10x, average | < 2s | ~2-3s |
| 2.3 Image pull (alpine) | Time pull from cold, 5x | < 15s | ~10-20s |
| 2.4 Image pull (nginx) | Time pull from cold, 5x | < 30s | ~20-40s |
| 2.5 System idle RAM | Measure RSS with 0 containers | < 100MB | ~500MB-2GB |
| 2.6 Per-container RAM | RSS delta per alpine sleep container | < 50MB | ~30-50MB |
| 2.7 Container exec latency | Time exec of `echo hello`, 10x | < 500ms | ~200-500ms |

**Test file:** `Tests/KegTests/PerformanceBenchmarkTests.swift` (new)

### Phase 3: Docker Compose Real-World Stacks

**What:** Test compose with stacks developers actually use.

| Stack | Services | Tests |
|-------|----------|-------|
| 3.1 Web app | nginx + redis | up, verify both running, down |
| 3.2 Full stack | postgres + node API + nginx proxy | up, verify connectivity, down |
| 3.3 Dev environment | postgres + redis + mailhog | up, verify ports, down |

**Compose files:** Written as test fixtures in `Tests/KegTests/Fixtures/`
**Test file:** `Tests/KegTests/ComposeStackTests.swift` (new)

### Phase 4: Kubernetes End-to-End

**What:** Full K8s workflow from cluster creation to workload deployment.

| Step | What | Verification |
|------|------|-------------|
| 4.1 | Create cluster | Node status = Ready |
| 4.2 | Deploy nginx | Pod status = Running |
| 4.3 | Create service | Service has ClusterIP |
| 4.4 | Scale to 3 replicas | 3 pods Running |
| 4.5 | Rolling update | New image deployed, 0 downtime |
| 4.6 | Create ConfigMap + Secret | Mounted in pod, values readable |
| 4.7 | Run CronJob | Job completes successfully |
| 4.8 | kubectl logs | Logs from running pod readable |
| 4.9 | kubectl exec | Command runs inside pod |
| 4.10 | Delete cluster | Container removed, kubeconfig cleaned |

**Test file:** Already exists: `Tests/KegTests/KubernetesShadowTests.swift` (extend)

### Phase 5: Docker API Contract Tests

**What:** Hit every Docker API route through the Unix socket and validate responses.

All 26 routes from DockerAPIServer.swift must:
- Return valid HTTP status codes
- Return valid JSON (where applicable)
- Match Docker Engine API schema for critical fields

**Test file:** `Tests/KegTests/DockerAPIContractTests.swift` (new)

### Phase 6: Reliability & Edge Cases

| Test | What | Why |
|------|------|-----|
| 6.1 | Kill container mid-exec | Graceful cleanup |
| 6.2 | Pull non-existent image | Clear error, no crash |
| 6.3 | Run with invalid port mapping | Error message, not crash |
| 6.4 | Stop already-stopped container | Idempotent, no error |
| 6.5 | Remove running container (no force) | Error, suggests --force |
| 6.6 | Compose up with missing image | Error on the failing service |
| 6.7 | 50 concurrent container starts | No race conditions |
| 6.8 | Docker API request with malformed JSON | 400, not crash |
| 6.9 | Docker API request with special chars in name | Handled, not crash (the bug we just fixed) |

**Test file:** `Tests/KegTests/ReliabilityTests.swift` (new)

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Apple Container CLI changes between versions | Tests break | Pin to container v0.11.0 in Package.swift |
| K8s cluster creation takes too long for CI | Tests timeout | Use KEG_RUN_K8S_E2E env gate, separate from fast tests |
| Docker API compat gaps | Users hit unsupported commands | Document known limitations, return proper 501 Not Implemented |
| XPC timeouts on stop/restart | Flaky tests | Add retry logic with exponential backoff |
| Memory pressure during benchmarks | Unreliable numbers | Run benchmarks in isolation, 3 warm-up runs |

---

## Verification Steps

1. Run all Docker tests: `KEG_RUN_CONTAINER_E2E=1 KEG_RUN_DOCKER_API=1 swift test --filter "DockerShadowTests|DockerCLIBenchmarkTests|DockerAPIContractTests|ComposeStackTests|ReliabilityTests"`
2. Run K8s tests: `KEG_RUN_K8S_E2E=1 swift test --filter KubernetesShadowTests`
3. Run performance benchmarks: `KEG_RUN_CONTAINER_E2E=1 swift test --filter PerformanceBenchmarkTests`
4. All tests pass with 0 failures
5. Benchmark results printed to stdout and saved to `outputs/benchmarks/`

---

## Execution Order

```
Phase 1 (Docker CLI)  ──┐
Phase 2 (Benchmarks)  ──┼── Parallel (independent)
Phase 5 (API Contract)──┘
Phase 3 (Compose)     ──── After Phase 1 (needs working Docker API)
Phase 6 (Reliability) ──── After Phase 1 (needs working containers)
Phase 4 (Kubernetes)  ──── Independent (long-running, separate env gate)
```

Phases 1, 2, 5 can run in parallel worktrees. Phase 3 and 6 after. Phase 4 independently.
