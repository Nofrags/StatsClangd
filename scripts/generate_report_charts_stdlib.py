#!/usr/bin/env python3
"""Génère des graphiques SVG + un résumé Markdown depuis le CSV détaillé.
Version sans dépendances externes (stdlib only).
"""

import argparse
import csv
import html
import os
from collections import Counter
from typing import Iterable, List, Tuple


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--input-csv",
        required=True,
        help="CSV détaillé (colonnes: day,version,file,line,column,code,source,message)",
    )
    ap.add_argument("--out-dir", default="charts_stdlib", help="Dossier de sortie")
    ap.add_argument("--top-n", type=int, default=20, help="Top N fichiers/codes")
    return ap.parse_args()


def safe_text(value: str) -> str:
    return html.escape(value if value else "")


def write_svg_bars(
    labels: List[str],
    values: List[int],
    title: str,
    output_path: str,
    width: int = 1200,
    bar_height: int = 24,
    left_margin: int = 340,
    right_margin: int = 40,
    top_margin: int = 60,
    bottom_margin: int = 40,
) -> None:
    n = len(labels)
    plot_height = max(1, n) * (bar_height + 10)
    height = top_margin + plot_height + bottom_margin
    max_value = max(values) if values else 1
    plot_width = max(200, width - left_margin - right_margin)

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">',
        '<style>text{font-family:Arial,Helvetica,sans-serif;font-size:12px;} .title{font-size:18px;font-weight:bold;}</style>',
        f'<text class="title" x="20" y="30">{safe_text(title)}</text>',
        f'<line x1="{left_margin}" y1="{top_margin-10}" x2="{left_margin}" y2="{height-bottom_margin+5}" stroke="#333"/>',
    ]

    for i, (label, value) in enumerate(zip(labels, values)):
        y = top_margin + i * (bar_height + 10)
        bar_w = int((value / max_value) * plot_width)
        lines.append(
            f'<rect x="{left_margin}" y="{y}" width="{bar_w}" height="{bar_height}" fill="#4C78A8" />'
        )
        lines.append(f'<text x="10" y="{y + bar_height - 6}">{safe_text(label)}</text>')
        lines.append(
            f'<text x="{left_margin + bar_w + 8}" y="{y + bar_height - 6}" fill="#111">{value}</text>'
        )

    lines.append("</svg>")
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def top_items(counter: Counter, top_n: int) -> List[Tuple[str, int]]:
    items = counter.most_common(top_n)
    return [(k if k else "(empty)", v) for k, v in items]


def markdown_table(items: Iterable[Tuple[str, int]], total: int) -> str:
    lines = ["| Item | Count | % |", "|---|---:|---:|"]
    for name, count in items:
        pct = (count / total * 100.0) if total else 0.0
        lines.append(f"| {name.replace('|', '/')} | {count} | {pct:.2f}% |")
    return "\n".join(lines)


def main() -> None:
    args = parse_args()
    if args.top_n <= 0:
        raise SystemExit("ERROR: --top-n doit être > 0")

    os.makedirs(args.out_dir, exist_ok=True)

    count_by_collect = Counter()
    count_by_file = Counter()
    count_by_code = Counter()
    count_by_source = Counter()

    with open(args.input_csv, "r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f, delimiter=";")
        required = {"day", "version", "file", "code", "source", "message"}
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise SystemExit(f"ERROR: colonnes manquantes dans le CSV: {sorted(missing)}")

        for row in reader:
            collect = " | ".join(part for part in [row.get("day", "").strip(), row.get("version", "").strip()] if part)
            count_by_collect[collect or "(unknown)"] += 1
            count_by_file[(row.get("file") or "").strip() or "(empty)"] += 1
            count_by_code[(row.get("code") or "").strip() or "(empty)"] += 1
            count_by_source[(row.get("source") or "").strip() or "(empty)"] += 1

    total = sum(count_by_collect.values())

    top_collect = top_items(count_by_collect, args.top_n)
    top_files = top_items(count_by_file, args.top_n)
    top_codes = top_items(count_by_code, args.top_n)
    top_sources = top_items(count_by_source, args.top_n)

    write_svg_bars(
        [k for k, _ in top_collect],
        [v for _, v in top_collect],
        "Volume des diagnostics par collecte (day | version)",
        os.path.join(args.out_dir, "01_collect_overview.svg"),
    )
    write_svg_bars(
        [k for k, _ in top_files],
        [v for _, v in top_files],
        f"Top {args.top_n} fichiers",
        os.path.join(args.out_dir, "02_top_files.svg"),
    )
    write_svg_bars(
        [k for k, _ in top_codes],
        [v for _, v in top_codes],
        f"Top {args.top_n} codes",
        os.path.join(args.out_dir, "03_top_codes.svg"),
    )
    write_svg_bars(
        [k for k, _ in top_sources],
        [v for _, v in top_sources],
        "Répartition par source",
        os.path.join(args.out_dir, "04_sources.svg"),
    )

    summary_path = os.path.join(args.out_dir, "summary.md")
    with open(summary_path, "w", encoding="utf-8") as f:
        f.write("# Diagnostic charts (stdlib)\n\n")
        f.write(f"- Total diagnostics: **{total}**\n")
        f.write(f"- Top N: **{args.top_n}**\n\n")

        f.write("## Top collectes\n\n")
        f.write(markdown_table(top_collect, total))
        f.write("\n\n## Top fichiers\n\n")
        f.write(markdown_table(top_files, total))
        f.write("\n\n## Top codes\n\n")
        f.write(markdown_table(top_codes, total))
        f.write("\n\n## Sources\n\n")
        f.write(markdown_table(top_sources, total))
        f.write("\n")

    print(f"OK: graphiques et résumé générés dans {args.out_dir}")


if __name__ == "__main__":
    main()
