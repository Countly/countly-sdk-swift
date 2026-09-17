#!/usr/bin/env python3
"""Fails the build when the SDK version is not the same in both places that carry it.

The version travels to the server as `sdk_version` on every request, so the value in the
sources is the one that matters. The changelog is a separate hand maintained copy of it, and
a release where they disagree is a release where the dashboard reports a version nobody
shipped.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

SOURCE = ROOT / "Sources/Countly/Internal/CountlyConsts.swift"
CHANGELOG = ROOT / "CHANGELOG.md"


def read(path):
    if not path.is_file():
        sys.exit("::error::%s is missing" % path.relative_to(ROOT))
    return path.read_text(encoding="utf-8")


def find(pattern, text, path, what):
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        sys.exit("::error::could not find the %s in %s" % (what, path.relative_to(ROOT)))
    return match.group(1)


def main():
    # `static let version = "26.8.0"` inside the SDK constants.
    source = find(
        r'static\s+let\s+version\s*=\s*"([^"]+)"',
        read(SOURCE), SOURCE, "SDK version",
    )
    # The newest changelog heading, which is the version being prepared or just released.
    changelog = find(
        r"^##\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$",
        read(CHANGELOG), CHANGELOG, "topmost version heading",
    )

    found = {
        "Sources/Countly/Internal/CountlyConsts.swift": source,
        "CHANGELOG.md": changelog,
    }

    for path, version in found.items():
        print("%-48s %s" % (path, version))

    if len(set(found.values())) != 1:
        sys.exit(
            "::error::the SDK version differs between files: %s"
            % ", ".join("%s=%s" % item for item in found.items())
        )

    print("\nBoth agree on %s." % source)


if __name__ == "__main__":
    main()
