#!/usr/bin/env python3
"""Detect a starved CI runner in an xcodebuild log.

A shared runner under load does not fail tests in a way that looks like load. It
fails them in a way that looks like a bug: a WebKit-backed test times out waiting
for a page that never rendered, a different test fails on the next run, and the
diff in flight gets the blame. That misreading is expensive, and it is avoidable,
because the starvation leaves a specific fingerprint in the log.

WebKit logs its own process launches with the duration inline:

    [Process] WebContent process (0x1130180c0) took 30.342715 seconds to launch
    [Process] Networking process (0x11308c400) took 30.358148 seconds to launch

A healthy launch is well under a second. Thirty is a runner that could not
schedule the process, and it is already past the suite's timeout before the page
has done any work of its own. So the number is the signal, not the presence of
the line: these lines are also printed on perfectly healthy runs.

This reports rather than fails. A starved runner is infrastructure, and the
report exists so a human reads "the runner was starved" instead of inferring "the
web view code broke".

Deliberately not used as a signal:

  - `RBSServiceErrorDomain` / `ProcessAssertion::acquireSync` failures. These are
    printed many times over on runs that pass, so thresholding them gives false
    positives. Verified against a green visionOS run.
  - `NSURLErrorDomain Code=-1009` on its own. The mock transport produces it
    legitimately when a suite asserts offline behaviour, so it corroborates a
    launch stall but cannot stand alone.
"""

import argparse
import json
import os
import re
import sys

# The seconds are always inline, which is what makes a threshold possible.
LAUNCH = re.compile(r"\[Process\]\s+(\w+) process[^)]*\)?\s*took\s+([0-9.]+)\s+seconds to launch")

# A cold, unloaded launch is comfortably under a second. Five leaves room for a
# genuinely slow-but-working runner before anything is called starved.
DEFAULT_THRESHOLD = 5.0


def scan(path, threshold):
    """Return the launches over `threshold`, slowest first, and the slowest overall."""
    slow, worst = {}, 0.0
    try:
        with open(path, "r", errors="replace") as handle:
            for line in handle:
                match = LAUNCH.search(line)
                if not match:
                    continue
                name, seconds = match.group(1), float(match.group(2))
                worst = max(worst, seconds)
                if seconds >= threshold:
                    # One entry per process type, holding its worst launch: ten slow
                    # WebContent launches are one story, not ten.
                    slow[name] = max(slow.get(name, 0.0), seconds)
    except FileNotFoundError:
        return None, 0.0
    return slow, worst


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, help="the tee'd xcodebuild log")
    parser.add_argument("--platform", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    args = parser.parse_args()

    slow, worst = scan(args.log, args.threshold)
    if slow is None:
        # No log is not a finding. The step may not have run at all.
        print(f"{args.platform}: no log at {args.log}, nothing to assess")
        return 0

    report = {
        "platform": args.platform,
        "starved": bool(slow),
        "threshold": args.threshold,
        "slowest_launch_seconds": round(worst, 1),
        "processes": {name: round(seconds, 1) for name, seconds in sorted(
            slow.items(), key=lambda item: -item[1])},
    }

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w") as handle:
        json.dump(report, handle, indent=2)

    if slow:
        listed = ", ".join(f"{name} {seconds:.1f}s" for name, seconds in report["processes"].items())
        print(f"::warning title=Starved runner ({args.platform})::"
              f"Process launches over {args.threshold:.0f}s: {listed}. "
              f"Test failures on this run are likely runner contention, not the code under test.")
    else:
        print(f"{args.platform}: no process launch over {args.threshold:.0f}s "
              f"(slowest {worst:.1f}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
