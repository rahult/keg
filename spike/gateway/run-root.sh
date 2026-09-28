#!/bin/bash
# Root-gated steps of the keg gateway spike. Run:
#   spike/gateway/run-root.sh
# 1) route *.keg DNS to the spike responder on 127.0.0.1:15353 (/etc/resolver/keg)
# 2) forward 127.0.0.1:443 -> 127.0.0.1:8443 (stands in for the future daemon)
# Both are trivially reversible: delete /etc/resolver/keg, Ctrl-C the splice.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f /etc/resolver/keg ] || ! grep -q 15353 /etc/resolver/keg; then
  sudo mkdir -p /etc/resolver
  sudo tee /etc/resolver/keg >/dev/null <<'EOF'
nameserver 127.0.0.1
port 15353
EOF
  echo "wrote /etc/resolver/keg"
else
  echo "/etc/resolver/keg already present"
fi
sudo killall -HUP mDNSResponder 2>/dev/null || true

if lsof -nP -iTCP:443 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
  echo "port 443 already bound — leaving it alone"
else
  echo "forwarding 127.0.0.1:443 -> 127.0.0.1:8443 (Ctrl-C to stop)"
  sudo python3 splice.py
fi
