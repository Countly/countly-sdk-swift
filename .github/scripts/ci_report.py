#!/usr/bin/env python3
"""Renders the pull request report: one test table across all five platforms, plus coverage.

Inputs are whatever the jobs uploaded -- the JUnit XML written by `xcresult_to_junit.py` on
each of the five platforms, and the normalised coverage records written by
`coverage_summary.py`.

Three things this deliberately does:

* A platform with no JUnit file gets a row saying so rather than being left out. The simulator
  jobs are `continue-on-error`, so a watchOS runtime missing from the runner image silently
  removes a platform from the report; a missing row is indistinguishable from a platform that
  was never meant to run.
* Skipped counts get their own column. The suites skip where a platform lacks the feature
  (watchOS skips ~136, tvOS ~17), so the skip count moving is a real change worth seeing.
* Coverage is reported per platform with its line count, never as a single number. macOS
  compiles out `WebViewManager`, `OverlayWindow` and the notification service, so its
  percentage is taken over roughly 1,500 fewer lines than the iOS one. The two are not
  comparable and the table has to say so.

There is no coverage threshold and no failure on coverage. Coverage is around 82% and is being
worked up deliberately; a gate would block every pull request rather than inform it.

Usage:
    ci_report.py --junit-dir junit --coverage-dir coverage --output ci-report.md
"""

import argparse
import glob
import json
import os
import xml.etree.ElementTree as ET
from pathlib import Path

# The order the table is rendered in. macOS leads because it is the job that gates the pull
# request; the rest are advisory.
PLATFORMS = ["macOS", "iOS", "tvOS", "watchOS", "visionOS"]

MAX_FAILURES_LISTED = 20
MAX_FILES_LISTED = 10


def read_junit(path):
    """Totals and failed test names from one JUnit file.

    The counts are recomputed from the `<testcase>` elements rather than trusted from the
    `<testsuites>` attributes, because `swift test --xunit-output` and this repository's own
    converter do not fill those attributes identically.
    """
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as error:
        return {"error": "could not be parsed (%s)" % error}

    suites = [root] if root.tag == "testsuite" else root.findall(".//testsuite")
    totals = {"tests": 0, "failures": 0, "skipped": 0, "time": 0.0, "failed": []}
    for suite in suites:
        try:
            totals["time"] += float(suite.get("time") or 0)
        except ValueError:
            pass
        for case in suite.findall("testcase"):
            totals["tests"] += 1
            name = "%s.%s" % (case.get("classname") or "", case.get("name") or "")
            if case.find("failure") is not None or case.find("error") is not None:
                totals["failures"] += 1
                totals["failed"].append(name)
            elif case.find("skipped") is not None:
                totals["skipped"] += 1
    return totals


def gather_tests(junit_dir):
    """One record per platform, merging every JUnit file that names that platform."""
    results = {}
    for path in sorted(glob.glob(os.path.join(junit_dir, "**", "*.xml"), recursive=True)):
        # Files are named `<platform>.xml`, and land under `<artifact>/<platform>.xml` once
        # download-artifact has unpacked them.
        stem = Path(path).stem
        platform = next(
            (known for known in PLATFORMS if known.lower() == stem.lower()
             or stem.lower().endswith(known.lower())),
            stem,
        )
        parsed = read_junit(path)
        record = results.setdefault(
            platform, {"tests": 0, "failures": 0, "skipped": 0, "time": 0.0,
                       "failed": [], "error": None}
        )
        if "error" in parsed:
            record["error"] = parsed["error"]
            continue
        for key in ("tests", "failures", "skipped", "time"):
            record[key] += parsed[key]
        record["failed"].extend(parsed["failed"])
    return results


