#!/usr/bin/env bash

set -euo pipefail

app_path=$1
identity=${MACOS_SIGNING_IDENTITY:-$2}
entitlements=$3

sign_args=(--force --sign "$identity")
case "${MACOS_SIGNING_MODE:-developer-id}" in
  local) sign_args+=(--timestamp=none) ;;
  developer-id)
    sign_args+=(--options runtime)
    if [[ "$identity" != "-" ]]; then sign_args+=(--timestamp); fi
    ;;
  *) echo 'Invalid MACOS_SIGNING_MODE' >&2; exit 1 ;;
esac
if [[ -n "${MACOS_SIGNING_KEYCHAIN:-}" ]]; then
  sign_args+=(--keychain "$MACOS_SIGNING_KEYCHAIN")
fi

frameworks_path="$app_path/Contents/Frameworks"
if [[ -d "$frameworks_path" ]]; then
  while IFS= read -r -d '' code; do
    if file -b "$code" | grep -q 'Mach-O'; then
      codesign "${sign_args[@]}" "$code"
    fi
  done < <(find "$frameworks_path" -type f -print0)

  while IFS= read -r -d '' framework; do
    codesign "${sign_args[@]}" "$framework"
  done < <(find "$frameworks_path" -depth -type d -name '*.framework' -print0)
fi

service_path="$app_path/Contents/MacOS/service"
if [[ -f "$service_path" ]]; then
  codesign "${sign_args[@]}" "$service_path"
fi

codesign "${sign_args[@]}" --generate-entitlement-der \
  --entitlements "$entitlements" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

actual_entitlements=$(codesign -d --entitlements :- "$app_path" 2>/dev/null)
audio_input=$(plutil -extract 'com\.apple\.security\.device\.audio-input' raw - \
  <<<"$actual_entitlements")
if [[ "$audio_input" != "true" ]]; then
  echo "Missing com.apple.security.device.audio-input entitlement" >&2
  exit 1
fi
