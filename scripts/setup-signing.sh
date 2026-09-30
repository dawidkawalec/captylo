#!/bin/bash
# One-time setup of a stable local code signing identity ("Captylo Dev").
#
# Ad-hoc signatures change with every build, so macOS drops the Microphone and
# Accessibility grants after each rebuild. A self-signed certificate gives the app
# a designated requirement based on the certificate instead of the binary hash,
# so the grants survive rebuilds. Local development only: distribution needs a
# Developer ID certificate and notarization.
#
# The identity lives in its own keychain (captylo-dev.keychain-db) that is added
# to the user keychain search list. Its password is kept outside the repo.
set -euo pipefail

NAME="Captylo Dev"
KC="$HOME/Library/Keychains/captylo-dev.keychain-db"
PWF="$HOME/.claude/secrets/captylo-dev-keychain.key"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists in $KC"
  exit 0
fi

mkdir -p "$(dirname "$PWF")"
if [ ! -f "$PWF" ]; then
  (umask 077; openssl rand -hex 24 > "$PWF")
fi
PW="$(cat "$PWF")"

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/id.p12" -passout pass:"$PW" 2>/dev/null

[ -f "$KC" ] || security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null

EXISTING=$(security list-keychains -d user | tr -d '"' | xargs)
if ! echo "$EXISTING" | grep -q captylo-dev; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s $EXISTING "$KC"
fi

security find-identity -p codesigning "$KC"
echo "Done. Run 'make release' and grant Microphone + Accessibility once more."
