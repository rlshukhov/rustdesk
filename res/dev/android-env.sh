#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
tool_root="${RUSTDESK_TOOLCHAINS:-$repo_root/../.toolchains}"
export CARGO_HOME="$tool_root/cargo"
export RUSTUP_HOME="$tool_root/rustup"
export ANDROID_HOME="$tool_root/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export AR="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-ar"
export RANLIB="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-ranlib"
ndk_sysroot="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ndk_sysroot -isystem $ndk_sysroot/usr/include/aarch64-linux-android ${BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android:-}"
export JAVA_HOME="$tool_root/jdk/Contents/Home"
export XDG_CONFIG_HOME="$tool_root/config"
export VCPKG_ROOT="$tool_root/vcpkg"
export PUB_CACHE="$tool_root/pub-cache"
export GRADLE_USER_HOME="$tool_root/gradle"
export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.jvmargs=-Xmx2g -Dorg.gradle.workers.max=2"
export PYTHONPATH="$tool_root/python${PYTHONPATH:+:$PYTHONPATH}"
export PATH="$CARGO_HOME/bin:$tool_root/flutter/bin:$tool_root/local/bin:$tool_root/python/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

if [ "$#" -eq 0 ]; then
    echo "Usage: bash res/dev/android-env.sh <command> [arguments...]"
    exit 2
fi
exec "$@"
