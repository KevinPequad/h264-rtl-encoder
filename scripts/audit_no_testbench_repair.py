#!/usr/bin/env python3
"""Static no-testbench-repair audit for RTL-owned H.264 bitstreams.

This is a thin wrapper around the repo's ownership/audit harness so gate
scripts can assert that final-syntax bytes stay RTL-owned and that no repair
hooks are present in the checkout.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from run_h264_verify_manifest import repo_root, static_rtl_ownership_audit


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=None, help="Repository root (defaults to auto-detection)")
    args = parser.parse_args()

    root = args.repo_root if args.repo_root is not None else repo_root()
    audit = static_rtl_ownership_audit(root)
    print(json.dumps(audit, indent=2, sort_keys=True))
    return 0 if audit.get("status") == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
