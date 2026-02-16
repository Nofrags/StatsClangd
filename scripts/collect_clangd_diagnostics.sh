#!/usr/bin/env bash
set -euo pipefail

# Collecte des diagnostics clangd via VS Code + extension "problems-as-file".
# Stratégie:
#  - Pour chaque chunk (ex: base, aggreg, webservices)
#    - Pass 1: ouvrir srclib -> attendre export stable -> copier en lieu sûr -> fermer éditeurs (manuel)
#    - Pass 2: relancer export -> ouvrir include -> attendre -> copier -> fermer éditeurs (manuel)
#    - Fusionner pass1+pass2 en un JSON par chunk
#  - Fusionner tous les chunks en un JSON global (merged-diagnostics.json)
#
# IMPORTANT:
#  - Le script ne peut pas piloter parfaitement l'UI VS Code en remote.
#    Il te demande donc de fermer les éditeurs manuellement entre les passes.

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Commande manquante: $1"; }

usage(){
  cat <<'USAGE'
Usage:
  scripts/collect_clangd_diagnostics.sh [options]

Options:
  --project-root PATH     Racine du workspace VS Code (contient compile_commands.json) [default: pwd]
  --src-root PATH         Racine des sources contenant sou/<chunk>                    [default: <project-root>/sources]
  --sou-subdirs LIST      Liste des chunks (séparés par virgule)                      [default: base,aggreg,webservices]
  --rel-srclib PATH       Relatif au chunk, ex: srclib                                [default: srclib]
  --rel-include PATH      Relatif au chunk, ex: include                               [default: include]
  --settings-json PATH    Fichier settings.json remote VS Code                        [default: ~/.vscode-server/data/Machine/settings.json]
  --export-basename NAME  Nom base export côté workspace (sans .json)                 [default: project-problems]
  --out-dir PATH          Répertoire de sortie                                        [default: <project-root>/clangd_diagnostics_out]
  --batch-size N          Taille des lots d'ouverture                                 [default: 40]
  --batch-sleep SEC       Pause entre lots                                            [default: 0.6]
  --poll-seconds SEC      Période de vérif taille fichier export                      [default: auto depuis settings ou 5]
  --max-cycles N          Cycles max d'attente stabilisation                          [default: 24]
  --stable-needed N       Nombre de tailles identiques consécutives                   [default: 3]
  --no-compile-db-check   Ne pas vérifier compile_commands.json
  -h, --help              Aide

Exemples:
  scripts/collect_clangd_diagnostics.sh --project-root /path/to/project

  scripts/collect_clangd_diagnostics.sh \
    --project-root . \
    --src-root ./sources/tpta-srv2 \
    --sou-subdirs base,aggreg,webservices \
    --out-dir ./_diag_out
USAGE
}

# Defaults
PROJECT_ROOT="$(pwd)"
SRC_ROOT=""                 # computed later
SOU_SUBDIRS="base,aggreg,webservices"
REL_SRCLIB="srclib"
REL_INCLUDE="include"
SETTINGS_JSON="${HOME}/.vscode-server/data/Machine/settings.json"
EXPORT_BASENAME="project-problems"   # on ajoute -<chunk> etc.
OUT_DIR=""                  # computed later
BATCH_SIZE="40"
BATCH_SLEEP="0.6"
POLL_SECONDS_DEFAULT="5"
POLL_SECONDS=""             # computed later
MAX_CYCLES="24"
STABLE_NEEDED="3"
CHECK_COMPILE_DB="1"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2;;
    --src-root) SRC_ROOT="$2"; shift 2;;
    --sou-subdirs) SOU_SUBDIRS="$2"; shift 2;;
    --rel-srclib) REL_SRCLIB="$2"; shift 2;;
    --rel-include) REL_INCLUDE="$2"; shift 2;;
    --settings-json) SETTINGS_JSON="$2"; shift 2;;
    --export-basename) EXPORT_BASENAME="$2"; shift 2;;
    --out-dir) OUT_DIR="$2"; shift 2;;
    --batch-size) BATCH_SIZE="$2"; shift 2;;
    --batch-sleep) BATCH_SLEEP="$2"; shift 2;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2;;
    --max-cycles) MAX_CYCLES="$2"; shift 2;;
    --stable-needed) STABLE_NEEDED="$2"; shift 2;;
    --no-compile-db-check) CHECK_COMPILE_DB="0"; shift 1;;
    -h|--help) usage; exit 0;;
    *) die "Option inconnue: $1";;
  esac
