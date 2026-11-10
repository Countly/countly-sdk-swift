#!/usr/bin/env python3
"""Fails a pull request whose coverage is lower than the base branch's.

The base branch's figure is the coverage summary of its last green push, which every push
uploads as an artifact. Without one, for example on the first pull request after the gate was
added, the gate passes with a notice: there is nothing to compare against.

The files are found by platform name anywhere under the two directories, because how an
artifact unpacks depends on the paths it was uploaded from.

Usage:
    coverage_gate.py --platform macOS --current-dir coverage --baseline-dir coverage-baseline
"""

import argparse
import json
import sys
from pathlib import Path

# Coverage moves by a few hundredths when lines elsewhere are added or removed, so a smaller
# drop than this is not counted as lowering it.
TOLERANCE = 0.05


def find_summary(directory, platform):
    """The summary file of `platform` under `directory`, or None."""
    root = Path(directory)
    if not root.is_dir():
        return None
    return next(iter(sorted(root.rglob("%s.json" % platform))), None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--current-dir", required=True)
    parser.add_argument("--baseline-dir", required=True)
    arguments = parser.parse_args()

    current_path = find_summary(arguments.current_dir, arguments.platform)
    if current_path is None:
        sys.exit("::error::no %s coverage summary was produced, so the gate cannot judge this pull request" % arguments.platform)

    baseline_path = find_summary(arguments.baseline_dir, arguments.platform)
    if baseline_path is None:
        print("::notice::no %s coverage of the base branch was found, the gate has nothing to compare against and passes" % arguments.platform)
        return

    current = json.loads(current_path.read_text(encoding="utf-8"))
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))

    print("%s coverage: %.2f%% in this pull request, %.2f%% on the base branch"
          % (arguments.platform, current["percent"], baseline["percent"]))

    if baseline["percent"] - current["percent"] > TOLERANCE:
        sys.exit("::error::this pull request lowers the %s coverage from %.2f%% to %.2f%%. Add tests for the code it changes."
                 % (arguments.platform, baseline["percent"], current["percent"]))


if __name__ == "__main__":
    main()
