#!/bin/sh
set -eu
task_source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_build_dir="$task_source_dir/../../target/macos-touch"
task_app="$task_build_dir/GestureProbe.app"
mkdir -p "$task_app/Contents/MacOS"
xcrun clang++ -std=c++17 -fobjc-arc -framework AppKit -framework ApplicationServices \
    "$task_source_dir/native_gestures_test.mm" -o "$task_build_dir/native-gestures-test"
"$task_build_dir/native-gestures-test"
xcrun clang -fobjc-arc -Wno-deprecated-declarations -framework Cocoa -framework ApplicationServices \
    "$task_source_dir/GestureProbe.m" "$task_source_dir/../../src/platform/macos/native_gestures.mm" \
    -lc++ -o "$task_app/Contents/MacOS/GestureProbe"
cat > "$task_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>GestureProbe</string>
    <key>CFBundleIdentifier</key><string>local.rustdesk.touchprobe</string>
    <key>CFBundleName</key><string>RustDesk Touch Probe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>NSPrincipalClass</key><string>TouchApp</string>
</dict></plist>
PLIST
codesign --force --sign "${TOUCH_CODESIGN_IDENTITY:--}" "$task_app"
printf 'Open %s and enable Accessibility to run the interactive test.\n' "$task_app"
