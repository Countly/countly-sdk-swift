#!/usr/bin/env python3
"""Converts an `.xcresult` bundle into a JUnit XML file.

`xcodebuild` writes a result bundle, not JUnit XML, and every reporting action worth using
consumes JUnit XML. Something has to bridge the two.

Why this and not the alternatives
---------------------------------
* `xcbeautify --report junit` / `xcpretty --report junit` build their report by *parsing
  xcodebuild's console text*. That is the failure mode this repository cannot afford: when the
  output format shifts, or the build dies before the first `Test Case '-[...]' started` line,
  the pipe still exits cleanly and writes a well formed XML file containing zero tests. A
  reporting step that succeeds while reporting nothing is worse than one that fails, so a text
  scraper is the wrong foundation. Both also need to be installed on the runner first, which
  buys a supply chain dependency for the privilege.
* `xcrun xcresulttool get test-results tests` reads the structured result bundle that
  xcodebuild already wrote. It is authoritative rather than inferred, it survives parallel and
  repeated test runs, and, unlike the console scrapers, it reports skipped tests as skipped
  rather than as nothing at all -- which matters here, because the suites skip deliberately
  where a platform lacks the feature (watchOS skips ~136, tvOS ~17) and those counts are the
  signal, not noise.

The macOS job does not use this script: `swift test --xunit-output` emits JUnit directly, so
there is nothing to convert there.

This script refuses to write an empty report. If the bundle contains no test cases, it exits
non-zero with a `::error::` rather than leaving a green step and a silent gap in the table.

Usage:
    xcresult_to_junit.py --xcresult Test.xcresult --platform iOS --output junit/ios.xml
    xcresult_to_junit.py --json dumped.json --platform iOS --output junit/ios.xml
"""

import argparse
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# `xcresulttool get test-results tests` labels every node in the tree with one of a fixed set
# of nodeType strings. Only these two carry the information the report needs.
TEST_CASE = "Test Case"
FAILURE_NODES = {"Failure Message", "Expression", "Test Value"}

# Result strings the tool emits on a Test Case node.
PASSED = {"Passed", "Expected Failure"}
SKIPPED = {"Skipped"}
FAILED = {"Failed"}

# "1m 3.5s", "0.012s", "0,012s" (xcresulttool follows the runner locale for the decimal mark).
DURATION = re.compile(r"(?:(\d+)m\s*)?(?:([\d.,]+)s)?")


def parse_duration(text):
    """Seconds as a float. Unparseable or absent durations become 0.0 rather than an error:
    a missing timing must not cost the whole report."""
    if not text:
        return 0.0
    match = DURATION.fullmatch(text.strip())
    if not match:
        return 0.0
    minutes, seconds = match.groups()
    total = float(minutes) * 60 if minutes else 0.0
    if seconds:
        try:
            total += float(seconds.replace(",", "."))
        except ValueError:
            return total
    return total


