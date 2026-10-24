#!/usr/bin/env bash
set -euo pipefail
: "${MACOS_P12_BASE64:?Missing macOS signing certificate}"
: "${MACOS_P12_PASSWORD:?Missing P12 password}"
: "${MACOS_CODESIGN_IDENTITY:?Missing signing identity (plain name or SHA-1)}"
mode=${MACOS_SIGNING_MODE:-developer-id}
case "$mode" in local|developer-id) ;; *) echo 'Invalid MACOS_SIGNING_MODE' >&2; exit 1;; esac
keychain="$RUNNER_TEMP/rustdesk-signing.keychain-db"
password=$(openssl rand -hex 32)
echo "::add-mask::$password"
p12=$(mktemp "$RUNNER_TEMP/rustdesk-signing.XXXXXX")
probe=$(mktemp "$RUNNER_TEMP/rustdesk-codesign-probe.XXXXXX")
trap 'rm -f "$p12" "$probe"' EXIT
chmod 600 "$p12"
printf '%s' "$MACOS_P12_BASE64" | base64 --decode > "$p12"
security create-keychain -p "$password" "$keychain"
printf 'MACOS_SIGNING_KEYCHAIN=%s\n' "$keychain" >> "$GITHUB_ENV"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$p12" -f pkcs12 -k "$keychain" -P "$MACOS_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null

if [ "$mode" = local ]; then
  certificate="$RUNNER_TEMP/rustdesk-signing-public.pem"
  openssl pkcs12 -in "$p12" -clcerts -nokeys -passin env:MACOS_P12_PASSWORD -out "$certificate"
  printf 'MACOS_SIGNING_CERTIFICATE=%s\n' "$certificate" >> "$GITHUB_ENV"
  # The hosted runner has no trust settings for our self-signed certificate.
  sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "$keychain" "$certificate"
fi

# Fail before downloading SDKs/building the app if the identity cannot sign.
cp /usr/bin/true "$probe"
if ! codesign --force --timestamp=none --keychain "$keychain" --sign "$MACOS_CODESIGN_IDENTITY" "$probe"; then
  security find-identity -v -p codesigning "$keychain"
  echo '::error::The imported macOS identity cannot sign. Check its name/SHA-1, private key and code-signing trust.' >&2
  exit 1
fi
codesign --verify --strict "$probe"
