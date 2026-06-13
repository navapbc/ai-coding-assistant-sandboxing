#!/usr/bin/env python3
"""Validate intra-repo Markdown links and heading anchors.

Walks every .md file under the repo root and checks that each relative link
(a) points at a file that exists, and (b) if it has a #fragment into another
.md file, that a matching heading anchor exists there. External (http) links
are not checked. Exits non-zero and lists every problem found.

Run from the repo root:  python3 scripts/validate-docs.py
"""
import os
import re
import sys

LINK_RE = re.compile(r"\]\((?!https?:)([^)]+)\)")
HEADING_RE = re.compile(r"^#+\s+(.*)")


def anchors(path):
    found = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = HEADING_RE.match(line)
            if m:
                slug = re.sub(r"[^\w\s-]", "", m.group(1).lower()).strip().replace(" ", "-")
                found.add(slug)
    return found


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    problems = []
    for dirpath, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".md"):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8") as f:
                text = f.read()
            for link in LINK_RE.findall(text):
                file_part, _, anchor = link.partition("#")
                target = os.path.normpath(os.path.join(dirpath, file_part)) if file_part else path
                if not os.path.exists(target):
                    problems.append(f"{path}: missing file -> {link}")
                    continue
                if anchor and target.endswith(".md") and anchor not in anchors(target):
                    problems.append(f"{path}: missing anchor #{anchor} in {file_part or name}")

    if problems:
        print("Doc validation FAILED:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("Doc validation OK: all relative links and anchors resolve.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
