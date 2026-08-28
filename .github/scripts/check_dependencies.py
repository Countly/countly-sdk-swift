#!/usr/bin/env python3
"""Guards the SDK's "no third party dependencies" promise, and scans anything that slips in.

An analytics SDK is linked into other people's applications. Every dependency it declares is
one those applications inherit and have to audit, so the Swift SDK deliberately has none. This
script is what makes that a build failure rather than a convention.

If a dependency is ever added on purpose, this does not just refuse: it queries the OSV
database for known vulnerabilities in the resolved versions and fails only on a finding at or
above the configured severity, writing a report the workflow uploads.

Usage: check_dependencies.py <swift package show-dependencies --format json output>
"""

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OSV_ENDPOINT = "https://api.osv.dev/v1/query"
REPORT = ROOT / "osv-report.md"

# Ordered least to most severe, so a threshold comparison is an index comparison.
SEVERITIES = ["low", "moderate", "high", "critical"]
# OSV writes CVSS qualitative ratings; "medium" and "moderate" are the same rating.
SEVERITY_ALIASES = {"medium": "moderate", "unknown": "low", "none": "low"}


def flatten(node, seen):
    """Every distinct package in the dependency tree, excluding the root package itself."""
    for child in node.get("dependencies", []):
        identity = (child.get("identity") or child.get("name"), child.get("version"))
        if identity in seen:
            continue
        seen[identity] = child.get("url", "")
        flatten(child, seen)
    return seen


def query_osv(url, version):
    """Known vulnerabilities for one resolved package, or None when OSV cannot be reached."""
    payload = json.dumps({
        "version": version,
        "package": {"name": url.removesuffix(".git").removeprefix("https://"), "ecosystem": "SwiftURL"},
    }).encode("utf-8")
    request = urllib.request.Request(
        OSV_ENDPOINT, data=payload, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response).get("vulns", []) or []
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        # Reported rather than swallowed: a scan that could not run must not read as a pass.
        print("::warning::OSV query failed for %s %s: %s" % (url, version, error))
        return None


def worst_severity(vulnerability):
    ratings = []
    for entry in vulnerability.get("severity", []) or []:
        rating = str(entry.get("score", "")).lower()
        ratings.append(SEVERITY_ALIASES.get(rating, rating))
    for affected in vulnerability.get("affected", []) or []:
        rating = str(affected.get("database_specific", {}).get("severity", "")).lower()
        ratings.append(SEVERITY_ALIASES.get(rating, rating))
    known = [r for r in ratings if r in SEVERITIES]
    if not known:
        return "low"
    return max(known, key=SEVERITIES.index)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: check_dependencies.py <dependencies.json>")

    graph = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    packages = flatten(graph, {})

    if not packages:
        REPORT.write_text(
            "## Dependency scan\n\nThe package declares no third party dependencies.\n",
            encoding="utf-8",
        )
        print("The package declares no third party dependencies.")
        return

    threshold = os.environ.get("SEVERITY_THRESHOLD", "high").lower()
    threshold = SEVERITY_ALIASES.get(threshold, threshold)
    if threshold not in SEVERITIES:
        sys.exit("::error::SEVERITY_THRESHOLD must be one of %s" % ", ".join(SEVERITIES))

    print(
        "::warning::The package now declares %d third party dependenc%s. The Swift SDK is "
        "meant to ship with none, because every one of them is inherited by every integrating "
        "application. Scanning them instead."
        % (len(packages), "y" if len(packages) == 1 else "ies")
    )

    lines = ["## Dependency scan", "", "| Package | Version | Vulnerabilities |", "|---|---|---|"]
    blocking = []
    unreachable = False

    for (name, version), url in sorted(packages.items()):
        vulnerabilities = query_osv(url, version)
        if vulnerabilities is None:
            unreachable = True
            lines.append("| `%s` | %s | not scanned, OSV unreachable |" % (name, version))
            continue

        severe = [v for v in vulnerabilities
                  if SEVERITIES.index(worst_severity(v)) >= SEVERITIES.index(threshold)]
        blocking.extend((name, version, v) for v in severe)

        if not vulnerabilities:
            cell = "none"
        else:
            cell = ", ".join(
                "%s (%s)" % (v.get("id", "?"), worst_severity(v)) for v in vulnerabilities
            )
        lines.append("| `%s` | %s | %s |" % (name, version, cell))

    lines.append("")
    lines.append("Threshold: **%s** and above blocks." % threshold)
    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")

    if blocking:
        for name, version, vulnerability in blocking:
            print("::error::%s %s is affected by %s (%s)"
                  % (name, version, vulnerability.get("id", "?"), worst_severity(vulnerability)))
        sys.exit(1)

    if unreachable:
        sys.exit("::error::at least one package could not be scanned; treating as a failure")


if __name__ == "__main__":
    main()
