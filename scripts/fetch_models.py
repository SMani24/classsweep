#!/usr/bin/env python3
"""Fetch exact upstream model binaries; refuse corrupted or substituted downloads."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    manifest = json.loads((ROOT / 'scripts/models.json').read_text())
    destination = ROOT / 'mobile/assets/models'
    destination.mkdir(parents=True, exist_ok=True)
    for entry in manifest['models']:
        path = destination / entry['file']
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256']:
            print(f"Verified {entry['file']}")
            continue
        request = urllib.request.Request(entry['url'], headers={'User-Agent': 'ClassSweep-model-fetcher'})
        with urllib.request.urlopen(request, timeout=90) as response:
            data = response.read(entry['bytes'] + 1)
        if len(data) != entry['bytes'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise SystemExit(f"Integrity check failed for {entry['file']}; nothing written")
        temporary = path.with_suffix('.download')
        temporary.write_bytes(data)
        temporary.replace(path)
        print(f"Downloaded and verified {entry['file']}")


if __name__ == '__main__':
    main()
