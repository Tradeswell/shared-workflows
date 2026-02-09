#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <migration_dir> [ignore_list]

Lint Flyway SQL migration files for naming conventions and duplicate versions.

Arguments:
  migration_dir   Path to the directory containing .sql migration files (required)
  ignore_list     Newline-separated list of filenames to ignore (optional)
EOF
  exit 1
}

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  usage
fi

MIGRATION_DIR="$1"
IGNORE_INPUT="${2:-}"

# Parse newline-separated ignore list into an array
FILES_TO_IGNORE=()
if [[ -n "$IGNORE_INPUT" ]]; then
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
    [[ -n "$line" ]] && FILES_TO_IGNORE+=("$line")
  done <<< "$IGNORE_INPUT"
fi

is_ignored() {
  local name="$1"
  for IGN in "${FILES_TO_IGNORE[@]+"${FILES_TO_IGNORE[@]}"}"; do
    # shellcheck disable=SC2254
    if [[ "$name" == $IGN ]]; then
      return 0
    fi
  done
  return 1
}

if [[ ! -d "$MIGRATION_DIR" ]]; then
  echo "::error::Migration directory not found: $MIGRATION_DIR"
  exit 1
fi

EXIT_CODE=0

# Lifecycle callback tracking
# VALID_LIFECYCLE_ENTRIES stores "lifecycleName FILE" pairs.
# VALID_LIFECYCLE_NAMES stores unique lifecycle names seen.
VALID_LIFECYCLE_ENTRIES=()
VALID_LIFECYCLE_NAMES=()

# ---------------------------------------------------------------------------
# Valid Flyway lifecycle callback names
# https://documentation.red-gate.com/fd/callback-events-277578832.html
# ---------------------------------------------------------------------------
LIFECYCLE_NAMES=(
  beforeMigrate beforeRepeatables beforeEachMigrate beforeEachMigrateStatement
  afterEachMigrateStatement afterEachMigrateStatementError afterEachMigrate
  afterEachMigrateError afterMigrate afterMigrateApplied afterVersioned afterMigrateError
  beforeUndo beforeEachUndo beforeEachUndoStatement afterEachUndoStatement
  afterEachUndoStatementError afterEachUndo afterEachUndoError afterUndo afterUndoError
  beforeDeploy afterDeploy afterDeployError
  beforeClean afterClean afterCleanError
  beforeInfo afterInfo afterInfoError
  beforeValidate afterValidate afterValidateError
  beforeBaseline afterBaseline afterBaselineError
  beforeRepair afterRepair afterRepairError
  beforeCreateSchema beforeConnect afterConnect createSchema
)

