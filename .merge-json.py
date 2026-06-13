#!/usr/bin/env python3
"""Deep-merge a baseline JSON config into an existing one for setup.sh.

Usage: .merge-json.py <existing> <overlay> <out>

Merge rules (overlay = our baseline, takes precedence):
  - dict + dict  -> recurse key by key (keys unique to existing are preserved)
  - list + list  -> union, existing order preserved, new items appended, deduped
  - anything else -> overlay value wins (so the security baseline is enforced)
"""
import json
import sys


def merge(existing, overlay):
    if isinstance(existing, dict) and isinstance(overlay, dict):
        result = dict(existing)
        for key, value in overlay.items():
            result[key] = merge(existing[key], value) if key in existing else value
        return result
    if isinstance(existing, list) and isinstance(overlay, list):
        result = list(existing)
        for item in overlay:
            if item not in result:
                result.append(item)
        return result
    return overlay


def main():
    existing_path, overlay_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(existing_path) as f:
        existing = json.load(f)
    with open(overlay_path) as f:
        overlay = json.load(f)
    merged = merge(existing, overlay)
    with open(out_path, "w") as f:
        json.dump(merged, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