def format_duration(seconds):
    if seconds >= 60:
        return "%dm %02ds" % (int(seconds) // 60, int(seconds) % 60)
    return "%.1fs" % seconds


def test_section(results, simulators_result):
    """The per platform table. `simulators_result` is the GitHub `needs.<job>.result` string
    for the simulator matrix, so a platform with no data can be described as skipped rather
    than as a warning -- the simulator jobs are skipped outright when the macOS job fails."""
    lines = [
        "### Test results",
        "",
        "| Platform | Tests | Passed | Failed | Skipped | Time | |",
        "| --- | ---: | ---: | ---: | ---: | ---: | :--: |",
    ]
    grand = {"tests": 0, "failures": 0, "skipped": 0}
    any_failure = False
    missing = []
    simulators_skipped = simulators_result == "skipped"

    for platform in PLATFORMS:
        record = results.get(platform)
        note = "" if platform == "macOS" else " *"
        if not record or record.get("error") or not record["tests"]:
            if simulators_skipped and platform != "macOS":
                # Not a problem to flag: the matrix never ran, because macOS gates it.
                lines.append(
                    "| %s%s | — | — | — | — | — | :fast_forward: |" % (platform, note)
                )
                continue
            reason = (record or {}).get("error") or "no results were produced"
            missing.append("%s: %s" % (platform, reason))
            lines.append(
                "| %s%s | — | — | — | — | — | :warning: |" % (platform, note)
            )
            continue
        passed = record["tests"] - record["failures"] - record["skipped"]
        icon = ":x:" if record["failures"] else ":white_check_mark:"
        if record["failures"]:
            any_failure = True
        lines.append(
            "| %s%s | %d | %d | %d | %d | %s | %s |"
            % (platform, note, record["tests"], passed, record["failures"],
               record["skipped"], format_duration(record["time"]), icon)
        )
        for key in grand:
            grand[key] += record[key]

    passed = grand["tests"] - grand["failures"] - grand["skipped"]
    lines.append(
        "| **Total** | **%d** | **%d** | **%d** | **%d** | | |"
        % (grand["tests"], passed, grand["failures"], grand["skipped"])
    )
    lines.append("")
    lines.append(
        "\\* Advisory. The simulator platforms run with `continue-on-error`; the macOS job is "
        "what gates the pull request. A red cell here is still worth looking at."
    )

    if simulators_skipped:
        lines += [
            "", "> [!NOTE]",
            "> The simulator jobs did not run: they depend on the macOS job, which did not "
            "pass.",
        ]
    if missing:
        lines += ["", "> [!WARNING]", "> No test results for: " + "; ".join(missing) + "."]

    if any_failure:
        failed = []
        for platform in PLATFORMS:
            failed.extend(sorted(results.get(platform, {}).get("failed", [])))
        lines += ["", "<details><summary>Failed tests (%d)</summary>" % len(failed), ""]
        for name in failed[:MAX_FAILURES_LISTED]:
            lines.append("- `%s`" % name)
        if len(failed) > MAX_FAILURES_LISTED:
            lines.append("- …and %d more; see the check run." % (len(failed) - MAX_FAILURES_LISTED))
        lines += ["", "</details>"]

    return lines, grand, any_failure


def coverage_section(coverage_dir):
    records = []
    for path in sorted(glob.glob(os.path.join(coverage_dir, "**", "*.json"), recursive=True)):
        try:
            records.append(json.loads(Path(path).read_text(encoding="utf-8")))
        except (json.JSONDecodeError, OSError):
            continue
    records = [r for r in records if r.get("lines")]
    if not records:
        return ["### Code coverage", "", "No coverage data was produced by this run."]

    order = {name: index for index, name in enumerate(PLATFORMS)}
    records.sort(key=lambda r: order.get(r.get("platform"), 99))

    lines = [
        "### Code coverage",
        "",
        "| Platform | Line coverage | Covered | Total lines |",
        "| --- | ---: | ---: | ---: |",
    ]
    for record in records:
        lines.append(
            "| %s | %.2f%% | %d | %d |"
            % (record["platform"], record["percent"], record["covered"], record["lines"])
        )
    lines += [
        "",
        "The platforms measure different amounts of code, so the percentages are not "
        "comparable: `WebViewManager`, `OverlayWindow` and the notification service are "
        "compiled out on macOS. Reported, not enforced — there is no coverage gate.",
    ]

    for record in records:
        worst = record["files"][:MAX_FILES_LISTED]
        if not worst:
            continue
        lines += [
            "",
            "<details><summary>Least covered files (%s)</summary>" % record["platform"],
            "",
            "| File | Coverage | Covered | Lines |",
            "| --- | ---: | ---: | ---: |",
        ]
        for entry in worst:
            lines.append(
                "| `%s` | %.2f%% | %d | %d |"
                % (entry["path"], entry["percent"], entry["covered"], entry["lines"])
            )
        lines += ["", "</details>"]

    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--junit-dir", required=True)
    parser.add_argument("--coverage-dir", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--title", default="CI report :rocket:")
    parser.add_argument(
        "--simulators-result", default="",
        help="the needs.<job>.result of the simulator matrix: success, failure, skipped, …",
    )
    arguments = parser.parse_args()

    results = gather_tests(arguments.junit_dir)
    tests, grand, any_failure = test_section(results, arguments.simulators_result)
    coverage = coverage_section(arguments.coverage_dir)

    body = ["## %s" % arguments.title, ""] + tests + [""] + coverage
    text = "\n".join(body) + "\n"

    output = Path(arguments.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="utf-8")

    # The same body goes to the run summary, so the report exists even where the job cannot
    # comment -- a fork pull request, or a push to a branch with no pull request open.
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(text)

    print(text)
    # Always exits zero. This step reports; the test jobs decide whether the run is red.
    if any_failure:
        print("::warning::at least one platform reported a failing test")


if __name__ == "__main__":
    main()
