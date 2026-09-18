#!/bin/bash
# Ecosystem certification suite — runs real-world Docker tooling against
# Keg's socket and writes docs/certification.md with the pass matrix.
# Tools that aren't installed are reported as SKIP (never a failure).
# Usage: ./Scripts/certify-ecosystem.sh
set -uo pipefail
export DOCKER_HOST="unix://${DOCKER_HOST_PATH:-$HOME/.keg/docker.sock}"
REPORT="docs/certification.md"
PASS=0; FAIL=0; SKIP=0

have() { command -v "$1" >/dev/null 2>&1; }
record() { # name, status(PASS/FAIL/SKIP), detail
    case "$2" in
        PASS) PASS=$((PASS+1));;
        FAIL) FAIL=$((FAIL+1));;
        SKIP) SKIP=$((SKIP+1));;
    esac
    RESULTS+=("| $1 | $2 | $3 |")
}
RESULTS=()

section_compose() {
    if ! docker compose version >/dev/null 2>&1; then
        record "docker compose" SKIP "compose plugin not installed"
        return
    fi
    local DIR=$(mktemp -d)
    cat >"$DIR/compose.yaml" <<'EOF'
services:
  api:
    image: docker.io/library/nginx:alpine
    ports: ["18080:80"]
    depends_on:
      db: { condition: service_started }
  db:
    image: docker.io/library/busybox:latest
    command: ["sleep", "120"]
EOF
    UP_OK=0
    (cd "$DIR" && timeout 180 docker compose up -d >/tmp/keg-cert-compose.log 2>&1) && UP_OK=1
    SERVED=0
    if [ "$UP_OK" = "1" ]; then
        for _ in $(seq 1 20); do
            if curl -sf -m 3 http://localhost:18080/ >/dev/null 2>&1; then SERVED=1; break; fi
            sleep 1
        done
    fi
    if [ "$SERVED" = "1" ]; then
        record "compose: up + depends_on + published port" PASS "nginx served via host port"
    else
        record "compose: up + depends_on + published port" FAIL "$(tail -1 /tmp/keg-cert-compose.log 2>/dev/null | cut -c1-80)"
    fi
    (cd "$DIR" && docker compose down -v >/dev/null 2>&1); rm -rf "$DIR"
}

section_testcontainers() {
    if have python3 && python3 -c "import testcontainers" 2>/dev/null; then
        if python3 - <<'EOF' >/dev/null 2>&1
from testcontainers.core.container import DockerContainer
with DockerContainer("docker.io/library/alpine:latest").with_command("sleep 2") as c:
    assert c.get_container_host_ip()
print("ok")
EOF
        then record "Testcontainers (Python)" PASS "container lifecycle via socket"
        else record "Testcontainers (Python)" FAIL "see docs/RELEASING or rerun manually"; fi
    else
        record "Testcontainers (Python)" SKIP "pip install testcontainers to enable"
    fi
}

section_cli() {
    if ./Scripts/docker-cli-contract-test.sh >/tmp/keg-cert-contract.log 2>&1; then
        record "docker CLI contract suite" PASS "all checks green"
    else
        record "docker CLI contract suite" FAIL "$(grep -c '❌' /tmp/keg-cert-contract.log) failing checks"
    fi
}

section_compose
section_testcontainers
section_cli

{
    echo "# Ecosystem Certification"
    echo
    echo "Generated $(date -u +%Y-%m-%dT%H:%MZ) against Keg's Docker API socket."
    echo
    echo "| Check | Status | Notes |"
    echo "|---|---|---|"
    printf '%s\n' "${RESULTS[@]}"
    echo
    echo "**$PASS passed · $FAIL failed · $SKIP skipped** (skips = tool not installed)"
} > "$REPORT"

cat "$REPORT"
[ "$FAIL" = "0" ]