def dump_xcresult(path):
    """The structured test results for a bundle, as the tool's JSON."""
    if not Path(path).exists():
        sys.exit("::error::%s does not exist, so there are no test results to convert" % path)
    command = [
        "xcrun", "xcresulttool", "get", "test-results", "tests",
        "--path", str(path), "--format", "json",
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(
            "::error::xcresulttool failed on %s (exit %d). This subcommand needs Xcode 16 or "
            "newer. stderr: %s" % (path, result.returncode, result.stderr.strip())
        )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        sys.exit("::error::xcresulttool produced output that is not JSON: %s" % error)


def failure_text(node):
    """Every failure message hanging off a test case, joined into one block."""
    messages = []

    def walk(current):
        if current.get("nodeType") in FAILURE_NODES:
            name = current.get("name")
            if name:
                messages.append(name)
        for child in current.get("children") or []:
            walk(child)

    for child in node.get("children") or []:
        walk(child)
    return "\n".join(messages)


def collect(node, suite, cases):
    """Flattens the node tree into (suite name, case node) pairs.

    Suites nest -- a bundle contains suites which can contain further suites -- so the suite a
    case belongs to is the nearest named ancestor that is not the test plan itself.
    """
    node_type = node.get("nodeType")
    if node_type == TEST_CASE:
        cases.append((suite or "Tests", node))
        # A Test Case can carry Test Case Run children for repetitions and configurations.
        # They are not separate tests, so the walk stops here.
        return
    name = node.get("name")
    if node_type in ("Test Suite", "Unit test bundle", "UI test bundle") and name:
        suite = name
    for child in node.get("children") or []:
        collect(child, suite, cases)


def build_xml(cases, platform):
    """A JUnit `<testsuites>` tree, one `<testsuite>` per Xcode test suite."""
    suites = {}
    for suite, case in cases:
        suites.setdefault(suite, []).append(case)

    root = ET.Element("testsuites", name=platform)
    totals = {"tests": 0, "failures": 0, "skipped": 0, "time": 0.0}

    for suite in sorted(suites):
        members = suites[suite]
        counts = {"tests": len(members), "failures": 0, "skipped": 0, "time": 0.0}
        element = ET.SubElement(root, "testsuite", name="%s.%s" % (platform, suite))

        for case in members:
            name = case.get("name") or "unnamed"
            seconds = parse_duration(case.get("duration"))
            counts["time"] += seconds
            # The platform is folded into classname because the five platforms' reports are
            # merged into one check; without it a failure cannot be attributed to a platform.
            case_element = ET.SubElement(
                element, "testcase",
                name=name,
                classname="%s.%s" % (platform, suite),
                time="%.3f" % seconds,
            )
            result = case.get("result")
            if result in FAILED:
                counts["failures"] += 1
                message = failure_text(case) or "Test failed"
                failure = ET.SubElement(
                    case_element, "failure", message=message.splitlines()[0][:400]
                )
                failure.text = message
            elif result in SKIPPED:
                counts["skipped"] += 1
                ET.SubElement(case_element, "skipped")
            elif result not in PASSED:
                # An unrecognised result is treated as a failure on purpose. Silently counting
                # an unknown state as a pass is how a broken run reports green.
                counts["failures"] += 1
                failure = ET.SubElement(
                    case_element, "failure", message="Unrecognised result: %r" % result
                )
                failure.text = failure_text(case)

        element.set("tests", str(counts["tests"]))
        element.set("failures", str(counts["failures"]))
        element.set("errors", "0")
        element.set("skipped", str(counts["skipped"]))
        element.set("time", "%.3f" % counts["time"])
        for key in totals:
            totals[key] += counts[key]

    root.set("tests", str(totals["tests"]))
    root.set("failures", str(totals["failures"]))
    root.set("errors", "0")
    root.set("skipped", str(totals["skipped"]))
    root.set("time", "%.3f" % totals["time"])
    return root, totals


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--xcresult", help="path to the .xcresult bundle")
    source.add_argument("--json", help="a previously dumped xcresulttool JSON file")
    parser.add_argument("--platform", required=True, help="iOS, tvOS, watchOS, visionOS, macOS")
    parser.add_argument("--output", required=True, help="path of the JUnit XML to write")
    arguments = parser.parse_args()

    if arguments.xcresult:
        payload = dump_xcresult(arguments.xcresult)
    else:
        payload = json.loads(Path(arguments.json).read_text(encoding="utf-8"))

    cases = []
    for node in payload.get("testNodes") or []:
        collect(node, None, cases)

    if not cases:
        sys.exit(
            "::error::no test cases were found in the result bundle for %s. Refusing to write "
            "an empty JUnit report -- a report that says nothing reads as a clean run."
            % arguments.platform
        )

    root, totals = build_xml(cases, arguments.platform)

    output = Path(arguments.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(output, encoding="utf-8", xml_declaration=True)

    passed = totals["tests"] - totals["failures"] - totals["skipped"]
    print(
        "%s: %d tests, %d passed, %d failed, %d skipped, %.1fs -> %s"
        % (arguments.platform, totals["tests"], passed, totals["failures"],
           totals["skipped"], totals["time"], output)
    )


if __name__ == "__main__":
    main()