done

# Tools
need python3
need stat
need find
need mkdir
need cp
need date
need code || echo "WARN: 'code' CLI non trouvé. Exécute depuis un terminal intégré VS Code (Remote)."

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
[[ -n "$SRC_ROOT" ]] || SRC_ROOT="${PROJECT_ROOT}/sources"
SRC_ROOT="$(cd "$SRC_ROOT" 2>/dev/null && pwd || true)"

[[ -n "$OUT_DIR" ]] || OUT_DIR="${PROJECT_ROOT}/clangd_diagnostics_out"
mkdir -p "$OUT_DIR"

if [[ "$CHECK_COMPILE_DB" == "1" ]]; then
  [[ -f "${PROJECT_ROOT}/compile_commands.json" ]] || die "compile_commands.json absent dans --project-root=$PROJECT_ROOT"
fi

get_setting_value_py='
import json,sys
p=sys.argv[1]
key=sys.argv[2]
try:
  with open(p,"r",encoding="utf-8") as f:
    d=json.load(f)
except Exception:
  d={}
v=d.get(key)
if v is None:
  sys.exit(3)
print(v)
'

get_poll_seconds(){
  local v
  if v="$(python3 -c "$get_setting_value_py" "$SETTINGS_JSON" "problems-as-file.interval.seconds" 2>/dev/null)"; then
    echo "$v" | sed 's/"//g'
  else
    echo "$POLL_SECONDS_DEFAULT"
  fi
}

