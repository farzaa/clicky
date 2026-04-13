#!/usr/bin/env python3
"""
Refreshes the hardcoded TFT snapshot in leanring-buddy/TFTMetaContext.swift.

Usage:
  python3 scripts/update_tft_meta_snapshot.py
  python3 scripts/update_tft_meta_snapshot.py --meta-note "Your custom note"
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import urllib.request
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SWIFT_FILE = REPO_ROOT / "leanring-buddy" / "TFTMetaContext.swift"
PATCH_TAGS_URL = "https://www.leagueoflegends.com/en-us/news/tags/teamfight-tactics-patch-notes/"
DDRAGON_VERSIONS_URL = "https://ddragon.leagueoflegends.com/api/versions.json"

BEGIN_MARKER = "// BEGIN_AUTOGEN_TFT_SNAPSHOT"
END_MARKER = "// END_AUTOGEN_TFT_SNAPSHOT"

DEFAULT_META_NOTES = [
    "This is a manually maintained snapshot, not a live API feed. State confidence when meta calls are uncertain.",
    "Patch notes are the source of truth for current balance direction.",
    "Use the current board/shop/items shown on screen to make final recommendations.",
]


def fetch_text(url: str) -> str:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "clicky-tft-snapshot-updater/1.0"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8", errors="replace")


def fetch_latest_patch_url() -> str:
    html = fetch_text(PATCH_TAGS_URL)
    url_matches = re.findall(
        r"https://teamfighttactics\.leagueoflegends\.com/[a-z-]+/news/game-updates/teamfight-tactics-patch-[^\"<\s]+/?",
        html,
        flags=re.IGNORECASE,
    )
    if not url_matches:
        raise RuntimeError("Could not find a TFT patch URL on the patch tags page.")

    # Keep original order and deduplicate.
    deduped = list(dict.fromkeys(url_matches))

    def patch_version_key(url: str) -> tuple[int, int]:
        match = re.search(r"teamfight-tactics-patch-(\d+)-(\d+)", url)
        if not match:
            return (0, 0)
        return (int(match.group(1)), int(match.group(2)))

    sorted_urls = sorted(deduped, key=patch_version_key, reverse=True)
    return sorted_urls[0]


def fetch_patch_details(patch_url: str) -> tuple[str, str]:
    html = fetch_text(patch_url)

    title_match = re.search(
        r"<h1[^>]*>\s*(Teamfight Tactics patch[^<]+)\s*</h1>",
        html,
        flags=re.IGNORECASE,
    )
    if title_match:
        patch_title = " ".join(title_match.group(1).split())
    else:
        slug_match = re.search(r"teamfight-tactics-patch-([a-z0-9.-]+)", patch_url, flags=re.IGNORECASE)
        if not slug_match:
            raise RuntimeError("Could not determine patch title.")
        patch_title = f"Teamfight Tactics patch {slug_match.group(1).replace('-', '.').upper()}"

    published_match = re.search(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.000Z)", html)
    patch_published_at = published_match.group(1) if published_match else "unknown"

    return patch_title, patch_published_at


def fetch_data_dragon_version() -> str:
    payload = fetch_text(DDRAGON_VERSIONS_URL)
    versions = json.loads(payload)
    if not isinstance(versions, list) or not versions:
        raise RuntimeError("Data Dragon versions response is empty.")
    return str(versions[0])


def swift_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\"", "\\\"")


def build_snapshot_block(
    snapshot_date: str,
    patch_title: str,
    patch_published_at: str,
    patch_url: str,
    ddragon_version: str,
    meta_notes: list[str],
) -> str:
    escaped_notes = "\n".join(
        f'            "{swift_escape(note)}",'
        for note in meta_notes
    )

    return f"""{BEGIN_MARKER}
    static let currentSnapshot = TFTMetaContextSnapshot(
        snapshotUpdatedOn: "{swift_escape(snapshot_date)}",
        latestPatchTitle: "{swift_escape(patch_title)}",
        latestPatchPublishedAt: "{swift_escape(patch_published_at)}",
        latestPatchURL: "{swift_escape(patch_url)}",
        dataDragonVersion: "{swift_escape(ddragon_version)}",
        metaNotes: [
{escaped_notes}
        ]
    )
    {END_MARKER}"""


def replace_snapshot_block(file_text: str, new_block: str) -> str:
    pattern = re.compile(
        re.escape(BEGIN_MARKER) + r".*?" + re.escape(END_MARKER),
        flags=re.DOTALL,
    )
    if not pattern.search(file_text):
        raise RuntimeError("Could not find TFT snapshot markers in TFTMetaContext.swift.")
    return pattern.sub(new_block, file_text)


def main() -> int:
    parser = argparse.ArgumentParser(description="Refresh hardcoded TFT snapshot data.")
    parser.add_argument("--snapshot-date", dest="snapshot_date", help="YYYY-MM-DD date for snapshot update marker.")
    parser.add_argument("--patch-title", dest="patch_title", help="Override patch title.")
    parser.add_argument("--patch-published-at", dest="patch_published_at", help="Override patch published timestamp.")
    parser.add_argument("--patch-url", dest="patch_url", help="Override patch URL.")
    parser.add_argument("--ddragon-version", dest="ddragon_version", help="Override Data Dragon version.")
    parser.add_argument("--meta-note", dest="meta_notes", action="append", help="Custom meta note. Repeat for multiple notes.")
    args = parser.parse_args()

    patch_url = args.patch_url or fetch_latest_patch_url()
    patch_title, patch_published_at = fetch_patch_details(patch_url)
    if args.patch_title:
        patch_title = args.patch_title
    if args.patch_published_at:
        patch_published_at = args.patch_published_at

    ddragon_version = args.ddragon_version or fetch_data_dragon_version()
    snapshot_date = args.snapshot_date or dt.datetime.now(dt.timezone.utc).date().isoformat()
    meta_notes = args.meta_notes if args.meta_notes else DEFAULT_META_NOTES

    file_text = SWIFT_FILE.read_text(encoding="utf-8")
    new_block = build_snapshot_block(
        snapshot_date=snapshot_date,
        patch_title=patch_title,
        patch_published_at=patch_published_at,
        patch_url=patch_url,
        ddragon_version=ddragon_version,
        meta_notes=meta_notes,
    )
    updated_text = replace_snapshot_block(file_text, new_block)
    SWIFT_FILE.write_text(updated_text, encoding="utf-8")

    print("Updated TFT snapshot.")
    print(f"  Patch title: {patch_title}")
    print(f"  Patch URL: {patch_url}")
    print(f"  Published at: {patch_published_at}")
    print(f"  Data Dragon version: {ddragon_version}")
    print(f"  Snapshot date: {snapshot_date}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
