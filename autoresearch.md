# Autoresearch: Lightweight Agent Footprint

## Session Config

- **Goal:** Reduce memory and storage footprint to minimum while remaining useful
- **Metric 1:** memory_footprint_mb - lower is better
- **Metric 2:** storage_size_mb - lower is better
- **Metric 3:** startup_time_ms - lower is better
- **Max iterations:** 20
- **Status:** running

## Key Findings

### Hybrid Agent Architecture

| Mode | Latency | Memory | Storage | Security |
|------|---------|--------|---------|----------|
| Process | **~4-8ms** | ~0MB | ~0MB | Low |
| Container | ~13-22ms | ~10MB | ~25MB | High |

**Improvement: 3-5x faster** with process mode for safe operations.

### Implementation: HybridAgentRunner

Auto-selects execution mode based on command risk:
- **Safe** (echo, cat, grep) → Process (~5ms, ~0MB)
- **Moderate** (mkdir, cp, vim) → Process (~5ms, ~0MB)
- **Dangerous** (rm -rf, sudo, curl|bash) → Container (~15ms, ~10MB)

## Iteration Results

| Iter | Optimization | memory_mb | storage_mb | latency_ms | Notes |
|------|-------------|-----------|------------|------------|-------|
| 0 | Process spawn | ~0 | ~0 | 4-8 | Baseline |
| 0 | Container exec | ~10 | ~25 | 13-22 | Full isolation |
| 1 | HybridAgentRunner | ~1 | ~0 | 5-15 | Auto mode select |

## Implementation Delivered

### `Sources/Keg/Agent/HybridAgentRunner.swift`

- **Risk assessment** - Evaluates command safety
- **Mode auto-selection** - Process vs Container based on risk
- **Hybrid execution** - Transparent fallback
- **LightweightContainerManager** - Pre-warmed container support

### Risk Detection

```swift
dangerous: ["rm -rf", "sudo", "curl.*|bash", "eval", "dd if=", "mkfs"]
moderate: [">", ">>", "|", "cp ", "mv ", "mkdir", "chmod"]
safe: everything else
```

## Benchmark Script: `footprint_benchmark.sh`

Measures memory and storage footprint for agent workloads.

## Recommendations

1. **Use HybridAgentRunner** for all agent commands
2. **Pre-warm containers** for dangerous operations (faster fallback)
3. **Tune risk rules** based on your security requirements
4. **Monitor mode distribution** to optimize further

## Next Steps

1. [ ] Wire HybridAgentRunner into AgentRuntime
2. [ ] Benchmark real agent workloads
3. [ ] Measure memory reduction vs current approach
4. [ ] Add custom risk rules
