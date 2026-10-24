"""Version preparation and signed APK checks for the manual release workflow."""

import argparse
import base64
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile


def validate_version(version, code):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[1-9][0-9]*)?", version):
        raise ValueError("Version must be X.Y.Z or X.Y.Z-N, without a v prefix")
    if not re.fullmatch(r"[1-9][0-9]*", code) or int(code) > 2099996000:
        raise ValueError("Base versionCode must be from 1 to 2099996000 (4000 reserved for Flutter ABI offsets)")


def prepare(root, version, code, check_only=False):
    validate_version(version, code)
    pubspec = root / "flutter/pubspec.yaml"
    old_pubspec = pubspec.read_text()
    current = re.search(r"^version: [^\n+]+\+([0-9]+)$", old_pubspec, re.M)
    if current is None or int(code) <= int(current[1]):
        raise ValueError("versionCode must exceed the build number committed in pubspec.yaml")
    replacements = [
        (root / "Cargo.toml", r'(?m)^(version = ")[^"]+("$)', rf"\g<1>{version}\2"),
        (root / "Cargo.lock", r'(\[\[package\]\]\nname = "rustdesk"\nversion = ")[^"]+("\n)', rf"\g<1>{version}\2"),
        (pubspec, r"(?m)^version: [^\n]+$", f"version: {version}+{code}"),
    ]
    updates = []
    for path, pattern, replacement in replacements:
        text, count = re.subn(pattern, replacement, path.read_text(), count=1)
        if count != 1:
            raise ValueError(f"Cannot locate release version in {path.name}")
        updates.append((path, text))
    if not check_only:
        for path, text in updates:
            path.write_text(text)


def verify_apk(apk, tools, version, code, arch):
    validate_version(version, code)
    apk_code = int(code) + {"armv7": 1000, "aarch64": 2000, "x86_64": 4000, "universal": 0}[arch]
    if apk_code > 2100000000:
        raise ValueError("APK versionCode exceeds the Android limit after Flutter's ABI offset")
    # Export the public certificate without passing the keystore password in argv.
    with tempfile.TemporaryDirectory() as directory:
        keystore = Path(directory) / "release.p12"
        keystore.write_bytes(base64.b64decode(os.environ["ANDROID_SIGNING_KEY"], validate=True))
        keystore.chmod(0o600)
        cert = subprocess.run([
            "keytool", "-exportcert", "-keystore", str(keystore),
            "-alias", os.environ["ANDROID_ALIAS"],
            "-storepass:env", "ANDROID_KEY_STORE_PASSWORD",
        ], capture_output=True)
        if cert.returncode:
            raise ValueError("Cannot export the release certificate from the signing keystore")
        fingerprint = hashlib.sha256(cert.stdout).hexdigest()
    result = subprocess.run([
        str(tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk),
    ], capture_output=True, text=True, check=True).stdout
    signers = re.findall(r"^Signer #[0-9]+ certificate SHA-256 digest: ([0-9a-f]+)$", result, re.M)
    if signers != [fingerprint] or "CN=Android Debug" in result:
        raise ValueError("APK is not signed exclusively by the expected release key")
    metadata = subprocess.run([
        str(tools / "aapt"), "dump", "badging", str(apk),
    ], capture_output=True, text=True, check=True).stdout
    expected = f"package: name='com.carriez.flutter_hbb' versionCode='{apk_code}' versionName='{version}'"
    if not metadata.startswith(expected + " ") and not metadata.startswith(expected + "\n"):
        raise ValueError("APK package, versionName or versionCode differs from the release inputs")
    if re.search(r"^application-debuggable", metadata, re.M):
        raise ValueError("Release APK must not be debuggable")
    print(f"Verified {apk.name}: {version}+{apk_code}, certificate SHA-256 {fingerprint}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "prepare", "verify"])
    parser.add_argument("--version", required=True)
    parser.add_argument("--code", required=True)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--tools", type=Path)
    parser.add_argument("--arch", choices=["armv7", "aarch64", "x86_64", "universal"])
    args = parser.parse_args()
    try:
        if args.command == "verify":
            if args.apk is None or args.tools is None or args.arch is None:
                parser.error("verify requires --apk, --tools and --arch")
            verify_apk(args.apk, args.tools, args.version, args.code, args.arch)
        else:
            prepare(args.root, args.version, args.code, args.command == "check")
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release validation failed: {error}\n")


if __name__ == "__main__":
    main()
