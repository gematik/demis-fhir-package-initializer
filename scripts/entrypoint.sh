#!/usr/bin/env sh
set -e

log() {
  echo "[fhir-package-initializer] $*"
}

run_package_init() {
  version="$1"
  package_start_time=$(date +%s)
  log "Initializing FHIR package: NAME=$PACKAGE_NAME VERSION=$version"
  if ! PACKAGE_NAME="$PACKAGE_NAME" PACKAGE_VERSION="$version" TARGET_DIR="$TARGET_DIR" /usr/local/bin/init_snapshot_package.sh; then
    log "Error initializing package: NAME=$PACKAGE_NAME VERSION=$version"
    return 1
  fi
  package_end_time=$(date +%s)
  package_duration=$((package_end_time - package_start_time))
  log "Finished FHIR package: NAME=$PACKAGE_NAME VERSION=$version in ${package_duration}s."
}

# Determine if we are in microservice mode (Java .jar argument present)
ORIGINAL_ARGS="$@"
MICROSERVICE_MODE=false
for arg in "$@"; do
  case "$arg" in
    *.jar)
      MICROSERVICE_MODE=true
      break
      ;;
  esac
done

# Always initialize packages in standalone mode
# Initialize packages in microservice mode only if the feature flag is enabled
if [ "$MICROSERVICE_MODE" = "false" ] || { [ "$MICROSERVICE_MODE" = "true" ] && [ "$FEATURE_FLAG_PACKAGE_REGISTRY_ENABLED" = "true" ]; }; then
  total_start_time=$(date +%s)
  log "Initializing FHIR packages..."
  if [ -z "$PACKAGE_NAME" ] || [ -z "$PACKAGE_VERSIONS" ]; then
    log "Error: PACKAGE_NAME and PACKAGE_VERSIONS must be set."
    exit 1
  fi

  old_ifs=$IFS
  IFS=','
  set -- $PACKAGE_VERSIONS
  IFS=$old_ifs
  version_count=$#

  if [ "$version_count" -eq 1 ]; then
    if ! run_package_init "$1"; then
      exit 1
    fi
  else
    log "Parallel initialization for $version_count FHIR packages..."
    pids=""
    for version in "$@"; do
      (
        run_package_init "$version"
      ) &
      pid=$!
      pids="${pids}${pids:+ }$pid:$version"
    done

    parallel_failed=false
    for entry in $pids; do
      pid=${entry%%:*}
      version=${entry#*:}
      if ! wait "$pid"; then
        log "Parallel initialization failed for VERSION=$version"
        parallel_failed=true
      fi
    done
    if [ "$parallel_failed" = "true" ]; then
      exit 1
    fi
  fi

  total_end_time=$(date +%s)
  total_duration=$((total_end_time - total_start_time))
  log "Finished initializing all FHIR packages in ${total_duration}s."
else
  log "Skipping FHIR package initialization."
fi

if [ "$MICROSERVICE_MODE" = "true" ]; then
  eval set -- $ORIGINAL_ARGS
  log "Microservice mode detected - starting Java application with args: $*"
  exec java "$@"
else
  log "Standalone mode - exiting after initialization"
fi
