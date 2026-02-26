#!/usr/bin/env python3
"""
merge_diagnostics.py

Merge VS Code "Problems" JSON exports (e.g. from problems-as-file) into a single
deduplicated JSON list.

Input formats supported:
- A JSON list of diagnostics (list[dict])
- A JSON object containing one of these keys with a list value:
  - "problems", "diagnostics", "items", "data"

Deduplication key uses:
(file/path/resource, code, line, column, message)

Usage:
  python3 merge_diagnostics.py --inputs a.json,b.json --output merged.json
  python3 merge_diagnostics.py --inputs-dir ./exports --glob 'project-problems-*.json' --output merged.json

Exit codes:
  0 OK
  2 No input files found / all missing
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from typing import Any, Dict, Iterable, List, Optional, Tuple


def extract_items(data: Any) -> List[Dict[str, Any]]:
    """Return a list of diagnostic dicts from either a list or a dict wrapper."""
    if isinstance(data, list):
        return [x for x in data if isinstance(x, dict)]
    if isinstance(data, dict):
        for k in ("problems", "diagnostics", "items", "data"):
            v = data.get(k)
            if isinstance(v, list):
                return [x for x in v if isinstance(x, dict)]
    return []


def get_code(d: Dict[str, Any]) -> str:
    code = d.get("code")
    if isinstance(code, dict):
        return str(code.get("value") or "")
    if isinstance(code, str):
        return code
    return ""


def get_file(d: Dict[str, Any]) -> str:
    fp = d.get("resource") or d.get("file") or d.get("uri") or d.get("path")
    if isinstance(fp, dict):
        fp = fp.get("path") or fp.get("fsPath") or fp.get("uri")
    return str(fp) if fp else ""


def get_pos(d: Dict[str, Any]) -> Tuple[str, str]:
    """
    Return (line, column) as strings.
    Supports both:
      - startLineNumber/startColumn
      - range.start.line / range.start.character
    """
    line = d.get("startLineNumber")
    col = d.get("startColumn")
    if line is not None and col is not None:
        return str(line), str(col)

    r = d.get("range", {})
    if isinstance(r, dict):
        s = r.get("start", {})
        if isinstance(s, dict):
            line = s.get("line")
            col = s.get("character")

    return (str(line) if line is not None else "", str(col) if col is not None else "")


def diag_key(d: Dict[str, Any]) -> Tuple[str, str, str, str, str]:
    return (get_file(d), get_code(d), *get_pos(d), str(d.get("message") or ""))


def read_json_file(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def list_inputs_from_dir(inputs_dir: str, pattern: str) -> List[str]:
    return sorted(glob.glob(os.path.join(inputs_dir, pattern)))


def parse_inputs_csv(inputs_csv: str) -> List[str]:
    return [x.strip() for x in inputs_csv.split(",") if x.strip()]


def main() -> int:
    ap = argparse.ArgumentParser(description="Merge and deduplicate VS Code Problems JSON exports.")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--inputs", help="Comma-separated list of JSON files.")
    g.add_argument("--inputs-dir", help="Directory containing JSON exports.")
    ap.add_argument("--glob", default="*.json", help="Glob pattern when using --inputs-dir. Default: *.json")
    ap.add_argument("--output", required=True, help="Output JSON path (written as a JSON list).")
    ap.add_argument("--no-dedup", action="store_true", help="Disable deduplication.")
    ap.add_argument("--quiet", action="store_true", help="Less console output.")
    args = ap.parse_args()

    if args.inputs:
        files = parse_inputs_csv(args.inputs)
    else:
        files = list_inputs_from_dir(args.inputs_dir, args.glob)

    files = [f for f in files if os.path.isfile(f)]
    if not files:
        if not args.quiet:
            print("ERROR: no input files found.", file=sys.stderr)
        return 2

    merged: List[Dict[str, Any]] = []
    read_ok = 0
    read_fail = 0

    for fp in files:
        try:
            data = read_json_file(fp)
            items = extract_items(data)
            merged.extend(items)
            read_ok += 1
        except Exception as e:
            read_fail += 1
            if not args.quiet:
                print(f"WARN: failed to read {fp}: {e}", file=sys.stderr)

    if args.no_dedup:
        uniq = merged
    else:
        seen = set()
        uniq: List[Dict[str, Any]] = []
        for d in merged:
            k = diag_key(d)
            if k in seen:
                continue
            seen.add(k)
            uniq.append(d)

    out_dir = os.path.dirname(os.path.abspath(args.output))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(uniq, f, ensure_ascii=False)

    if not args.quiet:
        print(f"OK: inputs={len(files)} read_ok={read_ok} read_fail={read_fail} "
              f"diagnostics_in={len(merged)} diagnostics_out={len(uniq)} output={args.output}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
