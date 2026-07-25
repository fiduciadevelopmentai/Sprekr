#!/usr/bin/env python3
"""Remove stale Sprekr Dock tiles that point at deleted build-tree / .development apps.

Keeps the certificate-bound install (usually /Applications/Sprekr.app). Never touches TCC.
"""

from __future__ import annotations

import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

STALE_BUNDLE_IDS = {"com.klimtalks.app.development"}
STALE_PATH_SNIPPETS = (
    "/build/debug/Sprekr.app",
    "/build/release/Sprekr.app",
)


def is_stale(item: dict) -> bool:
    tile = item.get("tile-data") or {}
    bid = tile.get("bundle-identifier") or ""
    url = ((tile.get("file-data") or {}).get("_CFURLString")) or ""
    book = tile.get("book") or b""
    if bid in STALE_BUNDLE_IDS:
        return True
    if any(snippet in url for snippet in STALE_PATH_SNIPPETS):
        return True
    if isinstance(book, (bytes, bytearray)) and (
        b"build/debug" in book or b"build/release" in book
    ):
        return True
    return False


def is_production_sprekr(item: dict) -> bool:
    tile = item.get("tile-data") or {}
    bid = tile.get("bundle-identifier") or ""
    url = ((tile.get("file-data") or {}).get("_CFURLString")) or ""
    return bid == "com.klimtalks.app" or url.rstrip("/").endswith("/Applications/Sprekr.app")


def main() -> int:
    export = subprocess.check_output(["defaults", "export", "com.apple.dock", "-"])
    dock = plistlib.loads(export)
    changed = False
    removed: list[str] = []

    for key in ("persistent-apps", "recent-apps", "persistent-others"):
        items = list(dock.get(key) or [])
        kept: list[dict] = []
        for item in items:
            if is_stale(item):
                tile = item.get("tile-data") or {}
                url = ((tile.get("file-data") or {}).get("_CFURLString")) or ""
                removed.append(f"{key}: {tile.get('bundle-identifier')} {url}")
                changed = True
            else:
                kept.append(item)
        dock[key] = kept

    # Collapse duplicate production Sprekr recent tiles to one.
    kept_recent: list[dict] = []
    seen_production = False
    for item in dock.get("recent-apps") or []:
        if is_production_sprekr(item):
            if seen_production:
                tile = item.get("tile-data") or {}
                url = ((tile.get("file-data") or {}).get("_CFURLString")) or ""
                removed.append(f"recent-apps duplicate: {url}")
                changed = True
                continue
            seen_production = True
        kept_recent.append(item)
    dock["recent-apps"] = kept_recent

    if not changed:
        print("No stale Sprekr Dock tiles found.")
        return 0

    for line in removed:
        print(f"Removed Dock tile: {line}")

    with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as handle:
        tmp = Path(handle.name)
        tmp.write_bytes(plistlib.dumps(dock, fmt=plistlib.FMT_BINARY))
    try:
        subprocess.check_call(["defaults", "import", "com.apple.dock", str(tmp)])
    finally:
        tmp.unlink(missing_ok=True)
    subprocess.run(["killall", "Dock"], check=False)
    print("Dock refreshed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
