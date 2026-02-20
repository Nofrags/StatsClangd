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
  -r, --project-root PATH     Racine du workspace VS Code (contient compile_commands.json)      [default: pwd]
  --src-root PATH         Racine des sources contenant sou/<chunk>                          [default: <project-root>/sources]
  --sou-subdirs LIST      Liste des chunks (séparés par virgule)                            [default: base,aggreg,webservices]
  --rel-srclib PATH       Relatif au chunk, ex: srclib                                      [default: srclib]
  --rel-include PATH      Relatif au chunk, ex: include                                     [default: include]
  --settings-json PATH    Fichier settings.json remote VS Code                              [default: ~/.vscode-server/data/Machine/settings.json]
  --export-basename NAME  Nom base export côté workspace (sans .json)                       [default: project-problems]
  --out-dir PATH          Répertoire de sortie                                              [default: $SCRIPT_DIR/clangd_diagnostics_out]
  --batch-size N          Taille des lots d'ouverture                                       [default: 40]
  --batch-sleep SEC       Pause entre lots                                                  [default: 0.6]
  --poll-seconds SEC      Période de vérif taille fichier export                            [default: auto depuis settings ou 5]
  --max-cycles N          Cycles max d'attente stabilisation                                [default: 24]
  --stable-needed N       Nombre de tailles identiques consécutives                         [default: 3]
  --max-merge-input-bytes N  Taille max autorisée par fichier JSON de chunk (0 = no limit)  [default: 104857600]
  --max-merged-items N    Nombre max de diagnostics fusionnés globalement (0 = no limit)    [default: 500000]
  --merge-only            Ne faire que la fusion globale + génération CSV (pas de collecte)
  --merge-input-dir PATH  Dossier des JSON chunk déjà fusionnés (mode --merge-only)         [default: dernier dossier trouvé dans <out-dir>/exports]
  --no-compile-db-check   Ne pas vérifier compile_commands.json                             [default: 0]
  -h, --help              Aide

Exemples:
  scripts/collect_clangd_diagnostics.sh --project-root $ET_ROOT

  scripts/collect_clangd_diagnostics.sh --merge-only

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
MERGE_ONLY="0"
MERGE_INPUT_DIR=""
MAX_MERGE_INPUT_BYTES="104857600"
MAX_MERGED_ITEMS="500000"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--project-root) PROJECT_ROOT="$2"; shift 2;;
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
    --merge-only) MERGE_ONLY="1"; shift 1;;
    --merge-input-dir) MERGE_INPUT_DIR="$2"; shift 2;;
    --no-compile-db-check) CHECK_COMPILE_DB="0"; shift 1;;
    --max-merge-input-bytes) MAX_MERGE_INPUT_BYTES="$2"; shift 2;;
    --max-merged-items) MAX_MERGED_ITEMS="$2"; shift 2;;
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
if [[ "$MERGE_ONLY" != "1" ]]; then
  need code || echo "WARN: 'code' CLI non trouvé. Exécute depuis un terminal intégré VS Code (Remote)."
fi

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
COLLECTION_VERSION="$(basename "$PROJECT_ROOT")"
[[ -n "$SRC_ROOT" ]] || SRC_ROOT="sources/tpta-srv2"

[[ -n "$OUT_DIR" ]] || OUT_DIR="${SCRIPT_DIR}/../clangd_diagnostics_out"
mkdir -p "$OUT_DIR"

declare -a MERGED_CHUNK_OUTPUTS=()
EXPORT_DIR_REL=""
MERGE_EXPORT_DIR_OVERRIDE=""

if [[ "$CHECK_COMPILE_DB" == "1" && "$MERGE_ONLY" != "1" ]]; then
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
import json, os, shutil, sys
settings_path = sys.argv[1]
file_name     = sys.argv[2]
enabled       = sys.argv[3].strip().lower() in ("1","true","yes","on")

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
d = {}
existed_before = os.path.exists(settings_path)
if existed_before:
    try:
        with open(settings_path, "r", encoding="utf-8") as f:
            d = json.load(f)
    except json.JSONDecodeError as exc:
        print(f"ERROR: settings.json invalide, arrêt pour éviter un écrasement: {exc}", file=sys.stderr)
        sys.exit(2)
    except OSError as exc:
        print(f"ERROR: impossible de lire settings.json: {exc}", file=sys.stderr)
        sys.exit(2)

