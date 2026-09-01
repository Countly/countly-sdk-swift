#!/usr/bin/env python3
"""Normalises a platform's code coverage into one small JSON file.

Two toolchains produce coverage for this package and they do not agree on a format:

* the macOS job runs `swift test --enable-code-coverage`, whose output is read with
  `xcrun llvm-cov export -summary-only`;
* the simulator jobs run `xcodebuild -enableCodeCoverage YES`, whose result bundle is read
  with `xcrun xccov view --report --json`.

They also do not measure the same code, and the gap is not rounding. `WebViewManager`,
`OverlayWindow` and the notification service are compiled out on macOS, so the iOS number
covers thousands more lines than the macOS one. Reporting a single percentage without saying
which platform produced it is therefore actively misleading, which is why every record this
script writes carries its platform and its line count.

Usage:
    coverage_summary.py --platform macOS --llvm-cov-export export.json --output cov-macos.json
    coverage_summary.py --platform iOS   --xccov xccov.json           --output cov-ios.json
"""

import argparse
import json
import re
import sys
from pathlib import Path

# Test sources and build intermediates are not product code. This mirrors the
# `-ignore-filename-regex='(Tests|\.build)/'` the macOS llvm-cov invocation already uses, and
# applies the same rule to the xccov side so the two numbers are comparable.
EXCLUDED_PATH = re.compile(r"(/Tests/|/\.build/|/DerivedData/|\.xctest/)")
# xccov reports the test bundle as a target of its own.
EXCLUDED_TARGET = re.compile(r"(Tests?\.xctest|PackageTests)", re.IGNORECASE)


def percent(covered, total):
    return round(100.0 * covered / total, 2) if total else 0.0


def from_llvm_cov(payload):
    """`llvm-cov export -summary-only -format=text` output -> (files, totals)."""
    files = []
    for block in payload.get("data") or []:
        for entry in block.get("files") or []:
            path = entry.get("filename", "")
            if EXCLUDED_PATH.search(path):
                continue
            lines = (entry.get("summary") or {}).get("lines") or {}
            count = int(lines.get("count") or 0)
            if not count:
                continue
            files.append({
                "path": path,
                "lines": count,
                "covered": int(lines.get("covered") or 0),
            })
    return files


def from_xccov(payload):
    """`xccov view --report --json` output -> files."""
    files = []
    for target in payload.get("targets") or []:
        if EXCLUDED_TARGET.search(target.get("name") or ""):
            continue
        for entry in target.get("files") or []:
            path = entry.get("path") or entry.get("name") or ""
            if EXCLUDED_PATH.search(path):
                continue
            count = int(entry.get("executableLines") or 0)
            if not count:
                continue
            files.append({
                "path": path,
                "lines": count,
                "covered": int(entry.get("coveredLines") or 0),
            })
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--llvm-cov-export", help="llvm-cov export -summary-only JSON")
    source.add_argument("--xccov", help="xccov view --report --json JSON")
    parser.add_argument("--platform", required=True)
    parser.add_argument("--output", required=True)
    arguments = parser.parse_args()

    path = Path(arguments.llvm_cov_export or arguments.xccov)
    if not path.is_file():
        sys.exit("::error::%s does not exist, so there is no coverage to summarise" % path)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        sys.exit("::error::%s is not valid JSON: %s" % (path, error))

    files = from_llvm_cov(payload) if arguments.llvm_cov_export else from_xccov(payload)
    if not files:
        # An empty coverage record would be rendered as 0%, which reads as a catastrophic
        # regression rather than as the tooling problem it actually is.
        sys.exit(
            "::error::no covered source files were found for %s. The coverage input was "
            "present but contained nothing after filtering out tests and build products."
            % arguments.platform
        )

    # Paths are absolute and runner specific; the repository relative tail is what a reviewer
    # can act on.
    for entry in files:
        parts = entry["path"].split("/Sources/", 1)
        entry["path"] = "Sources/" + parts[1] if len(parts) == 2 else entry["path"].split("/")[-1]
        entry["percent"] = percent(entry["covered"], entry["lines"])

    total_lines = sum(entry["lines"] for entry in files)
    total_covered = sum(entry["covered"] for entry in files)

    record = {
        "platform": arguments.platform,
        "lines": total_lines,
        "covered": total_covered,
        "percent": percent(total_covered, total_lines),
        # Worst covered first, then largest, so the table leads with what is worth fixing.
        "files": sorted(files, key=lambda entry: (entry["percent"], -entry["lines"])),
    }

    output = Path(arguments.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(record, indent=2), encoding="utf-8")

    print(
        "%s coverage: %.2f%% of %d lines (%d covered) across %d files -> %s"
        % (record["platform"], record["percent"], record["lines"],
           record["covered"], len(files), output)
    )


if __name__ == "__main__":
    main()