# configure problems-as-file:
# NOTE: d["problems-as-file.output.fileName"] doit être le *nom* (pas le chemin) si l'extension écrit dans le workspace root.
set_problems_as_file(){
  local file_name="$1"   # ex: project-problems-base.json
  local enabled="$2"     # True/False

  python3 - "$SETTINGS_JSON" "$file_name" "$enabled" <<'PY'
import json, os, sys
settings_path = sys.argv[1]
file_name     = sys.argv[2]
enabled       = sys.argv[3].strip().lower() in ("1","true","yes","on")

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
try:
    with open(settings_path, "r", encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {}

d["problems-as-file.output.fileName"] = file_name
d["problems-as-file.interval.enabled"] = enabled

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
}

open_files_in_dir(){
  local dir="$1"
  local batch_size="${2:-40}"
  local batch_sleep="${3:-0.6}"

  mapfile -t files < <(find "$dir" -type f \( -name "*.c" -o -name "*.h" \) | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "WARN: Aucun .c/.h trouvé dans $dir"
    return 0
  fi

  echo "Ouverture de ${#files[@]} fichiers dans $dir (batch_size=$batch_size, sleep=${batch_sleep}s)"

  local i=0
  while [[ $i -lt ${#files[@]} ]]; do
    local -a lot=("${files[@]:i:batch_size}")
    code -r "${lot[@]}" >/dev/null 2>&1 || true
    i=$((i + batch_size))
    sleep "$batch_sleep"
  done
}

wait_file_stable(){
  local f="$1"
  local poll="$2"
  local max_cycles="$3"
  local stable_needed="$4"

  local last_size="-1"
  local stable_count=0

  echo "Attente stabilisation: $f (poll=${poll}s, max=${max_cycles}, stable=${stable_needed})"
  for ((i=1;i<=max_cycles;i++)); do
    if [[ -f "$f" ]]; then
      local sz
      sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
      if [[ "$sz" == "$last_size" ]]; then
        stable_count=$((stable_count+1))
      else
        stable_count=0
      fi
      last_size="$sz"
      echo "  cycle $i/$max_cycles : size=$sz bytes, stable_count=$stable_count"
      if [[ "$stable_count" -ge "$stable_needed" ]]; then
        echo "OK: fichier stable."
        return 0
      fi
    else
      echo "  cycle $i/$max_cycles : fichier pas encore créé"
    fi
    sleep "$poll"
  done

  echo "WARN: stabilisation non confirmée après $max_cycles cycles."
  return 0
}

prompt_close_editors(){
  echo
  echo "=============================================================="
  echo "ACTION MANUELLE: Fermer les éditeurs ouverts dans VS Code"
  echo "  Ctrl + Shift + P"
  echo "  Commande : View: Close Editor (répéter si nécessaire)"
  echo "Puis appuyez sur une touche ici pour continuer..."
  echo "=============================================================="
  read -n 1 -s -r -p "Appuyez sur une touche pour continuer..."
  echo
}

copy_export(){
  local src_file="$1"   # workspace root file
  local dst_file="$2"   # safe output
  mkdir -p "$(dirname "$dst_file")"
  [[ -f "$src_file" ]] || { echo "WARN: export introuvable: $src_file"; return 1; }
  cp -f "$src_file" "$dst_file"
  echo "Copié -> $dst_file"
}

collect_chunk_two_passes(){
  local chunk="$1"
  local poll="$2"

  local chunk_root="${SRC_ROOT}/sou/${chunk}"
  local srclib="${chunk_root}/${REL_SRCLIB}"
  local include="${chunk_root}/${REL_INCLUDE}"

  [[ -d "$chunk_root" ]] || { echo "WARN: chunk absent: $chunk_root (skip)"; return 0; }

  local day
  day="$(date +%F)"
  local out_exports="${OUT_DIR}/exports/${day}"
  mkdir -p "$out_exports"

  # PASS 1: srclib
  local export_name="${EXPORT_BASENAME}-${chunk}.json"       # file name in workspace root
  local export_file="${PROJECT_ROOT}/${export_name}"         # actual location (workspace root)
  echo "=== Chunk: $chunk | PASS 1/2: ${REL_SRCLIB}"

  set_problems_as_file "$export_name" "True"
  rm -f "$export_file"

  if [[ -d "$srclib" ]]; then
    open_files_in_dir "$srclib" "$BATCH_SIZE" "$BATCH_SLEEP"
  else
    echo "WARN: srclib absent: $srclib"
  fi

  wait_file_stable "$export_file" "$poll" "$MAX_CYCLES" "$STABLE_NEEDED"

  local dst1="${out_exports}/${EXPORT_BASENAME}-${chunk}-${REL_SRCLIB}.json"
  copy_export "$export_file" "$dst1" || true
  prompt_close_editors

  # PASS 2: include (relancer export)
  echo "=== Chunk: $chunk | PASS 2/2: ${REL_INCLUDE}"
  set_problems_as_file "$export_name" "True"
  rm -f "$export_file"

  if [[ -d "$include" ]]; then
    open_files_in_dir "$include" "$BATCH_SIZE" "$BATCH_SLEEP"
  else
    echo "WARN: include absent: $include"
  fi

  wait_file_stable "$export_file" "$poll" "$MAX_CYCLES" "$STABLE_NEEDED"

  local dst2="${out_exports}/${EXPORT_BASENAME}-${chunk}-${REL_INCLUDE}.json"
  copy_export "$export_file" "$dst2" || true
  prompt_close_editors

  # Fusion PASS1 + PASS2 -> un fichier chunk unique
  python3 scripts/merge_diagnostics.py \
    --inputs "$dst1,$dst2" \
    --output "${out_exports}/${EXPORT_BASENAME}-${chunk}.json" \
    >/dev/null

  echo "OK: chunk fusionné -> ${out_exports}/${EXPORT_BASENAME}-${chunk}.json"
}

print_requirements(){
  echo "=============================================================="
  echo " PREREQUIS AVANT LANCEMENT DE LA COLLECTE"
  echo "=============================================================="
  echo
  echo "Extensions VS Code nécessaires (en Remote) :"
  echo "  - clangd  (llvm-vs-code-extensions.vscode-clangd)"
  echo "  - problems-as-file (nom exact variable selon marketplace)"
  echo
  echo "Commandes d'installation (si autorisé) :"
  echo "  code --install-extension llvm-vs-code-extensions.vscode-clangd"
  echo "  code --install-extension problems-as-file"
  echo
  echo "Contrôle des extensions installées :"
  if code --list-extensions 2>/dev/null | grep -q "llvm-vs-code-extensions.vscode-clangd"; then
    echo "  OK   clangd (llvm-vs-code-extensions.vscode-clangd)"
  else
    echo "  WARN clangd non détecté : llvm-vs-code-extensions.vscode-clangd"
  fi
  if code --list-extensions 2>/dev/null | grep -qi "problems-as-file"; then
    echo "  OK   problems-as-file (détecté via grep)"
  else
    echo "  WARN problems-as-file non détecté (grep problems-as-file)"
  fi
  echo
  echo "NOTE: ce script collecte TOUS les diagnostics clangd (pas de filtre)."
  echo "      On générera ensuite des rapports filtrés (ex: unused-includes)."
  echo
  echo "Appuyez sur ENTREE pour démarrer la collecte..."
  echo "=============================================================="
  read -r
}

main(){
  print_requirements

  if [[ -z "$SRC_ROOT" || ! -d "$SRC_ROOT" ]]; then
    die "--src-root invalide. Donne le bon chemin (actuel: $SRC_ROOT)."
  fi

  local poll="$POLL_SECONDS"
  [[ -n "$poll" ]] || poll="$(get_poll_seconds)"

  echo "PROJECT_ROOT=$PROJECT_ROOT"
  echo "SRC_ROOT=$SRC_ROOT"
  echo "SETTINGS_JSON=$SETTINGS_JSON"
  echo "OUT_DIR=$OUT_DIR"
  echo "SOU_SUBDIRS=$SOU_SUBDIRS"
  echo "POLL_SECONDS=$poll"
  echo "MAX_CYCLES=$MAX_CYCLES / STABLE_NEEDED=$STABLE_NEEDED"
  echo

  local day
  day="$(date +%F)"
  local out_exports="${OUT_DIR}/exports/${day}"
  mkdir -p "$out_exports"

  IFS=',' read -r -a chunks <<< "$SOU_SUBDIRS"

  for chunk in "${chunks[@]}"; do
    collect_chunk_two_passes "$chunk" "$poll"
    echo
  done

  # Remettre config par défaut (désactive interval)
  set_problems_as_file "${EXPORT_BASENAME}.json" "False" >/dev/null || true

  # Fusion globale de tous les chunks (un JSON global)
  local inputs=""
  for chunk in "${chunks[@]}"; do
    f="${out_exports}/${EXPORT_BASENAME}-${chunk}.json"
    [[ -f "$f" ]] || continue
    inputs="${inputs}${inputs:+,}${f}"
  done

  if [[ -z "$inputs" ]]; then
    die "Aucun export chunk trouvé dans $out_exports"
  fi

  python3 scripts/merge_diagnostics.py \
    --inputs "$inputs" \
    --output "${OUT_DIR}/merged-diagnostics-${day}.json" \
    >/dev/null

  ln -sfn "${OUT_DIR}/merged-diagnostics-${day}.json" "${OUT_DIR}/merged-diagnostics-latest.json"

  echo "=============================================================="
  echo "OK: Fusion globale terminée"
  echo "  - ${OUT_DIR}/merged-diagnostics-${day}.json"
  echo "  - ${OUT_DIR}/merged-diagnostics-latest.json (symlink)"
  echo "=============================================================="
}

main "$@"
