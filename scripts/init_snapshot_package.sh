#!/usr/bin/env sh
#
# Downloads a FHIR package and optionally its dependencies (declared recursively
# in each package's package.json) from the package registry, and organizes
# all resource files into a shared Fhir/ directory, sorted by resource type.
# Dependencies are only loaded if CONFIG_DEPENDENCY_LOADING_ENABLED is set to "true".
#
# Required env vars: PACKAGE_NAME, PACKAGE_VERSION
# Optional env vars: TARGET_DIR, CONFIG_OPTION_PACKAGE_REGISTRY_URL,
#                     CONFIG_OPTION_PACKAGE_REGISTRY_PORT,
#                     CONFIG_DEPENDENCY_LOADING_ENABLED (default false),
#                     DEPENDENCY_EXCLUSION (comma-separated package names),
#                     <DOMAIN_PREFIX>_ADDITIONAL_FHIR_PACKAGES
#                     (comma-separated list in format name@version),
#                     MAX_TOTAL_SECONDS (default 30), MAX_DELAY (default 5)
#                     - used by the download retry/backoff logic
#
# Note: keyword "local" is not specified by POSIX, but is supported by BusyBox ash,
# which provides /bin/sh in the Alpine-based runtime image. We use it to keep
# variables scoped per recursive call of load_package().


# ----------------------------------------------------------------------------
# Source logging.sh
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/logging.sh"

# ---------------------------------------------------------------------------
# Package download & extraction helpers
# ---------------------------------------------------------------------------

# Downloads a single file, retrying with a short backoff until MAX_TOTAL_SECONDS
# has elapsed. $1=url $2=destination file $3=label (used in log messages).
download_with_retry() {
  local url="$1" dest_file="$2" label="$3"
  local start_time attempt now delay

  start_time=$(date +%s)
  attempt=1
  while :; do
    wget -O "$dest_file" "$url" && return 0

    now=$(date +%s)
    if [ $(( now - start_time )) -ge "$MAX_TOTAL_SECONDS" ]; then
      log error "$label could not be downloaded within ${MAX_TOTAL_SECONDS} seconds."
      return 1
    fi

    delay=$(( attempt < MAX_DELAY ? attempt : MAX_DELAY ))
    log warn "Attempt $attempt for $label failed. Retrying in ${delay} seconds..."
    attempt=$((attempt + 1))
    sleep "$delay"
  done
}

# Extracts a package tarball into a directory.
extract_tarball() {
  local tarball="$1" dest_dir="$2" label="$3"
  if ! tar -xzf "$tarball" -C "$dest_dir"; then
    log error "Could not extract $label."
    return 1
  fi
}

# Prints dependencies declared in a package to stdout, one per line:
#   <package-name> <version>
read_dependencies() {
  local package_json="$1" label="$2"
  if ! jq -r '.dependencies // {} | to_entries[] | "\(.key) \(.value)"' "$package_json"; then
    log error "Could not parse dependencies from package.json of $label."
    return 1
  fi
}

