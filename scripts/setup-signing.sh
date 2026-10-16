#!/bin/zsh
# One-time: creates a self-signed code-signing identity "Vet Local Development"
# in the login keychain. A stable signature lets macOS remember Vet's
# Accessibility permission across rebuilds. May ask for your keychain password.
set -euo pipefail
NAME="Vet Local Development"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "$NAME already exists"; exit 0
fi
TMP=$(mktemp -d)
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout pass:vet
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P vet -T /usr/bin/codesign
rm -rf "$TMP"
security find-identity -p codesigning | grep "$NAME" || { echo "identity not usable for codesigning"; exit 1; }
