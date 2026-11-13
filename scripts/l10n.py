#!/usr/bin/env python3
"""Keeps the translation tables complete.

  scripts/l10n.py missing            lists the L("…") / plural(…) literals that have no translation yet
  scripts/l10n.py add <file.json>    adds translations: {"texto en español": {"en": "…", "pt": "…"}, …}

Spanish is the source language: the Spanish text is the key in both tables
(Sources/DevDeckCore/L10n+English.swift and L10n+Portuguese.swift).
Strings that only live in data tables (L10n.dataKeys) are checked by the tests, not here.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
TABLES = {"en": SOURCES / "DevDeckCore" / "L10n+English.swift", "pt": SOURCES / "DevDeckCore" / "L10n+Portuguese.swift"}
STRING = r'"((?:[^"\\]|\\.)*)"'
PATTERNS = [re.compile(r"\bL\(\s*" + STRING), re.compile(r"\bplural\([^,]+,\s*" + STRING + r"\s*,\s*" + STRING)]
ENTRY = re.compile(r"^\s*" + STRING + r":\s*" + STRING + r",\s*$")


def source_keys():
    keys = set()
    for path in SOURCES.rglob("*.swift"):
        if path.name.startswith("L10n"):
            continue
        text = path.read_text(encoding="utf-8")
        for pattern in PATTERNS:
            for match in pattern.finditer(text):
                keys.update(group for group in match.groups() if group is not None)
    return keys


def table_keys(language):
    keys = set()
    for line in TABLES[language].read_text(encoding="utf-8").splitlines():
        match = ENTRY.match(line)
        if match:
            keys.add(match.group(1))
    return keys


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def missing():
    keys = source_keys()
    out = sorted(key for key in keys if any(key not in table_keys(language) for language in TABLES))
    for key in out:
        print(key)
    return 1 if out else 0


def add(path):
    entries = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    for language, table in TABLES.items():
        existing = table_keys(language)
        lines = table.read_text(encoding="utf-8").splitlines()
        end = max(index for index, line in enumerate(lines) if line.strip() == "]")
        new = []
        for key, values in entries.items():
            raw = escape(key)
            if raw in existing or language not in values:
                continue
            new.append(f'        "{raw}": "{escape(values[language])}",')
        lines[end:end] = new
        table.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"{language}: {len(new)} added")
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "missing":
        sys.exit(missing())
    if len(sys.argv) == 3 and sys.argv[1] == "add":
        sys.exit(add(sys.argv[2]))
    print(__doc__)
    sys.exit(2)