# Moves all resource files (*.json, excluding package.json) from a package's
# extracted "package/" directory into the shared Fhir directory. If a file of
# the same name already exists (duplicate resource across packages), the
# duplicate is tolerated for all resource types: the incoming file is renamed
# with a "_dupN" suffix instead of overwriting the existing one, and the
# collision is logged as a warning.
merge_resources_into_fhir_dir() {
  local src_dir="$1" file filename target base suffix candidate
  for file in "$src_dir"/*.json; do
    [ -f "$file" ] || continue
    filename=$(basename "$file")
    [ "$filename" = "package.json" ] && continue

    target="$FHIR_DIR/$filename"
    if [ -e "$target" ]; then
      base="${filename%.json}"
      suffix=1
      candidate="${base}_dup${suffix}.json"
      while [ -e "$FHIR_DIR/$candidate" ]; do
        suffix=$((suffix + 1))
        candidate="${base}_dup${suffix}.json"
      done
      log warn "Duplicate resource file detected: $filename already exists in $FHIR_DIR. Renaming incoming file to $candidate."
      target="$FHIR_DIR/$candidate"
    fi
    mv "$file" "$target" || return 1
  done
}

# ---------------------------------------------------------------------------
# Package processing state
# ---------------------------------------------------------------------------

# Stores the first encountered version for each package name,
# allowing conflicting versions to be detected.
set_processed_package_version() {
  local name="$1" version="$2"
  printf '%s\n' "$version" >"$PROCESSED_BY_NAME_DIR/$name"
}

get_processed_package_version() {
  local name="$1"
  local marker="$PROCESSED_BY_NAME_DIR/$name"
  [ -f "$marker" ] && cat "$marker"
}

is_package_visited() {
  local name="$1" version="$2"
  [ -f "$VISITED_DIR/$name@$version" ]
}

mark_package_visited() {
  local name="$1" version="$2"
  touch "$VISITED_DIR/$name@$version"
}

# ---------------------------------------------------------------------------
# Recursive package + dependency loading
# ---------------------------------------------------------------------------

is_dependency_excluded() {
  local name="$1"
  local IFS=','

  for entry in ${DEPENDENCY_EXCLUSION:-}; do
    [ "$entry" = "$name" ] && return 0
  done

  return 1
}

# Loads every "name version" pair from a newline-separated dependency list.
# Expected format for $1 (deps):
#   package-a 1.2.3
#   package-b 4.5.6
# i.e. one dependency per line, with name and version separated by whitespace.
load_dependencies() {
  local deps="$1" dep_name dep_version

  while read -r dep_name dep_version; do
    [ -n "$dep_name" ] || continue
    if is_dependency_excluded "$dep_name"; then
      log info "Dependency exclusion: Skipping $dep_name@$dep_version."
      continue
    fi
    load_package "$dep_name" "$dep_version" || return 1
  done <<EOF
$deps
EOF
}


# Finds env vars matching *_ADDITIONAL_FHIR_PACKAGES and prints the variable
# name when exactly one match exists.
resolve_additional_packages_var_name() {
  local vars count

  vars=$(env | grep '_ADDITIONAL_FHIR_PACKAGES=' | cut -d= -f1)
  [ -n "$vars" ] || return 0

  count=$(printf '%s\n' "$vars" | grep -c '.')
  [ "$count" -eq 1 ] || return 1

  printf '%s\n' "$vars"
}

# Loads additional packages from a comma-separated list:
#   package-a@1.2.3,package-b@4.5.6
load_additional_packages() {
  local additional_packages="$1" old_ifs entry additional_name additional_version

  [ -n "$additional_packages" ] || return 0

  old_ifs=$IFS
  IFS=','
  set -- $additional_packages
  IFS=$old_ifs

  for entry in "$@"; do
    # Trim leading/trailing whitespace so entries like "a@1, b@2" parse correctly.
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -n "$entry" ] || continue
    case "$entry" in
      *@*)
        additional_name=${entry%@*}
        additional_version=${entry#*@}
        if [ -z "$additional_name" ] || [ -z "$additional_version" ]; then
          log error "Invalid additional package entry '$entry'. Expected format <name>@<version>."
          return 1
        fi
        load_package "$additional_name" "$additional_version" || return 1
        ;;
      *)
        log error "Invalid additional package entry '$entry'. Expected format <name>@<version>."
        return 1
        ;;
    esac
  done
}


# Downloads, extracts and merges a single package into the shared Fhir
# directory, then recursively loads its dependencies. Already encountered packages
# are skipped.
load_package() {
  local name="$1" version="$2" label pkg_dir tarball deps url processed_version
  label="$name@$version"

  # Handle conflicting versions of the same package name.
  processed_version=$(get_processed_package_version "$name")
  if [ -n "$processed_version" ] && [ "$processed_version" != "$version" ]; then
    log error "Inconsistent package versions for $name (already processed: $processed_version, encountered: $version)."
    return 1
  fi
  [ -n "$processed_version" ] || set_processed_package_version "$name" "$version"

  # Skip packages already encountered
  is_package_visited "$name" "$version" && return 0

  mark_package_visited "$name" "$version"
  log info "Loading package: NAME=$name VERSION=$version"
  pkg_dir="$WORK_DIR/$label"
  mkdir -p "$pkg_dir" || return 1
  tarball="$pkg_dir/$label.tgz"
  url="${CONFIG_OPTION_PACKAGE_REGISTRY_URL}:${CONFIG_OPTION_PACKAGE_REGISTRY_PORT}/packages/$name/$version"

  if ! download_with_retry "$url" "$tarball" "$label"; then
    rm -rf "$pkg_dir"
    return 1
  fi

  if ! extract_tarball "$tarball" "$pkg_dir" "$label" \
    || ! deps=$(read_dependencies "$pkg_dir/package/package.json" "$label"); then
    rm -rf "$pkg_dir"
    return 1
  fi

  if ! merge_resources_into_fhir_dir "$pkg_dir/package"; then
    rm -rf "$pkg_dir"
    return 1
  fi
  rm -rf "$pkg_dir"

  if [ -n "$deps" ]; then
    if [ "$CONFIG_DEPENDENCY_LOADING_ENABLED" = "true" ]; then
      load_dependencies "$deps" || return 1
    else
      log info "Dependency loading disabled. Skipping dependencies for $label."
    fi
  fi

  return 0
}


# ---------------------------------------------------------------------------
# Organizing downloaded resources into the Fhir/ directory structure
# ---------------------------------------------------------------------------

detect_worker_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null || echo 4
  else
    echo 4
  fi
}

# Moves files named "<ResourceType>-<...>.json" into Fhir/<ResourceType>/.
organize_named_resources() {
  log info "Organizing named files into directories... (directory: $FHIR_DIR)"
  export TARGET_DIR
  find "$FHIR_DIR" -maxdepth 1 -type f -name '*.json' -print0 |
    xargs -0 -n1 -P "$WORKERS" sh -c '
      file="$1"
      filename=$(basename "$file")
      case "$filename" in
        QuestionnaireResponse-*.json)
          target_dir="$TARGET_DIR/Fhir/StructureDefinition"
          ;;
        *-*.json)
          prefix=${filename%%-*}
          target_dir="$TARGET_DIR/Fhir/$prefix"
          ;;
        *)
          exit 0
          ;;
      esac
      mkdir -p "$target_dir" || exit 4
      mv "$file" "$target_dir/$filename" || exit 4
    ' _
}

# Moves Fhir/StructureDefinition/*.json files into subdirectories based on
# their "type" field.
organize_structure_definitions_by_type() {
  local struct_def_dir="$FHIR_DIR/StructureDefinition"
  log info "Organizing StructureDefinition files by type... (directory: $struct_def_dir)"
  [ -d "$struct_def_dir" ] || return 0

  export STRUCT_DEF_DIR="$struct_def_dir"
  find "$struct_def_dir" -maxdepth 1 -type f -name '*.json' -print0 |
    xargs -0 -n1 -P "$WORKERS" sh -c '
      file="$1"
      type=$(jq -r ".type" "$file")
      [ -n "$type" ] && [ "$type" != "null" ] || exit 0
      target_dir="$STRUCT_DEF_DIR/$type"
      if ! mkdir -p "$target_dir"; then
        echo "Error: Could not create directory $target_dir." >&2
        exit 1
      fi
      mv "$file" "$target_dir/" || exit 1
    ' _
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ -z "$PACKAGE_NAME" ] || [ -z "$PACKAGE_VERSION" ]; then
  log error "PACKAGE_NAME and PACKAGE_VERSION must be set."
  exit 1
fi

TARGET_DIR="${TARGET_DIR:-/tmp/fhir-profiles}/$PACKAGE_VERSION"
CONFIG_OPTION_PACKAGE_REGISTRY_URL="${CONFIG_OPTION_PACKAGE_REGISTRY_URL:-http://package-registry.demis.svc.cluster.local}"
CONFIG_OPTION_PACKAGE_REGISTRY_PORT="${CONFIG_OPTION_PACKAGE_REGISTRY_PORT:-8080}"
CONFIG_DEPENDENCY_LOADING_ENABLED="${CONFIG_DEPENDENCY_LOADING_ENABLED:-false}"
DEPENDENCY_EXCLUSION="${DEPENDENCY_EXCLUSION:-}"
ADDITIONAL_FHIR_PACKAGES=""
if ! ADDITIONAL_PACKAGES_VAR_NAME="$(resolve_additional_packages_var_name)"; then
  log error "Expected only one *_ADDITIONAL_FHIR_PACKAGES env var."
  exit 1
fi
if [ -n "$ADDITIONAL_PACKAGES_VAR_NAME" ]; then
  eval "ADDITIONAL_FHIR_PACKAGES=\${$ADDITIONAL_PACKAGES_VAR_NAME:-}"
fi

FHIR_DIR="$TARGET_DIR/Fhir"
WORK_DIR="$TARGET_DIR/.work"
VISITED_DIR="$TARGET_DIR/.visited"
PROCESSED_BY_NAME_DIR="$TARGET_DIR/.processed-by-name"
MAX_TOTAL_SECONDS="${MAX_TOTAL_SECONDS:-30}"
MAX_DELAY="${MAX_DELAY:-5}"

if ! mkdir -p "$FHIR_DIR" "$WORK_DIR" "$VISITED_DIR" "$PROCESSED_BY_NAME_DIR"; then
  log error "Could not create required directories."
  exit 1
fi
total_start_time=$(date +%s)
if ! load_package "$PACKAGE_NAME" "$PACKAGE_VERSION"; then
  log error "Package initialization failed for $PACKAGE_NAME@$PACKAGE_VERSION."
  rm -rf "$FHIR_DIR" "$WORK_DIR" "$VISITED_DIR" "$PROCESSED_BY_NAME_DIR"
  rm -f "$TARGET_DIR/.data-ready"
  exit 1
fi

if [ -n "$ADDITIONAL_FHIR_PACKAGES" ]; then
  log info "Loading additional packages from $ADDITIONAL_PACKAGES_VAR_NAME=$ADDITIONAL_FHIR_PACKAGES."
  if ! load_additional_packages "$ADDITIONAL_FHIR_PACKAGES"; then
    log error "Package initialization failed for additional packages in $ADDITIONAL_PACKAGES_VAR_NAME."
    rm -rf "$FHIR_DIR" "$WORK_DIR" "$VISITED_DIR" "$PROCESSED_BY_NAME_DIR"
    rm -f "$TARGET_DIR/.data-ready"
    exit 1
  fi
fi

rm -rf "$WORK_DIR" "$VISITED_DIR" "$PROCESSED_BY_NAME_DIR"

if [ "$CONFIG_DEPENDENCY_LOADING_ENABLED" = "true" ]; then
  dependency_log_suffix="and all dependencies"
else
  dependency_log_suffix="(dependencies ignored)"
fi

log info "Loaded package $PACKAGE_NAME@$PACKAGE_VERSION $dependency_log_suffix in $(( $(date +%s) - total_start_time )) s."

WORKERS=$(detect_worker_count)
organize_named_resources
organize_structure_definitions_by_type

touch "$TARGET_DIR/.data-ready"
log info "Done."