is_lifecycle_name() {
  local name="$1"
  for lc in "${LIFECYCLE_NAMES[@]}"; do
    if [[ "$lc" = "$name" ]]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# check_duplicates — detect duplicate keys in "KEY BASENAME" entry pairs
#   $1  summary_label   e.g. "V migrations"
#   $2  dup_label        e.g. "V migration version"
#   $3  entries          newline-separated "KEY BASENAME" pairs
# Appends to DUPLICATE_ERRORS array on duplicates; prints summary on success.
# ---------------------------------------------------------------------------
check_duplicates() {
  local summary_label="$1"
  local dup_label="$2"
  local entries="$3"
  local count
  count=$(printf '%s\n' "$entries" | awk 'NF{c++} END{print c+0}')

  if [[ "$count" -eq 0 ]]; then
    return
  fi

  local dupes
  dupes=$(printf '%s\n' "$entries" | awk '{print $1}' | sort | uniq -d)

  if [[ -n "$dupes" ]]; then
    while IFS= read -r dup_key; do
      [[ -z "$dup_key" ]] && continue
      local file_list
      file_list=$(printf '%s\n' "$entries" | awk -v key="$dup_key" '$1 == key {print $2}' | paste -sd ', ' -)
      DUPLICATE_ERRORS+=("Duplicate ${dup_label} ${dup_key}: ${file_list}")
    done <<< "$dupes"
  else
    echo "${summary_label}: $count file(s), no duplicates"
  fi
}

# ---------------------------------------------------------------------------
# Scan all .sql files — detect ignored/stray files and validate naming
# V/U files: V{version}__{description}.sql  where version = digits separated
#            by single underscores and description = non-empty [A-Za-z0-9_]+
# R files:   R__{number}_{description}.sql
# Lifecycle: {lifecycleName}__{number}_{description}.sql
# ---------------------------------------------------------------------------
VU_REGEX='^[VU][0-9]+(_[0-9]+)*__[A-Za-z0-9_]+\.sql$'
R_REGEX='^R__[0-9]+_[A-Za-z0-9_]+\.sql$'

IGNORED_FILES=()
STRAY_FILES=()
INVALID_V_FILES=()
INVALID_U_FILES=()
INVALID_R_FILES=()
INVALID_LC_FILES=()

# Arrays to track files that pass naming validation (used by duplicate check)
VALID_V_FILES=()
VALID_U_FILES=()
VALID_R_FILES=()

while IFS= read -r -d '' FILE; do
  BASENAME=$(basename "$FILE")
  if is_ignored "$BASENAME"; then
    IGNORED_FILES+=("$BASENAME")
    continue
  fi
  PREFIX="${BASENAME:0:1}"

  case "$PREFIX" in
    V)
      if [[ "$BASENAME" =~ $VU_REGEX ]]; then
        VALID_V_FILES+=("$FILE")
      else
        INVALID_V_FILES+=("$BASENAME")
      fi
      ;;
    U)
      if [[ "$BASENAME" =~ $VU_REGEX ]]; then
        VALID_U_FILES+=("$FILE")
      else
        INVALID_U_FILES+=("$BASENAME")
      fi
      ;;
    R)
      if [[ "$BASENAME" =~ $R_REGEX ]]; then
        VALID_R_FILES+=("$FILE")
      else
        INVALID_R_FILES+=("$BASENAME")
      fi
      ;;
    *)
      # Check if this is a lifecycle callback file
      PREFIX_PART="${BASENAME%%__*}"
      if is_lifecycle_name "$PREFIX_PART"; then
        LC_REGEX="^${PREFIX_PART}__[0-9]+_[A-Za-z0-9_]+\.sql$"
        if [[ "$BASENAME" =~ $LC_REGEX ]]; then
          VALID_LIFECYCLE_ENTRIES+=("${PREFIX_PART} ${FILE}")
          # Track unique lifecycle names
          FOUND=0
          for EXISTING in "${VALID_LIFECYCLE_NAMES[@]+"${VALID_LIFECYCLE_NAMES[@]}"}"; do
            if [[ "$EXISTING" = "$PREFIX_PART" ]]; then
              FOUND=1
              break
            fi
          done
          if [[ "$FOUND" -eq 0 ]]; then
            VALID_LIFECYCLE_NAMES+=("$PREFIX_PART")
          fi
        else
          INVALID_LC_FILES+=("$BASENAME")
        fi
      else
        STRAY_FILES+=("$BASENAME")
      fi
      ;;
  esac
done < <(find "$MIGRATION_DIR" -type f -name "*.sql" -print0 | sort -z)



DUPLICATE_ERRORS=()
# ---------------------------------------------------------------------------
# Duplicate version check (V and U)
# Only operates on files that passed naming validation.
# ---------------------------------------------------------------------------
for PREFIX in V U; do
  if [[ "$PREFIX" = "V" ]]; then
    FILES=("${VALID_V_FILES[@]+"${VALID_V_FILES[@]}"}")
  else
    FILES=("${VALID_U_FILES[@]+"${VALID_U_FILES[@]}"}")
  fi

  ENTRIES=""
  for FILE in "${FILES[@]+"${FILES[@]}"}"; do
    [[ -z "$FILE" ]] && continue
    BASENAME=$(basename "$FILE")
    VERSION="${BASENAME#${PREFIX}}"
    VERSION="${VERSION%%__*}"
    ENTRIES="$ENTRIES$VERSION $BASENAME"$'\n'
  done

  check_duplicates "${PREFIX} migrations" "${PREFIX} migration version" "$ENTRIES"
done

