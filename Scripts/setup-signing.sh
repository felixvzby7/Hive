#!/bin/zsh
# Prints the name of a local self-signed code-signing identity, creating it on first use.
# Signing every build with the same identity keeps macOS privacy permissions (folder access
# etc.) across rebuilds; ad-hoc signatures change with every build, so macOS would ask again.
set -e
NAME="Hive Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "$NAME"; exit 0; fi
echo "Lege einmalig ein lokales Signatur-Zertifikat \"$NAME\" im Schlüsselbund an …" >&2
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# macOS' own LibreSSL writes a PKCS#12 file the keychain can import (Homebrew OpenSSL 3 doesn't by default).
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:hive 2>/dev/null
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P hive -T /usr/bin/codesign >/dev/null
echo "$NAME"
