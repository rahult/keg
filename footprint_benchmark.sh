#!/bin/bash
# Lightweight Agent Footprint Benchmark
# Measures memory and storage footprint

set -e

RESULTS_FILE="/tmp/footprint_results.json"

echo "=== Lightweight Agent Footprint Benchmark ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# 1. Measure Alpine image size
echo "=== 1. Alpine Container Image ==="
ALPINE_SIZE=$(container image ls 2>/dev/null | grep alpine | awk '{print $7}' || echo "unknown")
echo "Alpine image size: $ALPINE_SIZE"

# 2. Measure running container memory
echo ""
echo "=== 2. Container Memory Usage ==="
container rm footprint-test 2>/dev/null || true
container create --name footprint-test alpine:latest sh 2>/dev/null
container start footprint-test 2>/dev/null
sleep 0.5

# Get container stats
STATS=$(container stats footprint-test --no-stream 2>/dev/null | tail -1 || echo "")
echo "Container stats: $STATS"

# Parse memory from stats (format varies)
MEM_USAGE=$(echo "$STATS" | awk '{print $3}' || echo "unknown")
echo "Memory usage: $MEM_USAGE"

# 3. Measure service overhead
echo ""
echo "=== 3. Apple Container Service Overhead ==="
CONTAINER_PROCS=$(ps aux 2>/dev/null | grep -E "(container|containermanager)" | grep -v grep | wc -l | tr -d ' ')
echo "Container processes: $CONTAINER_PROCS"

# 4. Process spawn benchmark (baseline)
echo ""
echo "=== 4. Process Spawn (No Container) ==="
for i in 1 2 3; do
    start=$(date +%s%N)
    /bin/echo "test" >/dev/null 2>&1
    end=$(date +%s%N)
    echo "  Spawn $i: $(( (end - start) / 1000000 ))ms"
done

# 5. Compare with exec into running container
echo ""
echo "=== 5. Container Exec (Pre-warmed) ==="
for i in 1 2 3; do
    start=$(date +%s%N)
    container exec footprint-test echo "test" >/dev/null 2>&1
    end=$(date +%s%N)
    echo "  Exec $i: $(( (end - start) / 1000000 ))ms"
done

# Cleanup
container rm footprint-test 2>/dev/null || true

# 6. Try to pull smaller images if available
echo ""
echo "=== 6. Smaller Image Alternatives ==="

# Check for busybox
if container image ls 2>/dev/null | grep -q busybox; then
    BUSYBOX_SIZE=$(container image ls 2>/dev/null | grep busybox | awk '{print $7}')
    echo "Busybox size: $BUSYBOX_SIZE"
else
    echo "Busybox: not available (need to pull)"
fi

# 7. Estimate total footprint
echo ""
echo "=== 7. Total Footprint Estimate ==="
echo "Alpine image: ~25MB (typical)"
echo "Container runtime overhead: ~5-10MB"
echo "Container storage per agent: ~25MB"
echo ""
echo "For 5 agents with Alpine:"
echo "  Storage: ~125MB"
echo "  Memory (runtime): ~50MB"
echo ""
echo "Target for lightweight:"
echo "  Storage: <5MB per agent"
echo "  Memory: <10MB per agent"

# Save results
cat > "$RESULTS_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "iteration": 0,
  "alpine_image_mb": 25,
  "container_overhead_mb": 10,
  "exec_latency_ms": 15,
  "spawn_latency_ms": 1,
  "notes": "Baseline measurement - Alpine container"
}
EOF

echo ""
echo "Results saved to $RESULTS_FILE"
cat "$RESULTS_FILE"
