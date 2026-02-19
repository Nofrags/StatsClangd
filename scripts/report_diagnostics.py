#!/usr/bin/env python3
import argparse, csv, json, os, sys
from collections import Counter
from typing import Any, Dict, List, Optional, Tuple

MAX_INPUT_SIZE_BYTES = 100 * 1024 * 1024  # 100 MiB safety guard


def sanitize_csv_cell(value: Any) -> str:
    """Prevent spreadsheet formula injection when CSV is opened in office tools."""
    text = str(value) if value is not None else ""
    if text.startswith(("=", "+", "-", "@")):
        return "'" + text
    return text


def get_code(d: Dict[str, Any]) -> Optional[str]:
    code = d.get("code")
    if isinstance(code, dict):
        return code.get("value")
    if isinstance(code, str):
        return code
    return None


def get_file(d: Dict[str, Any]) -> Optional[str]:
    fp = d.get("resource") or d.get("file") or d.get("uri") or d.get("path")
    if isinstance(fp, dict):
        fp = fp.get("path") or fp.get("fsPath") or fp.get("uri")
    return str(fp) if fp else None


def get_pos(d: Dict[str, Any]) -> Tuple[Optional[int], Optional[int]]:
    def to_int_or_none(value: Any) -> Optional[int]:
        try:
            return int(value) if value is not None else None
        except (TypeError, ValueError):
            return None

    line = d.get("startLineNumber")
    col = d.get("startColumn")
    if line is not None and col is not None:
        return to_int_or_none(line), to_int_or_none(col)
    r = d.get("range", {}) if isinstance(d.get("range", {}), dict) else {}
    s = r.get("start", {}) if isinstance(r.get("start", {}), dict) else {}
    line = s.get("line")
    col = s.get("character")
    return to_int_or_none(line), to_int_or_none(col)


def extract_items(data: Any) -> List[Dict[str, Any]]:
    if isinstance(data, list):
        return [x for x in data if isinstance(x, dict)]
    if isinstance(data, dict):
        for k in ("problems", "diagnostics", "items", "data"):
            v = data.get(k)
            if isinstance(v, list):
                return [x for x in v if isinstance(x, dict)]
    return []


def is_valid_diagnostic_item(item: Dict[str, Any]) -> bool:
    source = item.get("source")
    message = item.get("message")
    return isinstance(source, str) and isinstance(message, str)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="merged-diagnostics.json")
    ap.add_argument("--out-simple", required=True, help="CSV file;count")
    ap.add_argument(
        "--out-detailed",
        required=True,
        help="CSV file;line;column;code;source;message",
    )
    ap.add_argument(
        "--source",
        default="clangd",
        help="Filter by source field (default clangd). Use '*' for no filter.",
    )
    ap.add_argument(
        "--code",
        default="",
        help="Filter by code (e.g. unused-includes). Empty = no filter.",
    )
    ap.add_argument(
        "--message-contains", default="", help="Substring filter on message."
    )
    ap.add_argument(
        "--version",
        default="",
        help="Version de collecte à ajouter dans les CSV.",
    )
    ap.add_argument(
        "--day",
        default="",
        help="Jour de collecte (YYYY-MM-DD) à ajouter dans les CSV.",
    )
    ap.add_argument(
        "--max-items",
        type=int,
        default=0,
        help="Maximum number of diagnostics to process after filtering (0 = no limit).",
    )
    args = ap.parse_args()

    try:
        input_size = os.path.getsize(args.input)
    except OSError as exc:
        print(
            f"ERROR: impossible de lire la taille du fichier d'entrée: {exc}", file=sys.stderr
        )
        sys.exit(2)

    if input_size > MAX_INPUT_SIZE_BYTES:
        print(
            f"ERROR: fichier d'entrée trop volumineux ({input_size} octets). "
            f"Limite: {MAX_INPUT_SIZE_BYTES} octets.",
            file=sys.stderr,
        )
        sys.exit(2)

    try:
        with open(args.input, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as exc:
        print(f"ERROR: JSON invalide: {exc}", file=sys.stderr)
        sys.exit(2)

    items = extract_items(data)
    valid_items = [d for d in items if is_valid_diagnostic_item(d)]
    skipped_count = len(items) - len(valid_items)
    if skipped_count:
        print(
            f"WARN: {skipped_count} diagnostic(s) ignoré(s) car format invalide (source/message).",
            file=sys.stderr,
        )

    def keep(d: Dict[str, Any]) -> bool:
        if args.source != "*":
            if d.get("source") != args.source:
                return False
        if args.code:
            if get_code(d) != args.code:
                return False
        if args.message_contains:
            if args.message_contains not in d.get("message", ""):
                return False
        return True

    filtered = [d for d in valid_items if keep(d)]

    if args.max_items < 0:
        print("ERROR: --max-items doit être >= 0", file=sys.stderr)
        sys.exit(2)
    if args.max_items > 0:
        filtered = filtered[: args.max_items]

    per_file = Counter()
    for d in filtered:
        fp = get_file(d)
        if fp:
            per_file[fp] += 1

    with open(args.out_simple, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(["day", "version", "file", "count"])
        for fp, n in per_file.most_common():
            w.writerow([sanitize_csv_cell(fp), n])

    with open(args.out_detailed, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(["day", "version", "file", "line", "column", "code", "source", "message"])
        for d in filtered:
            fp = get_file(d) or ""
            line, col = get_pos(d)
            w.writerow(
                [
                    sanitize_csv_cell(args.day),
                    sanitize_csv_cell(args.version),
                    sanitize_csv_cell(fp),
                    line if line is not None else "",
                    col if col is not None else "",
                    sanitize_csv_cell(get_code(d) or ""),
                    sanitize_csv_cell(d.get("source", "")),
                    sanitize_csv_cell(d.get("message", "")),
                ]
            )


if __name__ == "__main__":
    main()
