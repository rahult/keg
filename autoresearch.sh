#!/bin/bash
# Agent Container Benchmark v5 - Container Pooling Test
# Measures cold start vs warm reuse

set -e

RESULTS_FILE="/tmp/agent_benchmark_results.json"
TEMP_COLD="/tmp/bench_cold.txt"
TEMP_WARM="/tmp/bench_warm.txt"
TEMP_EXEC="/tmp/bench_exec.txt"

echo "=== Agent Container Benchmark v5 ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Pre-warm a container
echo "Pre-warming test container..."
container rm test-pool-1 2>/dev/null || true
container create --name test-pool-1 alpine:latest sh 2>/dev/null
container start test-pool-1 2>/dev/null
sleep 0.5
echo "  Ready"

# Cold start test
echo ""
echo "=== Cold Start (3 iterations) ==="
total=0
for i in 1 2 3; do
    container rm test-cold 2>/dev/null || true
    start=$(date +%s%N)
    container run --name test-cold -d alpine:latest sleep 30 2>/dev/null || true
    end=$(date +%s%N)
    duration=$(( (end - start) / 1000000 ))
    total=$(( total + duration ))
    echo "  Iter $i: ${duration}ms"
done
cold_avg=$(( total / 3 ))
echo "  Average: ${cold_avg}ms"

# Warm reuse test (stop/start)
echo ""
echo "=== Warm Reuse (5 iterations) ==="
total=0
for i in 1 2 3 4 5; do
    start=$(date +%s%N)
    container stop test-pool-1 2>/dev/null || true
    container start test-pool-1 2>/dev/null || true
    end=$(date +%s%N)
    duration=$(( (end - start) / 1000000 ))
    total=$(( total + duration ))
    echo "  Iter $i: ${duration}ms"
done
warm_avg=$(( total / 5 ))
echo "  Average: ${warm_avg}ms"

# Warm exec test (just exec into running container)
echo ""
echo "=== Warm Exec (5 iterations) ==="
total=0
for i in 1 2 3 4 5; do
    start=$(date +%s%N)
    container exec test-pool-1 echo ok > /dev/null 2>&1
    end=$(date +%s%N)
    duration=$(( (end - start) / 1000000 ))
    total=$(( total + duration ))
    echo "  Iter $i: ${duration}ms"
done
exec_avg=$(( total / 5 ))
echo "  Average: ${exec_avg}ms"

# Cleanup
echo ""
echo "=== Cleanup ==="
container rm test-pool-1 test-cold 2>/dev/null || true

# Calculate improvement
improvement=$(( cold_avg - warm_avg ))
if [ $cold_avg -gt 0 ]; then
    pct=$(( (improvement * 100) / cold_avg ))
else
    pct=0
fi

# Save results
cat > "$RESULTS_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "iteration": 1,
  "cold_start_avg_ms": ${cold_avg},
  "warm_reuse_avg_ms": ${warm_avg},
  "warm_exec_avg_ms": ${exec_avg},
  "improvement_ms": ${improvement},
  "improvement_pct": ${pct}
}
EOF

echo ""
echo "=== SUMMARY ==="
echo "Cold start:   ${cold_avg}ms"
echo "Warm reuse:  ${warm_avg}ms"
echo "Warm exec:   ${exec_avg}ms"
echo "Improvement: ${improvement}ms (${pct}%)"
echo ""
echo "Results: $RESULTS_FILE"
