# Gateway spike — `https://memos.keg` with no ports and a valid padlock

> **SUPERSEDED 2026-09-24**: the gateway shipped in-app at `Sources/Keg/Gateway/`
> (Settings → Gateway) with the simplified scope: HTTP hostnames first
> (`http://memos.keg:8080`), HTTPS as an opt-in. This directory stays as the
> design record — especially the Results below (wildcard rejection, trust
> dialog, resolver behavior).

Feasibility spike for the Keg gateway idea: friendly hostnames for Apps-store
installs, all sharing one port, with real HTTPS. Everything here is host-side;
none of it depends on Apple's container runtime.

## The chain

```
Safari ── https://memos.keg ──> DNS: mDNSResponder ──> /etc/resolver/keg
                │                                        │
                │                                        ▼
                │                             dnsspike (UDP 127.0.0.1:15353)
                │                             answers *.keg → 127.0.0.1
                ▼
     127.0.0.1:443 (root-only) ── splice ──> 127.0.0.1:8443 tlsserver.py
                                             wildcard *.keg leaf, CA trusted
                                             (production: in-app proxy, Host routing)
```

## Files

| file | role |
|------|------|
| `gen-certs.sh` | throwaway local CA + wildcard leaf (`DNS:keg, DNS:*.keg, IP:127.0.0.1`, 825 days) |
| `dnsspike.swift` | ~100-line UDP DNS responder, raw sockets (proves in-process is trivial; port 15353 — see note) |
| `tlsserver.py` | TLS endpoint on 8443 standing in for the future in-app proxy |
| `splice.py` | dumb TCP splice 443→8443 (stand-in for the future privileged helper) |
| `trustcheck.swift` | URLSession fetch — same CFNetwork trust path as Safari |
| `run-root.sh` | the two root-gated steps: write `/etc/resolver/keg`, run the splice |
| `verify-chain.sh` | end-to-end verification once trust + resolver are in place |

## How to run (after a reboot of the machine or of opinions)

```bash
cd spike/gateway
./gen-certs.sh                      # regenerate PKI (throwaway)
swiftc -O -o dnsspike dnsspike.swift && ./dnsspike &   # DNS responder
python3 tlsserver.py &              # TLS endpoint on 8443
security add-trusted-cert -r trustRoot -p ssl pki/ca.pem   # GUI prompt → Allow
./run-root.sh                       # sudo: resolver file + 443 splice
./verify-chain.sh                   # should be all green
open https://memos.keg              # eyeball the padlock
```

## Results (2026-09-24, macOS 27.0) — ALL LINKS PROVEN

- ✅ **DNS responder** (`dnsspike`): `*.keg`/apex A → 127.0.0.1; AAAA + TYPE65
  (HTTPS-record, which browsers query) → empty NOERROR so resolvers fall back
  to A; off-zone → NXDOMAIN. Hand-rolled in ~100 lines of Swift, no deps.
- ✅ **PKI**: OpenSSL-generated CA + leaf; `openssl verify` clean.
- ✅ **CFNetwork trust**: fails closed with `-1202` before the dialog; after the
  user approves the `security add-trusted-cert` GUI prompt, URLSession gets
  HTTP 200 with zero warnings. The prompt is mandatory (no silent path) — the
  production Enable-Gateway flow must expect it.
- ✅ **`/etc/resolver/keg`**: mDNSResponder picks it up with no restart;
  `dscacheutil` resolves `memos.keg` → 127.0.0.1 system-wide within seconds.
- ✅ **443 splice**: dumb TCP forwarder 443→8443 carried the full chain —
  `https://memos.keg` and `https://gitea.keg` → HTTP 200 in URLSession
  (Safari's path), curl, Safari and Chrome, valid padlock.
- 📌 **WILDCARD REJECTED**: macOS Security.framework AND LibreSSL curl refuse
  `DNS:*.keg` wildcards with hostname mismatch (`errSSLHostNameMismatch`,
  -9843 → NSURLError -1202) even when the CA is fully trusted — while explicit
  SAN entries (`DNS:memos.keg`) on the same CA pass everywhere. Likely the
  wildcard-over-single-label-parent (TLD-shaped) rule. **Production
  consequence: the local CA must issue a per-app leaf at install time (mkcert
  model), not one wildcard leaf.** Safer anyway — no single key unlocks every
  app hostname at once.
- 📌 **Finding**: `container-apiserver` 1.4.1 already listens on UDP
  127.0.0.1:1053 **and 2053** (`LocalhostDNSHandler`/`ContainerDNSHandler`
  symbols, `--dns/--dns-domain/--dns-search` flags in the CLI). The runtime
  grew DNS machinery after 1.3.1 — the "no inter-container DNS" claim in
  AGENTS.md deserves a fresh verification pass, and the production gateway
  must not collide with 1053/2053 (spike used 15353).

`tlsserver.py` takes an optional cert-chain argument
(`python3 tlsserver.py pki/leaf2-fullchain.pem`); leaf2 = explicit SANs
(`keg`, `memos.keg`, `gitea.keg`, `uptime.keg`, IP) — that's the cert that
validates. `leaf-fullchain.pem` (wildcard) is kept for the A/B record.

## Undo everything

```bash
sudo rm /etc/resolver/keg                      # DNS routing off
security remove-trusted-cert pki/ca.pem        # drop trust setting
security delete-certificate -c "Keg Spike Local CA"   # drop cert from login keychain
# Ctrl-C the splice / killall dnsspike / killall python3   (or just reboot)
```

## Production notes carried out of the spike

- The only-root parts are: one `/etc/resolver/keg` write (never changes) and
  binding :443. A ~150-line Swift launchd daemon (SMAppService) doing the
  resolver write + splice covers both; all TLS/routing stays in-app, unprivileged.
- Local CA key must live in the login keychain as a SecKey (spike keeps it on
  disk under `pki/` — throwaway, never commit, never ship).
- Scope trust settings to `-p ssl` so the CA can never sign code/mail trust.
- `dig` on macOS bypasses mDNSResponder — test system resolution with
  `dscacheutil`/`curl`, not `dig`. Old system `dig` (9.10.6) also doesn't know
  the HTTPS-record mnemonic; use `TYPE65`.
- Firefox needs a manual CA import (own trust store); Safari/Chrome/Edge/curl
  (with `--cacert` or trust settings) all covered.
