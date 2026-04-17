#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_DIR="${MEADOW_QA_REPORT_DIR:-$ROOT_DIR/outputs/qa/latest}"
mkdir -p "$REPORT_DIR"

cd "$ROOT_DIR"

run_step() {
  local name="$1"
  shift

  echo
  echo "==> $name"
  echo "Command: $*"

  local log_file="$REPORT_DIR/${name// /-}.log"
  if "$@" 2>&1 | tee "$log_file"; then
    echo "✅ $name"
  else
    echo "❌ $name"
    echo "Log: $log_file"
    exit 1
  fi
}

cat > "$REPORT_DIR/summary.txt" <<EOF
Meadow QA run
Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Root: $ROOT_DIR
Report dir: $REPORT_DIR
MEADOW_RUN_MANAGED_AGENTS=${MEADOW_RUN_MANAGED_AGENTS:-0}
MEADOW_RUN_CONTAINER_E2E=${MEADOW_RUN_CONTAINER_E2E:-0}
MEADOW_QA_BUILD_APP=${MEADOW_QA_BUILD_APP:-0}
EOF

run_step "swift-build" swift build
run_step "swift-test" swift test

if [[ "${MEADOW_QA_BUILD_APP:-0}" == "1" ]]; then
  run_step "make-app" make app
fi

if [[ "${MEADOW_RUN_MANAGED_AGENTS:-0}" == "1" ]]; then
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "❌ MEADOW_RUN_MANAGED_AGENTS=1 but ANTHROPIC_API_KEY missing"
    exit 1
  fi
  run_step "managed-agents-integration" swift test --filter ManagedAgentsIntegrationTests
else
  echo "ℹ️ Skipping Managed Agents integration tests"
fi

if [[ "${MEADOW_RUN_CONTAINER_E2E:-0}" == "1" ]]; then
  run_step "container-e2e" swift test --filter MeadowE2ETests
else
  echo "ℹ️ Skipping container E2E tests"
fi

echo
cat <<EOF
QA complete.
Reports: $REPORT_DIR
Base automation: swift build + swift test
Opt-in suites:
  MEADOW_RUN_MANAGED_AGENTS=1 ANTHROPIC_API_KEY=... ./Scripts/qa.sh
  MEADOW_RUN_CONTAINER_E2E=1 ./Scripts/qa.sh
  MEADOW_QA_BUILD_APP=1 ./Scripts/qa.sh
EOF
