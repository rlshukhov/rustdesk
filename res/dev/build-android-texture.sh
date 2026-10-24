#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
decoder_mode="${1:-default}"
flutter_args=(build apk --release --no-pub --target-platform android-arm64)
case "$decoder_mode" in
    default) ;;
    true|false) flutter_args+=("--dart-define=ANDROID_TEXTURE_DECODER=$decoder_mode") ;;
    *) echo "Usage: build-android-texture.sh [default|true|false]"; exit 2 ;;
esac
: "${ANDROID_NDK_HOME:?Run through res/dev/android-env.sh}"
cd "$repo_root"
flutter config --jdk-dir "$JAVA_HOME" --android-sdk "$ANDROID_HOME"

cargo ndk --platform 21 --target aarch64-linux-android rustc --lib --locked --release \
    --features flutter,hwcodec --jobs 4 -- -C link-arg=-Wl,--no-undefined
native_dir="$repo_root/flutter/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$native_dir"
cp target/aarch64-linux-android/release/liblibrustdesk.so "$native_dir/librustdesk.so"
cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$native_dir/"

cd flutter
ORG_GRADLE_PROJECT_rustdeskTextureDev=true flutter "${flutter_args[@]}"
mkdir -p ../target/android-texture
cp build/app/outputs/flutter-apk/app-release.apk \
    "../target/android-texture/rustdesk-texture-$decoder_mode-arm64.apk"
