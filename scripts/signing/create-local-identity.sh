#!/bin/sh
# Creates a self-signed code signing identity, "GoLens Local Signing", in the login keychain so local
# builds keep the same signature across rebuilds and the Keychain stops asking for access after each
# make build. It is trusted for code signing on this Mac only; it is not a Developer ID and cannot be
# used to notarize. macOS asks for your login password once, to trust the certificate.
# Usage: scripts/signing/create-local-identity.sh
set -eu
name="GoLens Local Signing"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$name\""; then
  echo "\"$name\" already exists and is trusted for code signing."
  exit 0
fi
if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  echo "A certificate named \"$name\" exists but is not trusted for code signing." >&2
  echo "Delete it in Keychain Access (login keychain, My Certificates), then run this script again." >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/golens-signing.XXXXXX")
trap 'rm -rf "$work"' EXIT
cat > "$work/ext.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 3650 -config "$work/ext.cnf" 2>/dev/null
pass=$(uuidgen)
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/identity.p12" -passout "pass:$pass" 2>/dev/null
security import "$work/identity.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Trusting \"$name\" for code signing. macOS will ask for your login password."
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$name\""; then
  echo "Created \"$name\". make build now signs with it."
else
  echo "The certificate was added but is not trusted for code signing; check Keychain Access." >&2
  exit 1
fi
