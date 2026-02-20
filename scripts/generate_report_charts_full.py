#!/usr/bin/env python3
"""Génère des graphiques PNG depuis le CSV détaillé de report_diagnostics.py.
Nécessite des libs externes: pandas, matplotlib, seaborn.
"""

import argparse
import os
import sys


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--input-csv",
        required=True,
        help="CSV détaillé (colonnes: day,version,file,line,column,code,source,message)",
    )
    ap.add_argument("--out-dir", default="charts_full", help="Dossier de sortie PNG")
    ap.add_argument("--top-n", type=int, default=20, help="Top N fichiers")
    return ap.parse_args()


def require_dependencies():
    try:
        import pandas as pd  # noqa: F401
        import matplotlib.pyplot as plt  # noqa: F401
        import seaborn as sns  # noqa: F401
    except ImportError as exc:
        print(
            "ERROR: dépendances manquantes. Installer: pandas matplotlib seaborn\n"
            f"Détail: {exc}",
            file=sys.stderr,
        )
        sys.exit(2)


def main() -> None:
    args = parse_args()
    require_dependencies()

    import pandas as pd
    import matplotlib.pyplot as plt
    import seaborn as sns

    sns.set_theme(style="whitegrid")

    if args.top_n <= 0:
        print("ERROR: --top-n doit être > 0", file=sys.stderr)
        sys.exit(2)

    os.makedirs(args.out_dir, exist_ok=True)

    df = pd.read_csv(args.input_csv, sep=";", dtype=str, keep_default_na=False)
    required = {"day", "version", "file", "code", "source", "message"}
    missing = required - set(df.columns)
    if missing:
        print(f"ERROR: colonnes manquantes dans le CSV: {sorted(missing)}", file=sys.stderr)
        sys.exit(2)

    df["day_version"] = (df["day"].str.strip() + " | " + df["version"].str.strip()).str.strip(" |")
    df.loc[df["day_version"] == "", "day_version"] = "(unknown)"

    # 1) Evolution du volume par jour/version
    evolution = df.groupby("day_version", as_index=False).size().rename(columns={"size": "count"})
    plt.figure(figsize=(12, 5))
    sns.lineplot(data=evolution, x="day_version", y="count", marker="o")
    plt.title("Volume total des diagnostics par collecte")
    plt.xlabel("Collecte (day | version)")
    plt.ylabel("Nombre de diagnostics")
    plt.xticks(rotation=45, ha="right")
    plt.tight_layout()
    plt.savefig(os.path.join(args.out_dir, "01_evolution_diagnostics.png"), dpi=150)
    plt.close()

    # 2) Top fichiers
    top_files = (
        df[df["file"].str.strip() != ""]
        .groupby("file", as_index=False)
        .size()
        .rename(columns={"size": "count"})
        .sort_values("count", ascending=False)
        .head(args.top_n)
    )
    plt.figure(figsize=(12, max(5, len(top_files) * 0.35)))
    sns.barplot(data=top_files, y="file", x="count", orient="h")
    plt.title(f"Top {args.top_n} fichiers par nombre de diagnostics")
    plt.xlabel("Nombre de diagnostics")
    plt.ylabel("Fichier")
    plt.tight_layout()
    plt.savefig(os.path.join(args.out_dir, "02_top_files.png"), dpi=150)
    plt.close()

    # 3) Répartition par code
    by_code = (
        df.assign(code=df["code"].replace("", "(empty)"))
        .groupby("code", as_index=False)
        .size()
        .rename(columns={"size": "count"})
        .sort_values("count", ascending=False)
        .head(20)
    )
    plt.figure(figsize=(12, 6))
    sns.barplot(data=by_code, x="code", y="count")
    plt.title("Top codes de diagnostics")
    plt.xlabel("Code")
    plt.ylabel("Nombre de diagnostics")
    plt.xticks(rotation=45, ha="right")
    plt.tight_layout()
    plt.savefig(os.path.join(args.out_dir, "03_codes_distribution.png"), dpi=150)
    plt.close()

    # 4) Répartition par source
    by_source = (
        df.assign(source=df["source"].replace("", "(empty)"))
        .groupby("source", as_index=False)
        .size()
        .rename(columns={"size": "count"})
        .sort_values("count", ascending=False)
    )
    plt.figure(figsize=(8, 8))
    plt.pie(by_source["count"], labels=by_source["source"], autopct="%1.1f%%", startangle=90)
    plt.title("Répartition par source")
    plt.tight_layout()
    plt.savefig(os.path.join(args.out_dir, "04_sources_pie.png"), dpi=150)
    plt.close()

    print(f"OK: graphiques générés dans {args.out_dir}")


if __name__ == "__main__":
    main()