if existed_before:
    backup_path = settings_path + ".bak"
    if not os.path.exists(backup_path):
        try:
            shutil.copy2(settings_path, backup_path)
        except OSError as exc:
            print(f"ERROR: impossible de créer le backup {backup_path}: {exc}", file=sys.stderr)
            sys.exit(2)

d["problems-as-file.output.fileName"] = file_name
d["problems-as-file.interval.enabled"] = enabled

tmp_path = settings_path + ".tmp"
try:
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    os.replace(tmp_path, settings_path)
except OSError as exc:
    print(f"ERROR: impossible d'écrire settings.json: {exc}", file=sys.stderr)
    try:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
    except OSError:
        pass
    sys.exit(2)
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

    echo "  -> Batch: Fichers restants : $((remaining_before - current_batch_size))"
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
  local out_exports="${OUT_DIR}/exports/${day}/${COLLECTION_VERSION}"
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

  python3 "${SCRIPT_DIR}/merge_diagnostics.py" \
    --inputs "$inputs_csv" \
    --output "$merged_chunk_output" \
    >/dev/null

  echo "OK: chunk fusionné -> $merged_chunk_output"
  MERGED_CHUNK_OUTPUTS+=("$merged_chunk_output")
}

merge_jsons_and_generate_csv(){
  local day
  local version
  local export_dir
  if [[ -n "$MERGE_EXPORT_DIR_OVERRIDE" ]]; then
    export_dir="$MERGE_EXPORT_DIR_OVERRIDE"
    version="$(basename "$PROJECT_ROOT")"

    local maybe_day_dir
    maybe_day_dir="$(dirname "$export_dir")"
    if [[ "$(basename "$maybe_day_dir")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      day="$(basename "$maybe_day_dir")"
      version="$(basename "$export_dir")"
      EXPORT_DIR_REL="exports/${day}/${version}"
    else
      day="$(basename "$export_dir")"
      version="$(basename "$PROJECT_ROOT")"
      EXPORT_DIR_REL="exports/${day}/${version}"
    fi
  else
    day="$(date +%F)"
    version="$COLLECTION_VERSION"
    EXPORT_DIR_REL="exports/${day}/${version}"
    export_dir="${OUT_DIR}/${EXPORT_DIR_REL}"
  fi

  local merged_all="${export_dir}/merged-diagnostics.json"
  local reports_root="${OUT_DIR}/_reports_unused_includes"
  local report_dated_dir="${reports_root}/${day}"
  local report_latest_dir="${reports_root}/latest"
  mkdir -p "$export_dir" "$report_dated_dir" "$report_latest_dir"

  if [[ ${#MERGED_CHUNK_OUTPUTS[@]} -eq 0 ]]; then
    echo "WARN: aucun JSON chunk à fusionner."
    return 0
  fi

  python3 - "$merged_all" "$MAX_MERGE_INPUT_BYTES" "$MAX_MERGED_ITEMS" "${MERGED_CHUNK_OUTPUTS[@]}" <<'PY'
import json, os
import sys

out_path = sys.argv[1]
max_input_bytes = int(sys.argv[2])
max_items = int(sys.argv[3])
inputs = sys.argv[4:]

def extract_items(data):
    if isinstance(data, list):
        return [x for x in data if isinstance(x, dict)]
    if isinstance(data, dict):
        for k in ("problems", "diagnostics", "items", "data"):
            v = data.get(k)
            if isinstance(v, list):
                return [x for x in v if isinstance(x, dict)]
    return []

merged = []
for p in inputs:
    if max_input_bytes > 0:
        try:
            size = os.path.getsize(p)
        except OSError as exc:
            print(f"WARN: taille illisible ({p}): {exc}", file=sys.stderr)
            continue
        if size > max_input_bytes:
            print(
                f"WARN: fichier ignoré ({p}) taille={size} > limite={max_input_bytes} octets",
                file=sys.stderr,
            )
            continue

    try:
        with open(p, "r", encoding="utf-8") as f:
            chunk_items = extract_items(json.load(f))
            if max_items > 0 and len(merged) + len(chunk_items) > max_items:
                allowed = max_items - len(merged)
                if allowed > 0:
                    merged.extend(chunk_items[:allowed])
                print(
                    f"WARN: limite max diagnostics atteinte ({max_items}), fusion tronquée.",
                    file=sys.stderr,
                )
                break
            merged.extend(chunk_items)
    except Exception as exc:
        print(f"WARN: fichier ignoré ({p}): {exc}", file=sys.stderr)

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(merged, f, ensure_ascii=False, indent=2)

print(f"OK: JSON global fusionné -> {out_path}")
PY

  local report_simple="${report_dated_dir}/unused_includes_by_file.csv"
  local report_detailed="${report_dated_dir}/unused_includes_detailed.csv"

  python3 "${SCRIPT_DIR}/report_diagnostics.py" \
    --input "$merged_all" \
    --out-simple "$report_simple" \
    --out-detailed "$report_detailed" \
    --day "$day" \
    --version "$version" \
    --source "clangd" \
    --code "unused-includes"

  cp -f "$report_simple" "${report_latest_dir}/unused_includes_by_file.csv"
  cp -f "$report_detailed" "${report_latest_dir}/unused_includes_detailed.csv"
  cp -f "$merged_all" "${report_latest_dir}/merged-diagnostics.json"

  echo "OK: rapports CSV générés dans ${report_dated_dir} (copie dans latest/)"
}

load_existing_merged_chunks(){
  local input_dir="$MERGE_INPUT_DIR"

  if [[ -z "$input_dir" ]]; then
    local export_root="$OUT_DIR/exports"
    [[ -d "$export_root" ]] || die "Aucun dossier d'exports trouvé dans $export_root (utilise --merge-input-dir)."

    local -a export_dirs=()
    mapfile -t export_dirs < <(find "$export_root" -mindepth 1 -maxdepth 2 -type d | sort)

    local latest_candidate=""
    local candidate
    for candidate in "${export_dirs[@]}"; do
      local direct_day_candidate="0"
      if [[ "$(basename "$(dirname "$candidate")")" == "exports" ]]; then
        direct_day_candidate="1"
      fi

      if [[ "$direct_day_candidate" == "1" ]]; then
        continue
      fi

      for rep in "${SOU_SUBDIRS_ARRAY[@]}"; do
        local chunk_file="${candidate}/${EXPORT_BASENAME}-${rep}.json"
        if [[ -f "$chunk_file" ]]; then
          latest_candidate="$candidate"
          break
        fi
      done
    done

    [[ -n "$latest_candidate" ]] || die "Aucun dossier d'exports utilisable trouvé dans $export_root (attendu: ${EXPORT_BASENAME}-<chunk>.json)."
    input_dir="$latest_candidate"
  fi

  [[ -d "$input_dir" ]] || die "--merge-input-dir invalide: $input_dir"
  MERGE_EXPORT_DIR_OVERRIDE="$input_dir"

  local found=0
  for rep in "${SOU_SUBDIRS_ARRAY[@]}"; do
    local chunk_file="${input_dir}/${EXPORT_BASENAME}-${rep}.json"
    if [[ -f "$chunk_file" ]]; then
      MERGED_CHUNK_OUTPUTS+=("$chunk_file")
      found=1
    else
      echo "WARN: chunk absent pour fusion: $chunk_file"
    fi
  done

  [[ "$found" == "1" ]] || die "Aucun JSON chunk utilisable dans $input_dir"
  echo "Mode --merge-only: ${#MERGED_CHUNK_OUTPUTS[@]} chunk(s) détecté(s) dans $input_dir"
}

main(){
  if [[ "$MERGE_ONLY" != "1" ]]; then
    print_requirements_if_missing
  fi

  if [[ "$MERGE_ONLY" != "1" ]]; then
    cleanup_problems_as_file(){
      set_problems_as_file "${EXPORT_BASENAME}.json" "False" >/dev/null || true
    }
    trap cleanup_problems_as_file EXIT INT TERM
  fi

  if [[ "$MERGE_ONLY" != "1" && ( -z "$SRC_ROOT" || ! -d "$PROJECT_ROOT/$SRC_ROOT" ) ]]; then
    die "--src-root invalide. Donne le bon chemin (actuel: $PROJECT_ROOT/$SRC_ROOT)."
  fi

  # Conversion CSV -> tableau Bash
  IFS=',' read -r -a SOU_SUBDIRS_ARRAY <<< "$SOU_SUBDIRS"

  if [[ "$MERGE_ONLY" == "1" ]]; then
    load_existing_merged_chunks
    echo "Fusion globale des chunks (mode --merge-only)..."
    merge_jsons_and_generate_csv
    echo
    echo "Résultats disponibles dans :"
    echo "  - $OUT_DIR/_reports_unused_includes/latest/"
    echo "  - $OUT_DIR/$EXPORT_DIR_REL/"
    return 0
  fi

  local poll="$POLL_SECONDS"
  [[ -n "$poll" ]] || poll="$(get_poll_seconds)"

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

    collect_chunk_two_passes "$rep" "$poll"
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
