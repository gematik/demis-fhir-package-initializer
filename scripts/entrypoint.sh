#!/usr/bin/env sh
set -e

# Source logging.sh for log() function
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/logging.sh"

run_package_init() {
  version="$1"
  package_start_time=$(date +%s)
  log "info" "Initializing FHIR package: NAME=$PACKAGE_NAME VERSION=$version, dependencies loading: ${CONFIG_DEPENDENCY_LOADING_ENABLED:-false}"
  if ! PACKAGE_NAME="$PACKAGE_NAME" PACKAGE_VERSION="$version" TARGET_DIR="$TARGET_DIR" /usr/local/bin/init_snapshot_package.sh; then
    log error "Error initializing package: NAME=$PACKAGE_NAME VERSION=$version"
    return 1
  fi
  package_end_time=$(date +%s)
  package_duration=$((package_end_time - package_start_time))
  log info "Finished FHIR package: NAME=$PACKAGE_NAME VERSION=$version in ${package_duration}s."
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

if [ -n "$PACKAGE_NAME" ]; then
  # initialize packages
  total_start_time=$(date +%s)
  log info "Initializing FHIR packages..."
  if [ -z "$PACKAGE_VERSIONS" ]; then
    log error "PACKAGE_NAME and PACKAGE_VERSIONS must be set."
    exit 1
  fi

  old_ifs=$IFS
  IFS=','
  set -- $PACKAGE_VERSIONS
  IFS=$old_ifs
  version_count=$#

  if [ "$version_count" -gt 1 ] && env | grep -q '_ADDITIONAL_FHIR_PACKAGES='; then
    log error "<DOMAIN_PREFIX>_ADDITIONAL_FHIR_PACKAGES is not allowed when multiple PACKAGE_VERSIONS are declared."
    exit 1
  fi

  if [ "$version_count" -eq 1 ]; then
    if ! run_package_init "$1"; then
      exit 1
    fi
  else
    log info "Parallel initialization for $version_count FHIR packages..."
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
        log error "Parallel initialization failed for VERSION=$version"
        parallel_failed=true
      fi
    done
    if [ "$parallel_failed" = "true" ]; then
      exit 1
    fi
  fi

  total_end_time=$(date +%s)
  total_duration=$((total_end_time - total_start_time))
  log info "Finished initializing all FHIR packages in ${total_duration}s."
else
  log warn "Skipping FHIR package initialization. Parameter PACKAGE_NAME missing."
fi

if [ "$MICROSERVICE_MODE" = "true" ]; then
  eval set -- $ORIGINAL_ARGS
  log info "Microservice mode detected - starting Java application with args: $*"
  exec java "$@"
else
  log info "Standalone mode - exiting after initialization"
fi
