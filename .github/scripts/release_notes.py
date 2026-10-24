"""Render user-facing release notes from the versioned repository document."""

import argparse
from pathlib import Path
import re

from android_release import validate_version


def render(root, version, code, sha):
    validate_version(version, code)
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Expected a full source commit SHA")
    path = root / "docs" / "release-notes" / f"{version}.md"
    notes = path.read_text().strip()
    if not notes:
        raise ValueError(f"Release notes are empty: {path}")
    return (
        f"{notes}\n\n---\nВерсия: {version} · Android versionCode: {code} · "
        f"[Исходный код ({sha[:7]})](https://github.com/rlshukhov/rustdesk/commit/{sha})\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--code", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--root", type=Path, default=Path("."))
    args = parser.parse_args()
    try:
        print(render(args.root, args.version, args.code, args.sha), end="")
    except (ValueError, OSError) as error:
        parser.exit(1, f"Release notes validation failed: {error}\n")


if __name__ == "__main__":
    main()
