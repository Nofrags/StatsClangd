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

SOURCE_SCRIPT="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_SCRIPT" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE_SCRIPT")" && pwd)"
  SOURCE_SCRIPT="$(readlink "$SOURCE_SCRIPT")"
  [[ $SOURCE_SCRIPT != /* ]] && SOURCE_SCRIPT="$DIR/$SOURCE_SCRIPT"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE_SCRIPT")" && pwd)"

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
  --no-compile-db-check   Ne pas vérifier compile_commands.json                       [default: 0]
  -h, --help              Aide

Exemples:
  scripts/collect_clangd_diagnostics.sh --project-root /path/to/project

  scripts/collect_clangd_diagnostics.sh \
    --project-root . \
    --src-root ./sources/projet1 \
    --sou-subdirs base,aggreg,webservices \
    --out-dir ./_diag_out
USAGE
}

# Defaults
PROJECT_ROOT="$(pwd)"
SRC_ROOT=""                 # computed later
#SOU_SUBDIRS=("base" "aggreg" "webservices")
SOU_SUBDIRS="${SOU_SUBDIRS:-base,aggreg,webservices}"
REL_SRCLIB="srclib"
REL_INCLUDE="include"
SETTINGS_JSON="${HOME}/.vscode-server/data/Machine/settings.json"
EXPORT_BASENAME="project-problems"   # on ajoute -<chunk> etc.
OUT_DIR=""                  # computed later
BATCH_SIZE="1"
BATCH_SLEEP="0.5"
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
    *) usage; echo ; die "Option inconnue: $1";;
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
[[ -n "$SRC_ROOT" ]] || SRC_ROOT="sources/tpta-srv2"

[[ -n "$OUT_DIR" ]] || OUT_DIR="${PWD}/clangd_diagnostics_out"
mkdir -p "$OUT_DIR"

if [[ "$CHECK_COMPILE_DB" == "1" ]]; then
  [[ -f "${PROJECT_ROOT}/compile_commands.json" ]] || die "compile_commands.json absent dans $PROJECT_ROOT"
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

has_extension(){
  local needle="$1"
  code --list-extensions 2>/dev/null | grep -qi -- "$needle"
}

check_prereqs(){
  local missing=0

  # commandes
  command -v python3 >/dev/null 2>&1 || { echo "MANQUE: python3"; missing=1; }
  command -v stat   >/dev/null 2>&1 || { echo "MANQUE: stat"; missing=1; }
  command -v find   >/dev/null 2>&1 || { echo "MANQUE: find"; missing=1; }
  command -v code   >/dev/null 2>&1 || { echo "MANQUE: code (CLI VS Code)"; missing=1; }

  # compile_commands.json
  if [[ ! -f "$PROJECT_ROOT/compile_commands.json" ]]; then
    echo "MANQUE: $PROJECT_ROOT/compile_commands.json"
    missing=1
  fi

  # extensions VS Code (si code est dispo)
  if command -v code >/dev/null 2>&1; then
    has_extension "llvm-vs-code-extensions.vscode-clangd" || { echo "MANQUE: extension clangd (llvm-vs-code-extensions.vscode-clangd)"; missing=1; }
    has_extension "problems-as-file" || { echo "MANQUE: extension problems-as-file (recherche 'problems-as-file')"; missing=1; }
  fi

  return "$missing"
}

print_requirements_if_missing(){
  if check_prereqs; then
    # OK, rien ne manque => pas de cartouche
    return 0
  fi

  echo
  echo "=============================================================="
  echo " PREREQUIS MANQUANTS - ACTION REQUISE"
  echo "=============================================================="
  echo
  echo "Extensions VS Code nécessaires (en Remote) :"
  echo "  - clangd  (llvm-vs-code-extensions.vscode-clangd)"
  echo "  - problems-as-file"
  echo
  echo "Commandes d'installation (si autorisé) :"
  echo "  code --install-extension llvm-vs-code-extensions.vscode-clangd"
  echo "  code --install-extension problems-as-file"
  echo
  echo "Vérifiez aussi :"
  echo "  - compile_commands.json présent dans ET_ROOT"
  echo "  - exécution depuis un terminal VS Code Remote (CLI 'code' dispo)"
  echo
  echo "Corrigez les prérequis puis relancez le script."
  echo "=============================================================="
  exit 1
}

print_chunks_summary(){
  echo "=============================================================="
  echo " RESUME AVANT COLLECTE"
  echo "=============================================================="
  echo "PROJECT_ROOT  : $PROJECT_ROOT"
  echo "SRC_ROOT      : $PROJECT_ROOT/$SRC_ROOT"
  echo "OUT_DIR       : $OUT_DIR"
  echo "SETTINGS_JSON : $SETTINGS_JSON"
  echo
  echo "Chunks (sou/<chunk>) et sous-dossiers attendus : srclib + include"
  echo

  local isAllDirIsPresent=1

  for rep in "${SOU_SUBDIRS_ARRAY[@]}"; do
    local base="$PROJECT_ROOT/$SRC_ROOT/sou/$rep"
    local srclib="$base/srclib"
    local include="$base/include"

    local st_base="MISSING"
    local st_srclib="MISSING"
    local st_inc="MISSING"

    [[ -d "$base" ]] && st_base="OK" || isAllDirIsPresent=0
    [[ -d "$srclib" ]] && st_srclib="OK" || isAllDirIsPresent=0
    [[ -d "$include" ]] && st_inc="OK" || isAllDirIsPresent=0

    printf " - %-25s rep:%-7s  srclib:%-7s  include:%-7s\n" "$rep" "$st_base" "$st_srclib" "$st_inc"
  done

  if [[ -f "${SCRIPT_DIR}/merge_diagnostics.py" ]]; then
    printf " - %-25s script:OK\n" "merge_diagnostics.py"
  else
    echo 'Fichier de merge merge_diagnostics.py indisponible dans ${SCRIPT_DIR}.'
    isAllDirIsPresent=0
  fi 

  [[ $isAllDirIsPresent -eq 0 ]] && die "Au moins nécéssaire n'est pas présent."

  echo "=============================================================="
  echo
}


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
  local batch_size="${2:-1}"
  local batch_sleep="${3:-0.5}"

  mapfile -t files < <(find "$dir" -type f \( -name "*.c" -o -name "*.h" \) | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "WARN: Aucun .c/.h trouvé dans $dir"
    return 0
  fi

  echo "Ouverture de ${#files[@]} fichiers dans $dir (batch_size=$batch_size, sleep=${batch_sleep}s)"

  local total="${#files[@]}"
  local i=0
  while [[ $i -lt $total ]]; do
    local remaining_before=$((total - i))
    local current_batch_size="$batch_size"
    if (( remaining_before < current_batch_size )); then
      current_batch_size="$remaining_before"
    fi

    echo "  -> Batch: ouverture de ${current_batch_size} fichier(s), restant après batch: $((remaining_before - current_batch_size))"
    local -a lot=("${files[@]:i:current_batch_size}")
    code -r "${lot[@]}" >/dev/null 2>&1 || true
    i=$((i + current_batch_size))
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
  echo "  Commande : View: Close All Editors"
  echo "=============================================================="
  echo
  read -n 1 -s -r -p "Appuyez sur une touche pour continuer..."
  echo
}

move_export(){
  local src_file="$1"   # workspace root file
  local dst_file="$2"   # safe output
  mkdir -p "$(dirname "$dst_file")"
  [[ -f "$src_file" ]] || { echo "WARN: export introuvable: $src_file"; return 1; }
  mv -f "$src_file" "$dst_file"
  echo "Déplacé $src_file -> $dst_file"
}

collect_chunk_two_passes(){
  local chunk="$1"
  local poll="$2"

  local chunk_root="${PROJECT_ROOT}/${SRC_ROOT}/sou/${chunk}"
  [[ -d "$chunk_root" ]] || die "chunk absent pendant la collecte: $chunk_root"

  local day
  day="$(date +%F)"
  local out_exports="${OUT_DIR}/exports/${day}"
  mkdir -p "$out_exports"

  local export_name="${EXPORT_BASENAME}-${chunk}"           # file name in workspace root
  local export_file="${PROJECT_ROOT}/${export_name}.json"   # actual location (workspace root)
  local merged_chunk_output="${out_exports}/${EXPORT_BASENAME}-${chunk}.json"

  local -a pass_dirs=("$REL_SRCLIB" "$REL_INCLUDE")
  local -a pass_outputs=()

  run_chunk_pass(){
    local pass_index="$1"
    local rel_dir="$2"
    local target_dir="${chunk_root}/${rel_dir}"
    local dst="${out_exports}/${EXPORT_BASENAME}-${chunk}-${rel_dir}.json"

    echo "=== Chunk: $chunk | PASS ${pass_index}/2: ${rel_dir}"

    set_problems_as_file "$export_name" "True"
    rm -f "$export_file"

    [[ -d "$target_dir" ]] || die "répertoire obligatoire absent pendant la collecte: $target_dir"
    open_files_in_dir "$target_dir" "$BATCH_SIZE" "$BATCH_SLEEP"

    wait_file_stable "$export_file" "$poll" "$MAX_CYCLES" "$STABLE_NEEDED"

    set_problems_as_file "$export_name" "false"

    if move_export "$export_file" "$dst"; then
      pass_outputs+=("$dst")
    fi

    prompt_close_editors
  }

  run_chunk_pass 1 "${pass_dirs[0]}"
  run_chunk_pass 2 "${pass_dirs[1]}"


  if [[ ${#pass_outputs[@]} -eq 0 ]]; then
    echo "WARN: aucun export valide pour chunk=$chunk (fusion ignorée)"
    return 0
  fi

  local inputs_csv
  inputs_csv="$(IFS=,; echo "${pass_outputs[*]}")"

  python3 ${SCRIPT_DIR}/merge_diagnostics.py \
    --inputs "$inputs_csv" \
    --output "$merged_chunk_output" \
    >/dev/null

  echo "OK: chunk fusionné -> $merged_chunk_output"
}

main(){
  print_requirements_if_missing

  cleanup_problems_as_file(){
    set_problems_as_file "${EXPORT_BASENAME}.json" "False" >/dev/null || true
  }
  trap cleanup_problems_as_file EXIT INT TERM

  if [[ -z "$SRC_ROOT" || ! -d "$PROJECT_ROOT/$SRC_ROOT" ]]; then
    die "--src-root invalide. Donne le bon chemin (actuel: $PROJECT_ROOT/$SRC_ROOT)."
  fi

  local poll="$POLL_SECONDS"
  [[ -n "$poll" ]] || poll="$(get_poll_seconds)"

  # Conversion CSV -> tableau Bash
  IFS=',' read -r -a SOU_SUBDIRS_ARRAY <<< "$SOU_SUBDIRS"

  # --- Résumé configuration ---
  print_chunks_summary

  echo "Configuration runtime :"
  echo "  POLL_SECONDS  = $poll"
  echo "  NB_ATTENTE    = $MAX_CYCLES"
  echo "  NB_STABLE     = $STABLE_NEEDED"
  echo "  BATCH_SIZE    = $BATCH_SIZE"
  echo "  BATCH_SLEEP   = $BATCH_SLEEP"
  echo "=============================================================="
  echo
  read -n 1 -s -r -p "Appuyez sur une touche pour continuer... (q pour quitter)" caractere
  echo

  if [[ "$caractere" = "q" ]]; then
    exit 0
  fi

  # --- Collecte ---
  for rep in "${SOU_SUBDIRS_ARRAY[@]}"; do
    echo "=============================================================="
    echo "=== Chunk: $rep"
    echo "=============================================================="

    collect_chunk_two_passes "$rep" $BATCH_SIZE $BATCH_SLEEP
    echo
  done

  # --- Fusion globale ---
  echo
  echo "Fusion globale des chunks..."
  merge_jsons_and_generate_csv

  echo
  echo "=============================================================="
  echo " COLLECTE TERMINEE"
  echo "=============================================================="
  echo
  echo "Résultats disponibles dans :"
  echo "  - $OUT_DIR/_reports_unused_includes/latest/"
  echo "  - $OUT_DIR/$EXPORT_DIR_REL/"
  echo
}


main "$@"
