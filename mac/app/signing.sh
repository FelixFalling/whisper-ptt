#!/bin/bash
# Makes the signing identity build.sh uses, once per Mac. Run it on the Mac; build.sh runs
# it by itself when the identity is missing.
#
# Why: signed ad hoc, the app's signature names that exact build, and macOS ties the
# permissions it grants (Accessibility, Input Monitoring, Microphone) to it. Every rebuild
# then looked like a stranger: System Settings still showed Whisper PTT switched on, while
# the app said the permission was missing. Signed with this certificate, the app is known
# by its bundle identifier and the certificate, which stay the same from build to build.
#
# The certificate is self-signed and lives in a keychain of its own,
# ~/Library/Keychains/whisper-ptt-signing.keychain-db, whose random password is in
# ~/.config/whisper-ptt/signing-keychain-password (readable by this user only). It needs
# no Apple developer account, and it signs nothing but this app.
set -euo pipefail
NAME="Whisper PTT Local Signing"
KC="$HOME/Library/Keychains/whisper-ptt-signing.keychain-db"
PASSFILE="$HOME/.config/whisper-ptt/signing-keychain-password"

if [[ -f "$KC" && -s "$PASSFILE" ]]; then
  security unlock-keychain -p "$(cat "$PASSFILE")" "$KC"
  if security find-identity -p codesigning "$KC" | grep -q "\"$NAME\""; then
    echo "The signing identity is already there."
    exit 0
  fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
P12PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" \
  -passout "pass:$P12PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" \
       -passout "pass:$P12PASS"

KCPASS="$(openssl rand -hex 16)"
rm -f "$KC"
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"            # no automatic locking
security unlock-keychain -p "$KCPASS" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC" >/dev/null
mkdir -p "$(dirname "$PASSFILE")"
(umask 077 && printf %s "$KCPASS" > "$PASSFILE")
echo "Made the signing identity \"$NAME\"."
