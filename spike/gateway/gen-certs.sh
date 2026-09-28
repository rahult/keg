#!/bin/bash
# Generates the spike PKI under pki/: local root CA + wildcard leaf for *.keg.
# Spike-only throwaway keys — never ship, never commit.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p pki

cat > pki/ca.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = Keg Spike Local CA
O = Keg Spike (throwaway)
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

cat > pki/leaf.ext <<'EOF'
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:keg, DNS:*.keg, IP:127.0.0.1
EOF

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1825 \
  -keyout pki/ca.key -out pki/ca.pem -config pki/ca.cnf

openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout pki/leaf.key -out pki/leaf.csr -subj "/CN=memos.keg/O=Keg Spike"

openssl x509 -req -sha256 -days 825 \
  -in pki/leaf.csr -CA pki/ca.pem -CAkey pki/ca.key -CAcreateserial \
  -out pki/leaf.pem -extfile pki/leaf.ext

cat pki/leaf.pem pki/ca.pem > pki/leaf-fullchain.pem

echo "--- leaf summary"
openssl x509 -in pki/leaf.pem -noout -subject -ext subjectAltName
echo "--- chain verify"
openssl verify -CAfile pki/ca.pem pki/leaf.pem
