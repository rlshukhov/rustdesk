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
# Keep the existing search list: codesign chain/key lookups also use this list.
python3 - "$keychain" <<'PY_SEARCH'
import shlex, subprocess, sys
keychains = shlex.split(subprocess.check_output(["security", "list-keychains", "-d", "user"], text=True))
if sys.argv[1] not in keychains:
    subprocess.run(["security", "list-keychains", "-d", "user", "-s", *keychains, sys.argv[1]], check=True)
PY_SEARCH
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

# Resolve the configured identity once, avoiding name-based codesign lookup.
identity=$(security find-identity -v -p codesigning "$keychain" | python3 -c '
import os, re, sys
wanted = os.environ["MACOS_CODESIGN_IDENTITY"].strip()
matches = [sha for sha, name in re.findall(r"\b([0-9A-Fa-f]{40}) \"([^\"]+)\"", sys.stdin.read())
           if wanted.lower() == sha.lower() or wanted == name]
if len(matches) != 1:
    sys.exit("Expected exactly one valid imported signing identity matching MACOS_CODESIGN_IDENTITY")
print(matches[0])
')
printf 'MACOS_SIGNING_IDENTITY=%s\n' "$identity" >> "$GITHUB_ENV"

# Fail before downloading SDKs/building the app if the identity cannot sign.
cp /usr/bin/true "$probe"
if ! codesign --force --timestamp=none --keychain "$keychain" --sign "$identity" "$probe"; then
  security find-identity -v -p codesigning "$keychain"
  echo '::error::The imported macOS identity cannot sign. Check its name/SHA-1, private key and code-signing trust.' >&2
  exit 1
fi
codesign --verify --strict "$probe"
