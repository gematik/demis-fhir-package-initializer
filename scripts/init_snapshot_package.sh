#!/usr/bin/env sh

log() {
  echo "[fhir-package-initializer] $*"
}

# === PARAMETERS ===

# Required parameters: PACKAGE_NAME, PACKAGE_VERSION
if [ -z "$PACKAGE_NAME" ] || [ -z "$PACKAGE_VERSION" ]; then
  log "Error: PACKAGE_NAME and PACKAGE_VERSION must be set."
  exit 1
fi

# Optional parameters: TARGET_DIR, CONFIG_OPTION_PACKAGE_REGISTRY_URL, CONFIG_OPTION_PACKAGE_REGISTRY_PORT
TARGET_DIR="${TARGET_DIR:-/tmp/fhir-profiles}"
CONFIG_OPTION_PACKAGE_REGISTRY_URL="${CONFIG_OPTION_PACKAGE_REGISTRY_URL:-http://package-registry.demis.svc.cluster.local}"
CONFIG_OPTION_PACKAGE_REGISTRY_PORT="${CONFIG_OPTION_PACKAGE_REGISTRY_PORT:-8080}"

# Internal parameters: PACKAGE_FILE, DOWNLOAD_URL
PACKAGE_FILE="${PACKAGE_NAME}@${PACKAGE_VERSION}.tgz"
DOWNLOAD_URL="${CONFIG_OPTION_PACKAGE_REGISTRY_URL}:${CONFIG_OPTION_PACKAGE_REGISTRY_PORT}/packages/${PACKAGE_NAME}/${PACKAGE_VERSION}"

# === SCRIPT LOGIC ===

# Step 1: Download package tarball
mkdir -p "$TARGET_DIR/$PACKAGE_VERSION"
TARGET_DIR="$TARGET_DIR/$PACKAGE_VERSION"

max_total_seconds=30
max_delay=5

start_time=$(date +%s)
attempt=1

while :; do
  if wget -O "${TARGET_DIR}/${PACKAGE_FILE}" "$DOWNLOAD_URL"; then
    break
  fi

  # Check if max total time exceeded
  now=$(date +%s)
  elapsed=$(( now - start_time ))
  if [ "$elapsed" -ge "$max_total_seconds" ]; then
    log "Error: Package could not be downloaded within ${max_total_seconds} seconds."
    exit 2
  fi

  # Wait 1s, 2s, 3s, ..., up to 5s until max_total_seconds
  delay=$(( attempt < max_delay ? attempt : max_delay ))

  log "Attempt $attempt failed. Retrying in ${delay} seconds..."
  attempt=$((attempt + 1))
  sleep "$delay"
done

end_time=$(date +%s)
duration=$((end_time - start_time))
log "Downloaded package in ${duration} s."

# Step 2: Extract package tarball
start_time=$(date +%s)
log "Extracting package to $TARGET_DIR..."
tar -xzf "${TARGET_DIR}/${PACKAGE_FILE}" -C "$TARGET_DIR"
end_time=$(date +%s)
duration=$((end_time - start_time))
log "Extracted package in ${duration} s."

# Step 3: Organize files
log "Preparing Fhir directory... (directory: $TARGET_DIR)"
mkdir -p "$TARGET_DIR/Fhir"
mv "$TARGET_DIR"/package/*.json "$TARGET_DIR/Fhir/"
rm -rf "$TARGET_DIR"/package
rm "$TARGET_DIR"/Fhir/package.json
[ -f "$TARGET_DIR"/Fhir/.index.json ] && rm "$TARGET_DIR"/Fhir/.index.json

# Parallel processing setup
if command -v nproc >/dev/null 2>&1; then
  workers=$(nproc)
elif command -v sysctl >/dev/null 2>&1; then
  workers=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
else
  workers=4
fi

# Step 3a: Organize named files into directories
# Files named with pattern <ResourceType>-<...>.json go into directory Fhir/<ResourceType>/
log "Organizing named files into directories... (directory: $TARGET_DIR/Fhir)"
start_time=$(date +%s)
export TARGET_DIR
find "$TARGET_DIR/Fhir" -maxdepth 1 -type f -name '*.json' -print0 |
  xargs -0 -n1 -P "$workers" sh -c '
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
end_time=$(date +%s)
duration=$((end_time - start_time))
log "Organized named files in ${duration} s with ${workers} workers."

# Step 3b: Organize StructureDefinition files by type
# Files in Fhir/StructureDefinition/*.json are moved into subdirectories by their "type" field
STRUCT_DEF_DIR="$TARGET_DIR/Fhir/StructureDefinition"
log "Organizing StructureDefinition files by type... (directory: $STRUCT_DEF_DIR)"
if [ -d "$STRUCT_DEF_DIR" ]; then
  start_time=$(date +%s)
  export STRUCT_DEF_DIR
  find "$STRUCT_DEF_DIR" -maxdepth 1 -type f -name '*.json' -print0 |
    xargs -0 -n1 -P "$workers" sh -c '
      file="$1"
      type=$(jq -r ".type" "$file")
      [ -n "$type" ] && [ "$type" != "null" ] || exit 0
      target_dir="$STRUCT_DEF_DIR/$type"
      if ! mkdir -p "$target_dir"; then
        echo "Error: Could not create directory $target_dir." >&2
        exit 4
      fi
      mv "$file" "$target_dir/" || exit 4
    ' _
  end_time=$(date +%s)
  duration=$((end_time - start_time))
  log "Organized StructureDefinition files in ${duration} s with ${workers} workers."
fi

touch "$TARGET_DIR/.data-ready"
log "Done."