# ---------------------------------------------------------------------------
# Duplicate numbering check (R — Repeatable migrations)
# Incremental internal standard to prefix the description with a number to ensure
# ordering in cases where some scripts are dependent.
# Repeatable migrations use R__{number}_{description}.sql; check for
# duplicate leading numbers.
# ---------------------------------------------------------------------------
R_ENTRIES=""
for FILE in "${VALID_R_FILES[@]+"${VALID_R_FILES[@]}"}"; do
  [[ -z "$FILE" ]] && continue
  BASENAME=$(basename "$FILE")
  NUM="${BASENAME#R__}"
  NUM="${NUM%%_*}"
  R_ENTRIES="$R_ENTRIES$NUM $BASENAME"$'\n'
done

check_duplicates "R migrations" "R migration number" "$R_ENTRIES"

# ---------------------------------------------------------------------------
# Duplicate numbering check (lifecycle callbacks)
# Incremental internal standard to prefix the description with a number to ensure
# ordering in cases where some scripts are dependent.
# Lifecycle callbacks use {name}__{number}_{description}.sql; check for
# duplicate leading numbering within each lifecycle name.
# ---------------------------------------------------------------------------
for LC_NAME in "${VALID_LIFECYCLE_NAMES[@]+"${VALID_LIFECYCLE_NAMES[@]}"}"; do
  [[ -z "$LC_NAME" ]] && continue
  LC_ENTRIES=""

  for ENTRY in "${VALID_LIFECYCLE_ENTRIES[@]}"; do
    ENTRY_NAME="${ENTRY%% *}"
    ENTRY_FILE="${ENTRY#* }"
    if [[ "$ENTRY_NAME" = "$LC_NAME" ]]; then
      BASENAME=$(basename "$ENTRY_FILE")
      NUM="${BASENAME#${LC_NAME}__}"
      NUM="${NUM%%_*}"
      LC_ENTRIES="$LC_ENTRIES$NUM $BASENAME"$'\n'
    fi
  done

  check_duplicates "${LC_NAME} callbacks" "${LC_NAME} lifecycle callback number" "$LC_ENTRIES"
done

# ---------------------------------------------------------------------------
# Output errors/warnings
# ---------------------------------------------------------------------------

if [[ "${#IGNORED_FILES[@]}" -gt 0 ]]; then
  LIST=$(printf '%s, ' "${IGNORED_FILES[@]}")
  echo "::warning::Ignoring known issues: ${LIST%, }"
fi

if [[ "${#STRAY_FILES[@]}" -gt 0 ]]; then
  LIST=$(printf '%s, ' "${STRAY_FILES[@]}")
  echo "::error::Found SQL files with invalid prefix (must start with V, U, R, or lifecycle callback name): ${LIST%, }"
  EXIT_CODE=1
fi

if [[ "${#INVALID_V_FILES[@]}" -gt 0 ]]; then
  LIST=$(printf '%s, ' "${INVALID_V_FILES[@]}")
  echo "::error::Invalid Versioned migration (expected: V{version}__{description}.sql): ${LIST%, }"
  EXIT_CODE=1
fi

if [[ "${#INVALID_U_FILES[@]}" -gt 0 ]]; then
  LIST=$(printf '%s, ' "${INVALID_U_FILES[@]}")
  echo "::error::Invalid Undo migration (expected: U{version}__{description}.sql): ${LIST%, }"
  EXIT_CODE=1
fi

if [[ "${#INVALID_R_FILES[@]}" -gt 0 ]]; then
  LIST=$(printf '%s, ' "${INVALID_R_FILES[@]}")
  echo "::error::Invalid Repeatable migration (expected: R__{number}_{description}.sql): ${LIST%, }"
  EXIT_CODE=1
fi

if [[ "${#INVALID_LC_FILES[@]}" -gt 0 ]]; then
  LIST=$(printf '%s, ' "${INVALID_LC_FILES[@]}")
  echo "::error::Invalid lifecycle callback filename (expected: {name}__{number}_{description}.sql): ${LIST%, }"
  EXIT_CODE=1
fi

for ERR in "${DUPLICATE_ERRORS[@]+"${DUPLICATE_ERRORS[@]}"}"; do
  echo "::error::${ERR}"
  EXIT_CODE=1
done

exit $EXIT_CODE
