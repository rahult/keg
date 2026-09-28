#!/bin/bash
# Full-chain verification — run AFTER: (1) CA trust approved, (2) run-root.sh done.
set -uo pipefail
cd "$(dirname "$0")"
PASS=0; FAIL=0
check() { # check <label> — evaluates the exit code of the preceding command
  local rc=$?
  if [ "$rc" = "0" ]; then echo "  ✅ $1"; PASS=$((PASS+1)); else echo "  ❌ $1 (rc=$rc)"; FAIL=$((FAIL+1)); fi
}

echo "== 1. system resolution via /etc/resolver (mDNSResponder)"
OUT=$(dscacheutil -q host -a name memos.keg 2>&1)
echo "$OUT" | grep -q "127.0.0.1"
check "dscacheutil memos.keg -> 127.0.0.1"
OUT=$(scutil --dns 2>/dev/null)
echo "$OUT" | grep -q "domain.*keg"
check "scutil --dns shows keg resolver"

echo "== 2. trust via CFNetwork (Safari's path)"
swift trustcheck.swift https://127.0.0.1:8443/ >/dev/null 2>&1
check "URLSession https://127.0.0.1:8443 (trust, by IP SAN)"
swift trustcheck.swift https://memos.keg/ 2>&1 | sed 's/^/  > /'

echo "== 3. curl (own CA bundle, so --cacert)"
CODE=$(curl -s --cacert pki/ca.pem https://memos.keg/ -o /dev/null -w "%{http_code}")
[ "$CODE" = "200" ]
check "curl --cacert https://memos.keg/ -> HTTP $CODE"

echo
echo "PASS=$PASS FAIL=$FAIL"
echo "now eyeball the padlock:  open https://memos.keg  (and: open -a 'Google Chrome' https://memos.keg)"
