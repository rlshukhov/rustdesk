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
trap 'rm -f "$p12"' EXIT
chmod 600 "$p12"
printf '%s' "$MACOS_P12_BASE64" | base64 --decode > "$p12"
security create-keychain -p "$password" "$keychain"
printf 'MACOS_SIGNING_KEYCHAIN=%s\n' "$keychain" >> "$GITHUB_ENV"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$p12" -f pkcs12 -k "$keychain" -P "$MACOS_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null

