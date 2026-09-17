#!/bin/bash
# Docker CLI contract test — runs the REAL docker CLI against Keg's Docker
# API socket and asserts the behaviors daily-driver usage depends on.
#
# Usage: ./Scripts/docker-cli-contract-test.sh [socket-path]
# Requires: docker CLI, Apple container runtime installed, Keg running
# (make open) with the Docker API started.
set -uo pipefail

SOCKET="${1:-$HOME/.keg/docker.sock}"
export DOCKER_HOST="unix://$SOCKET"

PASS=0
FAIL=0
CONTAINERS=()

log()  { printf '%s\n' "$*"; }
pass() { PASS=$((PASS+1)); log "  ✅ $*"; }
fail() { FAIL=$((FAIL+1)); log "  ❌ $*"; }

section() { log ""; log "== $* =="; }

cleanup() {
    for c in "${CONTAINERS[@]:-}"; do
        docker rm -f "$c" >/dev/null 2>&1
    done
}
trap cleanup EXIT

require() {
    if ! command -v docker >/dev/null 2>&1; then
        log "docker CLI not found"; exit 2
    fi
    if [ ! -S "$SOCKET" ]; then
        log "socket not found at $SOCKET — start Keg (make open) first"; exit 2
    fi
}

section "system"
require
if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    pass "docker version"
else
    fail "docker version"
fi

if docker ps >/dev/null 2>&1; then
    pass "docker ps"
else
    fail "docker ps"
fi

section "pull + run + wait exit code"
docker pull alpine:latest >/dev/null 2>&1 || true

RUN_NAME="keg-contract-$RANDOM"
CONTAINERS+=("$RUN_NAME")
OUT=$(docker run --name "$RUN_NAME" alpine:latest sh -c 'echo hello-keg; exit 7' 2>&1)
RUN_EXIT=$?
if [ "$RUN_EXIT" = "7" ]; then
    pass "docker run propagates exit code 7"
else
    fail "docker run exit code: expected 7, got $RUN_EXIT (output: $OUT)"
fi
if echo "$OUT" | grep -q "hello-keg"; then
    pass "docker run streams stdout"
else
    fail "docker run output missing 'hello-keg': $OUT"
fi

section "exec"
EXEC_NAME="keg-exec-$RANDOM"
docker run -d --name "$EXEC_NAME" alpine:latest sleep 300 >/dev/null 2>&1
CONTAINERS+=("$EXEC_NAME")

EXEC_OUT=$(docker exec "$EXEC_NAME" echo exec-works 2>&1)
if echo "$EXEC_OUT" | grep -q "exec-works"; then
    pass "docker exec (hijack, non-tty)"
else
    fail "docker exec: $EXEC_OUT"
fi

docker exec "$EXEC_NAME" sh -c 'exit 5' >/dev/null 2>&1
EXEC_EXIT=$?
if [ "$EXEC_EXIT" = "5" ]; then
    pass "docker exec propagates exit code"
else
    fail "docker exec exit: expected 5, got $EXEC_EXIT"
fi

STDIN_OUT=$(echo "stdin-data" | docker exec -i "$EXEC_NAME" cat 2>&1)
if echo "$STDIN_OUT" | grep -q "stdin-data"; then
    pass "docker exec -i forwards stdin"
else
    fail "docker exec -i: $STDIN_OUT"
fi

TTY_OUT=$(docker exec "$EXEC_NAME" sh -c 'echo tty-ok' 2>&1)
if echo "$TTY_OUT" | grep -q "tty-ok"; then
    pass "docker exec output (no spurious framing)"
else
    fail "docker exec output garbled: $TTY_OUT"
fi

section "logs"
LOGS=$(docker logs "$RUN_NAME" 2>&1)
if echo "$LOGS" | grep -q "hello-keg"; then
    pass "docker logs"
else
    fail "docker logs: $LOGS"
fi

section "stats"
STATS=$(docker stats --no-stream --format '{{.Name}}' "$EXEC_NAME" 2>&1)
if echo "$STATS" | grep -q "$EXEC_NAME"; then
    pass "docker stats --no-stream"
else
    fail "docker stats: $STATS"
fi

section "events"
EVENTS_FILE=$(mktemp)
UNTIL=$(( $(date +%s) + 6 ))
(sleep 1; docker restart "$EXEC_NAME" >/dev/null 2>&1) &
timeout 15 docker events --since 1s --until "$UNTIL" >"$EVENTS_FILE" 2>&1
if grep -qE '"(start|restart|die)"|container (start|restart|die)' "$EVENTS_FILE" 2>/dev/null; then
    pass "docker events streams lifecycle events"
else
    fail "docker events produced nothing: $(head -3 "$EVENTS_FILE")"
fi
rm -f "$EVENTS_FILE"

section "volumes + df"
VOL="keg-contract-vol-$RANDOM"
if docker volume create "$VOL" >/dev/null 2>&1 && docker volume ls --format '{{.Name}}' | grep -q "$VOL"; then
    pass "docker volume create + ls"
else
    fail "docker volume create/ls"
fi
docker volume rm "$VOL" >/dev/null 2>&1 && pass "docker volume rm" || fail "docker volume rm"

if docker system df >/dev/null 2>&1; then
    pass "docker system df"
else
    fail "docker system df"
fi

section "build"
# docker 29 dropped the classic builder on the CLI side (BuildKit only),
# so exercise the classic POST /build contract — which API clients like
# Testcontainers still use — directly over the socket.
BUILD_DIR=$(mktemp -d)
cat >"$BUILD_DIR/Dockerfile" <<'EOF'
FROM alpine:latest
RUN echo marker-ok > /keg-contract-marker
CMD ["echo", "built"]
EOF
(cd "$BUILD_DIR" && tar -cf context.tar Dockerfile)
BUILD_OUT=$(curl -s -m 180 -X POST --unix-socket "$SOCKET" \
    "http://localhost/v1.45/build?dockerfile=Dockerfile&t=keg-contract-test:latest" \
    --data-binary @"$BUILD_DIR/context.tar")
BUILD_MARKER_OK=$(echo "$BUILD_OUT" | grep -c "marker-ok\|writing image\|naming\|exporting")
rm -rf "$BUILD_DIR"
if [ "$BUILD_MARKER_OK" -gt 0 ]; then
    pass "POST /build (tar context + streamed output)"
else
    fail "POST /build: $(echo "$BUILD_OUT" | tail -3)"
fi

section "results"
log ""
if [ "$FAIL" = "0" ]; then
    log "✅ All $PASS checks passed"
    exit 0
else
    log "❌ $FAIL failed, $PASS passed"
    exit 1
fi
