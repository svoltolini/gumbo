#!/usr/bin/env python3
"""Validate each target against the current app version, without a stale release constant."""
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
targets = ("Gumbo", "GumboWidgets", "GumboWatch", "GumboMac", "GumboTV")
versions = {}
for target in targets:
    match = re.search(r"^  " + re.escape(target) + r":\n(.*?)(?=^  \S|\Z)", text, re.M | re.S)
    section = match.group(1) if match else ""
    values = []
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        value = re.search(r"^\s+" + key + r":\s*\"([^\"]+)\"\s*$", section, re.M)
        values.append(value.group(1) if value else None)
    versions[target] = tuple(values)
expected = versions["Gumbo"]
valid = bool(expected[0] and expected[1])
for target, value in versions.items():
    print(f"{target}: {value[0]} ({value[1]})")
    valid = valid and value == expected
sys.exit(0 if valid else 1)
