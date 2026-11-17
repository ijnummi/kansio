#!/bin/bash
# Makes sure the local code-signing identity "Kansio Local Signing" exists and prints its keychain's path.
#
# Why: an ad-hoc signature ("-") makes macOS identify the app by the hash of that exact build (cdhash), so every rebuild
# is a "new app" — Full Disk Access and other privacy grants stop applying after each install. Signed with a stable
# (self-signed) certificate, the app's designated requirement is "this bundle ID + this certificate", which survives
# rebuilds.
#
# The identity lives in its own keychain file (~/Library/Keychains/kansio-signing.keychain-db), not the login
# keychain, and isn't added to the keychain search list. Its private key never leaves this Mac (not in the repo).
# Remove it with: security delete-keychain ~/Library/Keychains/kansio-signing.keychain-db
set -euo pipefail

name="Kansio Local Signing"
keychain="$HOME/Library/Keychains/kansio-signing.keychain-db"
password="kansio-local-signing" # protects only this local signing key; the file is readable only by you

if [[ -f "$keychain" ]]; then
  security unlock-keychain -p "$password" "$keychain" >/dev/null 2>&1 || true
  if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
    echo "$keychain"
    exit 0
  fi
fi

echo "creating the local code-signing identity “${name}” in ${keychain}…" >&2
work="$(mktemp -d "${TMPDIR:-/tmp}/kansio-signing.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cat >"$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
  -passout pass:"$password" -out "$work/identity.p12" 2>/dev/null

[[ -f "$keychain" ]] || security create-keychain -p "$password" "$keychain"
security set-keychain-settings "$keychain" # no auto-lock timeout
security unlock-keychain -p "$password" "$keychain"
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
echo "$keychain"
