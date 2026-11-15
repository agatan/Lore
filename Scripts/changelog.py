#!/usr/bin/env python3
"""Check, preview, and release the changelog fragments in changelog.d/."""

import argparse
import datetime
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FRAGMENTS = ROOT / "changelog.d"
CHANGELOG = ROOT / "CHANGELOG.md"
SECTIONS = {
    "added": "Added",
    "changed": "Changed",
    "fixed": "Fixed",
    "removed": "Removed",
    "security": "Security",
}
NAME = re.compile(r"^(\d+)\.(" + "|".join(SECTIONS) + r")\.md$")


def fragments():
    found, errors = [], []
    for path in sorted(FRAGMENTS.glob("*")):
        if path.name == "README.md":
            continue
        match = NAME.match(path.name)
        if not match:
            errors.append(f"{path.name}: rename to <issue>.<type>.md, where <type> is one of {', '.join(SECTIONS)}")
            continue
        lines = [line for line in path.read_text().splitlines() if line.strip()]
        if not lines:
            errors.append(f"{path.name}: add at least one '- ' bullet line")
        for line in lines:
            if not line.startswith("- "):
                errors.append(f"{path.name}: start every line with '- ': {line!r}")
        found.append((int(match.group(1)), match.group(2), lines, path))
    return found, errors


def section(heading, found):
    out = [f"## {heading}", ""]
    for kind, title in SECTIONS.items():
        entries = sorted((number, lines) for number, k, lines, _ in found if k == kind)
        if entries:
            out += [f"### {title}", ""]
            out += [line for _, lines in entries for line in lines]
            out.append("")
    return "\n".join(out)


def checked():
    found, errors = fragments()
    if errors:
        sys.exit("\n".join(errors))
    return found


def check(_):
    print(f"{len(checked())} changelog fragments are valid")


def preview(_):
    found = checked()
    print(section("Unreleased", found) if found else "No unreleased changes.")


def release(args):
    found = checked()
    if not found:
        sys.exit("No fragments in changelog.d/ to release.")
    text = CHANGELOG.read_text()
    if re.search(rf"^## {re.escape(args.version)} ", text, re.MULTILINE):
        sys.exit(f"CHANGELOG.md already has a {args.version} section.")
    new = section(f"{args.version} - {args.date}", found)
    first = re.search(r"^## ", text, re.MULTILINE)
    if first:
        text = text[: first.start()] + new + "\n" + text[first.start():]
    else:
        text = text.rstrip("\n") + "\n\n" + new
    CHANGELOG.write_text(text)
    for *_, path in found:
        path.unlink()
    print(f"Added {args.version} to CHANGELOG.md and removed {len(found)} fragments")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(required=True)
    commands.add_parser("check", help="validate fragment names and contents").set_defaults(run=check)
    commands.add_parser("preview", help="print the next release's notes").set_defaults(run=preview)
    cut = commands.add_parser("release", help="move the fragments into CHANGELOG.md")
    cut.add_argument("version")
    cut.add_argument("--date", default=datetime.date.today().isoformat())
    cut.set_defaults(run=release)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
