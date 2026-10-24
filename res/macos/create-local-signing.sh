#!/usr/bin/env bash
# Generates once; retain the same identity for every local and CI update.
set -euo pipefail
umask 077
if [[ $# != 1 ]]; then echo "Usage: $0 PRIVATE_DIRECTORY" >&2; exit 1; fi
mkdir -p "$1"
directory=$(cd "$1" && pwd)
if [[ -e "$directory/identity.p12" || -e "$directory/signing.keychain-db" ]]; then
  echo 'Identity already exists. Reuse it; do not regenerate signing certificates for updates.' >&2
  exit 1
fi
chmod 700 "$directory"
openssl rand -hex 32 > "$directory/p12-password.txt"
openssl rand -hex 32 > "$directory/keychain-password.txt"
key=$(mktemp "$directory/key.XXXXXX")
trap 'rm -f "$key"' EXIT
openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
  -subj '/CN=RustDesk Local Signing/' \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature' \
  -addext 'extendedKeyUsage=codeSigning' \
  -keyout "$key" -out "$directory/certificate.pem" 2>/dev/null
openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -name 'RustDesk Local Signing' -inkey "$key" \
  -in "$directory/certificate.pem" -out "$directory/identity.p12" \
  -passout "file:$directory/p12-password.txt"
security create-keychain -p "$(cat "$directory/keychain-password.txt")" "$directory/signing.keychain-db"
security set-keychain-settings -lut 21600 "$directory/signing.keychain-db"
security unlock-keychain -p "$(cat "$directory/keychain-password.txt")" "$directory/signing.keychain-db"
security import "$directory/identity.p12" -k "$directory/signing.keychain-db" \
  -P "$(cat "$directory/p12-password.txt")" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$(cat "$directory/keychain-password.txt")" "$directory/signing.keychain-db" >/dev/null
printf '%s\n' 'RustDesk Local Signing' > "$directory/identity-name.txt"
printf '%s\n' "Created private signing material in: $directory" \
  'Keep identity.p12 and its password backed up separately. No private values were printed.'
