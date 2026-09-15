#!/usr/bin/env sh
#
# Self-tests for init_snapshot_package.sh.
#
# What this does, in plain words:
#   1. Starts a tiny local HTTP server that pretends to be the package
#      registry, serving fake FHIR packages (.tgz files) that we build
#      on the fly.
#   2. Runs init_snapshot_package.sh against that fake registry for a
#      few realistic scenarios
#   3. Checks the result of each scenario (exit code + resulting files).
#   4. Prints a PASS/FAIL summary and exits non-zero if anything failed,
#      which makes the CI test step fail.
#
# No test framework is used on purpose: everything below is plain
# shell so that anyone can read it top to bottom without prior
# knowledge of a testing library.
#
# This script is executed by CI as an external test step
# (see jenkinsfiles/ci.jenkinsfile). A failing test fails the pipeline.
#
# You can also run this script directly in a local Unix-like shell
# (from the repository root):
#   sh scripts/tests/run_tests.sh


set -u

TESTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOCAL_SCRIPT_UNDER_TEST="$TESTS_DIR/../init_snapshot_package.sh"
ENTRYPOINT_SCRIPT="$TESTS_DIR/../entrypoint.sh"

if [ -z "${SCRIPT_UNDER_TEST:-}" ]; then
  SCRIPT_UNDER_TEST="$LOCAL_SCRIPT_UNDER_TEST"
fi

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "FAIL: script under test not found: $SCRIPT_UNDER_TEST"
  exit 1
fi

REGISTRY_PORT=8199
FAILED_TESTS=0

# Overrides for init_snapshot_package.sh's download retry/backoff, so that
# the "download failure" test case (which lets every retry attempt run out
# on purpose) takes a couple of seconds instead of the production default
# of up to 30 seconds.
TEST_MAX_TOTAL_SECONDS=3
TEST_MAX_DELAY=1

# -----------------------------------------------------------------------
# Tiny assertion helpers
# -----------------------------------------------------------------------

assert_equals() {
  # $1=expected $2=actual $3=description
  if [ "$1" = "$2" ]; then
    echo "  PASS: $3"
  else
    echo "  FAIL: $3 (expected '$1', got '$2')"
    FAILED_TESTS=$((FAILED_TESTS + 1))
  fi
}

assert_file_exists() {
  # $1=path $2=description
  if [ -f "$1" ]; then
    echo "  PASS: $2"
  else
    echo "  FAIL: $2 (file not found: $1)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
  fi
}

assert_not_exists() {
  # $1=path $2=description
  if [ ! -e "$1" ]; then
    echo "  PASS: $2"
  else
    echo "  FAIL: $2 (path exists: $1)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
  fi
}

assert_file_contains() {
  # $1=path $2=needle $3=description
  if grep -Fq "$2" "$1"; then
    echo "  PASS: $3"
  else
    echo "  FAIL: $3 (did not find '$2' in $1)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
  fi
}

# -----------------------------------------------------------------------
# Fake package registry
# -----------------------------------------------------------------------

# Directory tree served over HTTP; a package is a plain file at
# packages/<name>/<version>, exactly what init_snapshot_package.sh
# downloads with "wget $REGISTRY_URL/packages/<name>/<version>".
REGISTRY_DIR=""
REGISTRY_PID=""
REGISTRY_HANDLER=""

start_fake_registry_with_python() {
  REGISTRY_DIR=$(mktemp -d)
  mkdir -p "$REGISTRY_DIR/packages"
  export REGISTRY_DIR

  if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL: python3 is required to run the tests."
    exit 1
  fi

  REGISTRY_HANDLER=$(mktemp)
  cat >"$REGISTRY_HANDLER" <<-'EOF'
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

registry_dir = os.environ["REGISTRY_DIR"]
registry_port = int(os.environ["REGISTRY_PORT"])

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        rel_path = self.path.split("?", 1)[0].lstrip("/")
        file_path = os.path.join(registry_dir, rel_path)

        if os.path.isfile(file_path):
            with open(file_path, "rb") as f:
                data = f.read()

            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass

ThreadingHTTPServer(("127.0.0.1", registry_port), Handler).serve_forever()
EOF

  REGISTRY_PORT="$REGISTRY_PORT" \
    REGISTRY_DIR="$REGISTRY_DIR" \
    python3 "$REGISTRY_HANDLER" &

  REGISTRY_PID=$!
  sleep 1
}

stop_fake_registry() {
  [ -n "$REGISTRY_PID" ] && kill "$REGISTRY_PID" 2>/dev/null
  [ -n "$REGISTRY_DIR" ] && rm -rf "$REGISTRY_DIR"
  [ -n "$REGISTRY_HANDLER" ] && rm -f "$REGISTRY_HANDLER"
}
trap stop_fake_registry EXIT

# Publishes a fake package to the fake registry, so it becomes
# downloadable as packages/<name>/<version>.
#
# $1=name $2=version $3=dependencies (raw JSON object, e.g. '{"b":"1.0.0"}')
# $4=resource type used for the one FHIR resource this package contains
# (e.g. "Patient"); pass "" to publish a package with no resources.
publish_package() {
  name="$1" version="$2" dependencies="$3" resource_type="$4"
  resource_filename=""
  [ -n "$resource_type" ] && resource_filename="$resource_type-$name.json"
  publish_package_with_custom_resource "$name" "$version" "$dependencies" "$resource_type" "$resource_filename"
}

# Like publish_package, but allows forcing a custom resource filename to build
# conflict scenarios across different package names.
publish_package_with_custom_resource() {
  name="$1" version="$2" dependencies="$3" resource_type="$4" resource_filename="$5"
  build_dir=$(mktemp -d)
  pkg_dir="$build_dir/package"
  mkdir -p "$pkg_dir"

  printf '{"name":"%s","version":"%s","dependencies":%s}\n' \
    "$name" "$version" "$dependencies" >"$pkg_dir/package.json"

  if [ -n "$resource_type" ] && [ -n "$resource_filename" ]; then
    printf '{"resourceType":"%s"}\n' "$resource_type" \
      >"$pkg_dir/$resource_filename"
  fi

  mkdir -p "$REGISTRY_DIR/packages/$name"
  (cd "$build_dir" && tar -czf "$REGISTRY_DIR/packages/$name/$version" package)
  rm -rf "$build_dir"
}

# Publishes a package whose package.json is not valid JSON, to test
# how init_snapshot_package.sh reacts to a broken dependency.
publish_broken_package() {
  name="$1" version="$2"
  build_dir=$(mktemp -d)
  pkg_dir="$build_dir/package"
  mkdir -p "$pkg_dir"
  printf 'this is not valid json' >"$pkg_dir/package.json"

  mkdir -p "$REGISTRY_DIR/packages/$name"
  (cd "$build_dir" && tar -czf "$REGISTRY_DIR/packages/$name/$version" package)
  rm -rf "$build_dir"
}

# -----------------------------------------------------------------------
# Runs the script under test against the fake registry.
# $1=package name $2=package version $3=target dir
# $4=CONFIG_DEPENDENCY_LOADING_ENABLED (optional, defaults to "true")
# $5=DEPENDENCY_EXCLUSION (optional, comma-separated package names)
# $6=<DOMAIN_PREFIX>_ADDITIONAL_FHIR_PACKAGES value
#    (optional, comma-separated package@version entries)
# Sets RUN_EXIT_CODE as a side effect.
# -----------------------------------------------------------------------

run_init_script() {
  name="$1" version="$2" target_dir="$3" dependency_loading_enabled="${4:-true}" dependency_exclusion="${5:-}" additional_packages="${6:-}"
  domain="${name%%.*}"
  additional_var_name="$(printf '%s' "$domain" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')_ADDITIONAL_FHIR_PACKAGES"

  if [ -n "$additional_packages" ]; then
    env "$additional_var_name=$additional_packages" \
      PACKAGE_NAME="$name" \
      PACKAGE_VERSION="$version" \
      TARGET_DIR="$target_dir" \
      CONFIG_OPTION_PACKAGE_REGISTRY_URL="http://127.0.0.1" \
      CONFIG_OPTION_PACKAGE_REGISTRY_PORT="$REGISTRY_PORT" \
      CONFIG_DEPENDENCY_LOADING_ENABLED="$dependency_loading_enabled" \
      DEPENDENCY_EXCLUSION="$dependency_exclusion" \
      MAX_TOTAL_SECONDS="$TEST_MAX_TOTAL_SECONDS" \
      MAX_DELAY="$TEST_MAX_DELAY" \
      sh "$SCRIPT_UNDER_TEST" >"$target_dir.log" 2>&1
  else
    PACKAGE_NAME="$name" \
      PACKAGE_VERSION="$version" \
      TARGET_DIR="$target_dir" \
      CONFIG_OPTION_PACKAGE_REGISTRY_URL="http://127.0.0.1" \
      CONFIG_OPTION_PACKAGE_REGISTRY_PORT="$REGISTRY_PORT" \
      CONFIG_DEPENDENCY_LOADING_ENABLED="$dependency_loading_enabled" \
      DEPENDENCY_EXCLUSION="$dependency_exclusion" \
      MAX_TOTAL_SECONDS="$TEST_MAX_TOTAL_SECONDS" \
      MAX_DELAY="$TEST_MAX_DELAY" \
      sh "$SCRIPT_UNDER_TEST" >"$target_dir.log" 2>&1
  fi
  RUN_EXIT_CODE=$?
}

# -----------------------------------------------------------------------
# Test cases
# -----------------------------------------------------------------------

test_simple_package_without_dependencies() {
  echo "test_simple_package_without_dependencies"
  publish_package "simple" "1.0.0" "{}" "Patient"

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "simple" "1.0.0" "$target_dir"

  assert_equals 0 "$RUN_EXIT_CODE" "script succeeds"
  assert_file_exists "$version_dir/Fhir/Patient/Patient-simple.json" \
    "resource is placed in Fhir/Patient/"
  assert_file_exists "$version_dir/.data-ready" \
    "ready signal file is created"
  assert_not_exists "$version_dir/.work" \
    "temporary work directory is cleaned up"
  assert_not_exists "$version_dir/.visited" \
    "temporary loaded-package markers are cleaned up"
  assert_not_exists "$version_dir/.processed-by-name" \
    "temporary package-version map is cleaned up"
  rm -rf "$target_dir" "$target_dir.log"
}

test_shared_dependency_is_only_loaded_once() {
  # diamond: root depends on left and right, both of which depend on shared.
  echo "test_shared_dependency_is_only_loaded_once"
  publish_package "shared" "1.0.0" "{}" "Observation"
  publish_package "left" "1.0.0" '{"shared":"1.0.0"}' "Patient"
  publish_package "right" "1.0.0" '{"shared":"1.0.0"}' ""
  publish_package "root" "1.0.0" '{"left":"1.0.0","right":"1.0.0"}' ""

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "root" "1.0.0" "$target_dir"
  shared_load_count=$(grep -c 'Loading package: NAME=shared VERSION=1.0.0' "$target_dir.log")

  assert_equals 0 "$RUN_EXIT_CODE" "script succeeds"
  assert_file_exists "$version_dir/Fhir/Patient/Patient-left.json" \
    "resource from 'left' dependency is merged"
  assert_file_exists "$version_dir/Fhir/Observation/Observation-shared.json" \
    "resource from shared dependency is merged (only once, reached via two paths)"
  assert_equals 1 "$shared_load_count" \
    "shared dependency is loaded exactly once despite diamond dependency graph"
  assert_file_exists "$version_dir/.data-ready" \
    "ready signal file is created"
  assert_not_exists "$version_dir/.work" \
    "temporary work directory is cleaned up"
  assert_not_exists "$version_dir/.visited" \
    "temporary loaded-package markers are cleaned up"
  assert_not_exists "$version_dir/.processed-by-name" \
    "temporary package-version map is cleaned up"
  rm -rf "$target_dir" "$target_dir.log"
}

test_dependency_loading_disabled_skips_recursive_dependencies() {
  echo "test_dependency_loading_disabled_skips_recursive_dependencies"
  publish_package "dep" "1.0.0" "{}" "Observation"
  publish_package "root" "1.0.0" '{"dep":"1.0.0"}' "Patient"

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "root" "1.0.0" "$target_dir" "false"

  assert_equals 0 "$RUN_EXIT_CODE" "script succeeds when dependency loading is disabled"
  assert_file_exists "$version_dir/Fhir/Patient/Patient-root.json" \
    "resource from root package is merged"
  assert_not_exists "$version_dir/Fhir/Observation/Observation-dep.json" \
    "dependency resource is not merged when recursive loading is disabled"
  assert_equals 0 "$(grep -c 'Loading package: NAME=dep VERSION=1.0.0' "$target_dir.log")" \
    "dependency package is never loaded"
  assert_file_exists "$version_dir/.data-ready" \
    "ready signal file is created"
  assert_not_exists "$version_dir/.work" \
    "temporary work directory is cleaned up"
  assert_not_exists "$version_dir/.visited" \
    "temporary loaded-package markers are cleaned up"
  assert_not_exists "$version_dir/.processed-by-name" \
    "temporary package-version map is cleaned up"
  rm -rf "$target_dir" "$target_dir.log"
}

test_dependency_exclusion_skips_selected_dependencies() {
  echo "test_dependency_exclusion_skips_selected_dependencies"
  publish_package "dep-a" "1.0.0" "{}" "Observation"
  publish_package "dep-b" "1.0.0" "{}" "Condition"
  publish_package "root" "1.0.0" '{"dep-a":"1.0.0","dep-b":"1.0.0"}' "Patient"

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "root" "1.0.0" "$target_dir" "true" "dep-b"

  assert_equals 0 "$RUN_EXIT_CODE" "script succeeds with excluded dependency"
  assert_file_exists "$version_dir/Fhir/Patient/Patient-root.json" \
    "resource from root package is merged"
  assert_file_exists "$version_dir/Fhir/Observation/Observation-dep-a.json" \
    "resource from non-excluded dependency is merged"
  assert_not_exists "$version_dir/Fhir/Condition/Condition-dep-b.json" \
    "resource from excluded dependency is not merged"
  assert_file_contains "$target_dir.log" "Skipping dep-b@1.0.0." \
    "excluded dependency skip is logged"
  assert_equals 0 "$(grep -c 'Loading package: NAME=dep-b VERSION=1.0.0' "$target_dir.log")" \
    "excluded dependency package is not loaded"
  rm -rf "$target_dir" "$target_dir.log"
}

test_conflicting_versions_for_same_package_fail() {
  echo "test_conflicting_versions_for_same_package_fail"
  publish_package "shared" "1.0.0" "{}" "Observation"
  publish_package "shared" "2.0.0" "{}" "Observation"
  publish_package "left" "1.0.0" '{"shared":"1.0.0"}' "Patient"
  publish_package "right" "1.0.0" '{"shared":"2.0.0"}' "Patient"
  publish_package "root" "1.0.0" '{"left":"1.0.0","right":"1.0.0"}' ""

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "root" "1.0.0" "$target_dir"

  assert_equals 1 "$RUN_EXIT_CODE" "script fails on conflicting versions"
  assert_file_contains "$target_dir.log" "Inconsistent package versions for shared" \
    "explicit package-version conflict is logged"
  assert_not_exists "$version_dir/.data-ready" \
    "ready signal file is not created on failure"
  assert_not_exists "$version_dir/.work" \
    "temporary work directory is cleaned up on failure"
  assert_not_exists "$version_dir/.visited" \
    "temporary loaded-package markers are cleaned up on failure"
  assert_not_exists "$version_dir/.processed-by-name" \
    "temporary package-version map is cleaned up on failure"
  rm -rf "$target_dir" "$target_dir.log"
}

test_duplicate_filename_is_renamed_instead_of_overwritten() {
  echo "test_duplicate_filename_is_renamed_instead_of_overwritten"
  publish_package_with_custom_resource "left" "1.0.0" "{}" "Patient" "Patient-duplicate.json"
  publish_package_with_custom_resource "right" "1.0.0" "{}" "Patient" "Patient-duplicate.json"
  publish_package "root" "1.0.0" '{"left":"1.0.0","right":"1.0.0"}' ""

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "root" "1.0.0" "$target_dir"

  assert_equals 0 "$RUN_EXIT_CODE" \
    "script succeeds instead of failing on duplicate resource filename"
  assert_file_contains "$target_dir.log" \
    "Duplicate resource file detected: Patient-duplicate.json already exists in" \
    "duplicate conflict is logged as a warning"
  assert_file_exists "$version_dir/Fhir/Patient/Patient-duplicate.json" \
    "first package's resource keeps its original filename"
  assert_file_exists "$version_dir/Fhir/Patient/Patient-duplicate_dup1.json" \
    "second package's colliding resource is kept, renamed with a _dupN suffix"
  assert_file_exists "$version_dir/.data-ready" \
    "ready signal file is created despite the renamed duplicate"
  assert_not_exists "$version_dir/.work" \
    "temporary work directory is cleaned up"
  assert_not_exists "$version_dir/.visited" \
    "temporary loaded-package markers are cleaned up"
  assert_not_exists "$version_dir/.processed-by-name" \
    "temporary package-version map is cleaned up"
  rm -rf "$target_dir" "$target_dir.log"
}

test_circular_dependency_does_not_hang() {
  echo "test_circular_dependency_does_not_hang"
  publish_package "cycle-a" "1.0.0" '{"cycle-b":"1.0.0"}' "Patient"
  publish_package "cycle-b" "1.0.0" '{"cycle-a":"1.0.0"}' "Observation"

  target_dir=$(mktemp -d)
  run_init_script "cycle-a" "1.0.0" "$target_dir"

  assert_equals 0 "$RUN_EXIT_CODE" "script succeeds instead of hanging forever"
  assert_file_exists "$target_dir/1.0.0/Fhir/Patient/Patient-cycle-a.json" \
    "resource from cycle-a is merged"
  assert_file_exists "$target_dir/1.0.0/Fhir/Observation/Observation-cycle-b.json" \
    "resource from cycle-b is merged"
  rm -rf "$target_dir" "$target_dir.log"
}

test_missing_dependency_fails_with_download_error() {
  echo "test_missing_dependency_fails_with_download_error"
  publish_package "needs-missing" "1.0.0" '{"does-not-exist":"9.9.9"}' "Patient"

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "needs-missing" "1.0.0" "$target_dir"

  # Exit code 1 = any failure.
  assert_equals 1 "$RUN_EXIT_CODE" "script fails on download error"
  assert_not_exists "$version_dir/.data-ready" \
    "ready signal file is not created on failure"
  assert_not_exists "$version_dir/.work" \
    "temporary work directory is cleaned up on failure"
  assert_not_exists "$version_dir/.visited" \
    "temporary loaded-package markers are cleaned up on failure"
  assert_not_exists "$version_dir/.processed-by-name" \
    "temporary package-version map is cleaned up on failure"
  rm -rf "$target_dir" "$target_dir.log"
}

test_broken_package_json_fails_with_parse_error() {
  echo "test_broken_package_json_fails_with_parse_error"
  publish_broken_package "broken-json" "1.0.0"
  publish_package "needs-broken" "1.0.0" '{"broken-json":"1.0.0"}' "Patient"

  target_dir=$(mktemp -d)
  run_init_script "needs-broken" "1.0.0" "$target_dir"

  # Exit code 1 = any failure.
  assert_equals 1 "$RUN_EXIT_CODE" "script fails on broken package.json"
  rm -rf "$target_dir" "$target_dir.log"
}

test_additional_packages_are_loaded() {
  echo "test_additional_packages_are_loaded"
  publish_package "root" "1.0.0" "{}" "Patient"
  publish_package "bar" "1.2.3" "{}" "Observation"
  publish_package "kee" "2.0.0" "{}" "Condition"

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "root" "1.0.0" "$target_dir" "false" "" "bar@1.2.3,kee@2.0.0"

  assert_equals 0 "$RUN_EXIT_CODE" "script succeeds with additional packages"
  assert_file_exists "$version_dir/Fhir/Patient/Patient-root.json" \
    "resource from root package is merged"
  assert_file_exists "$version_dir/Fhir/Observation/Observation-bar.json" \
    "resource from first additional package is merged"
  assert_file_exists "$version_dir/Fhir/Condition/Condition-kee.json" \
    "resource from second additional package is merged"
  assert_file_contains "$target_dir.log" "Loading additional packages from ROOT_ADDITIONAL_FHIR_PACKAGES=bar@1.2.3,kee@2.0.0." \
    "additional package env variable usage is logged"
  rm -rf "$target_dir" "$target_dir.log"
}

test_additional_packages_with_whitespace_after_comma_are_loaded() {
  echo "test_additional_packages_with_whitespace_after_comma_are_loaded"
  publish_package "root" "1.0.0" "{}" "Patient"
  publish_package "bar" "1.2.3" "{}" "Observation"
  publish_package "kee" "2.0.0" "{}" "Condition"

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "root" "1.0.0" "$target_dir" "false" "" "bar@1.2.3,  kee@2.0.0"

  assert_equals 0 "$RUN_EXIT_CODE" \
    "script succeeds with whitespace after comma in additional packages"
  assert_file_exists "$version_dir/Fhir/Observation/Observation-bar.json" \
    "resource from first additional package is merged"
  assert_file_exists "$version_dir/Fhir/Condition/Condition-kee.json" \
    "resource from second additional package (with leading whitespace) is merged"
  rm -rf "$target_dir" "$target_dir.log"
}

test_additional_packages_are_loaded_recursively_when_enabled() {
  echo "test_additional_packages_are_loaded_recursively_when_enabled"
  publish_package "root" "1.0.0" "{}" "Patient"
  publish_package "addon" "1.0.0" '{"addon-dep":"3.0.0"}' "Observation"
  publish_package "addon-dep" "3.0.0" "{}" "Condition"

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "root" "1.0.0" "$target_dir" "true" "" "addon@1.0.0"

  assert_equals 0 "$RUN_EXIT_CODE" "script succeeds with recursive additional package loading"
  assert_file_exists "$version_dir/Fhir/Observation/Observation-addon.json" \
    "resource from additional package is merged"
  assert_file_exists "$version_dir/Fhir/Condition/Condition-addon-dep.json" \
    "resource from dependency of additional package is merged when dependency loading is enabled"
  rm -rf "$target_dir" "$target_dir.log"
}

test_additional_package_already_in_main_tree_is_not_loaded_again() {
  echo "test_additional_package_already_in_main_tree_is_not_loaded_again"
  publish_package "shared" "1.0.0" "{}" "Observation"
  publish_package "root" "1.0.0" '{"shared":"1.0.0"}' "Patient"

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "root" "1.0.0" "$target_dir" "true" "" "shared@1.0.0"
  shared_load_count=$(grep -c 'Loading package: NAME=shared VERSION=1.0.0' "$target_dir.log")

  assert_equals 0 "$RUN_EXIT_CODE" \
    "script succeeds when an additional package was already loaded via the main dependency tree"
  assert_file_exists "$version_dir/Fhir/Observation/Observation-shared.json" \
    "resource from the shared package is merged"
  assert_equals 1 "$shared_load_count" \
    "package already processed in the main tree is not loaded again as an additional package"
  rm -rf "$target_dir" "$target_dir.log"
}

test_additional_package_conflicting_version_fails() {
  echo "test_additional_package_conflicting_version_fails"
  publish_package "shared" "1.0.0" "{}" "Observation"
  publish_package "shared" "2.0.0" "{}" "Observation"
  publish_package "root" "1.0.0" '{"shared":"1.0.0"}' "Patient"

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "root" "1.0.0" "$target_dir" "true" "" "shared@2.0.0"

  assert_equals 1 "$RUN_EXIT_CODE" \
    "script fails when an additional package conflicts with a version from the main dependency tree"
  assert_file_contains "$target_dir.log" "Inconsistent package versions for shared" \
    "explicit package-version conflict against an additional package is logged"
  assert_not_exists "$version_dir/.data-ready" \
    "ready signal file is not created on failure"
  rm -rf "$target_dir" "$target_dir.log"
}

test_invalid_additional_package_format_fails() {
  echo "test_invalid_additional_package_format_fails"
  publish_package "root" "1.0.0" "{}" "Patient"

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  run_init_script "root" "1.0.0" "$target_dir" "true" "" "not-a-valid-entry"

  assert_equals 1 "$RUN_EXIT_CODE" "script fails for invalid additional package format"
  assert_file_contains "$target_dir.log" "Invalid additional package entry 'not-a-valid-entry'. Expected format <name>@<version>." \
    "invalid additional package format error is logged"
  assert_not_exists "$version_dir/.data-ready" \
    "ready signal file is not created on failure"
  rm -rf "$target_dir" "$target_dir.log"
}

test_multiple_additional_package_env_vars_fail() {
  echo "test_multiple_additional_package_env_vars_fail"
  publish_package "root" "1.0.0" "{}" "Patient"

  target_dir=$(mktemp -d)
  version_dir="$target_dir/1.0.0"
  env \
    FIRST_ADDITIONAL_FHIR_PACKAGES="bar@1.2.3" \
    SECOND_ADDITIONAL_FHIR_PACKAGES="kee@2.0.0" \
    PACKAGE_NAME="root" \
    PACKAGE_VERSION="1.0.0" \
    TARGET_DIR="$target_dir" \
    CONFIG_OPTION_PACKAGE_REGISTRY_URL="http://127.0.0.1" \
    CONFIG_OPTION_PACKAGE_REGISTRY_PORT="$REGISTRY_PORT" \
    CONFIG_DEPENDENCY_LOADING_ENABLED="true" \
    DEPENDENCY_EXCLUSION="" \
    MAX_TOTAL_SECONDS="$TEST_MAX_TOTAL_SECONDS" \
    MAX_DELAY="$TEST_MAX_DELAY" \
    sh "$SCRIPT_UNDER_TEST" >"$target_dir.log" 2>&1
  RUN_EXIT_CODE=$?

  assert_equals 1 "$RUN_EXIT_CODE" "script fails when multiple additional package env vars are set"
  assert_file_contains "$target_dir.log" "Expected only one *_ADDITIONAL_FHIR_PACKAGES env var." \
    "multiple additional package env vars are rejected"
  assert_not_exists "$version_dir/.data-ready" \
    "ready signal file is not created on failure"
  rm -rf "$target_dir" "$target_dir.log"
}

test_entrypoint_rejects_additional_packages_with_multiple_versions() {
  echo "test_entrypoint_rejects_additional_packages_with_multiple_versions"

  target_dir=$(mktemp -d)
  PACKAGE_NAME="root" \
    PACKAGE_VERSIONS="1.0.0,2.0.0" \
    TARGET_DIR="$target_dir" \
    FOO_ADDITIONAL_FHIR_PACKAGES="bar@1.2.3" \
    sh "$ENTRYPOINT_SCRIPT" >"$target_dir.log" 2>&1
  RUN_EXIT_CODE=$?

  assert_equals 1 "$RUN_EXIT_CODE" \
    "entrypoint fails when additional packages are combined with multiple PACKAGE_VERSIONS"
  assert_file_contains "$target_dir.log" \
    "<DOMAIN_PREFIX>_ADDITIONAL_FHIR_PACKAGES is not allowed when multiple PACKAGE_VERSIONS are declared." \
    "explicit rejection reason is logged"
  rm -rf "$target_dir" "$target_dir.log"
}

test_entrypoint_allows_multiple_versions_without_additional_packages() {
  echo "test_entrypoint_allows_multiple_versions_without_additional_packages"

  target_dir=$(mktemp -d)
  PACKAGE_NAME="root" \
    PACKAGE_VERSIONS="1.0.0,2.0.0" \
    TARGET_DIR="$target_dir" \
    sh "$ENTRYPOINT_SCRIPT" >"$target_dir.log" 2>&1
  RUN_EXIT_CODE=$?

  assert_equals 0 "$(grep -c '<DOMAIN_PREFIX>_ADDITIONAL_FHIR_PACKAGES is not allowed' "$target_dir.log")" \
    "multiple PACKAGE_VERSIONS without additional packages are allowed"
  rm -rf "$target_dir" "$target_dir.log"
}

test_entrypoint_allows_additional_packages_with_single_version() {
  echo "test_entrypoint_allows_additional_packages_with_single_version"

  target_dir=$(mktemp -d)
  PACKAGE_NAME="root" \
    PACKAGE_VERSIONS="1.0.0" \
    TARGET_DIR="$target_dir" \
    FOO_ADDITIONAL_FHIR_PACKAGES="bar@1.2.3" \
    sh "$ENTRYPOINT_SCRIPT" >"$target_dir.log" 2>&1
  RUN_EXIT_CODE=$?

   assert_equals 0 "$(grep -c '<DOMAIN_PREFIX>_ADDITIONAL_FHIR_PACKAGES is not allowed' "$target_dir.log")" \
    "additional packages with a single PACKAGE_VERSION are not rejected by the new rule"
  rm -rf "$target_dir" "$target_dir.log"
}

# -----------------------------------------------------------------------
# Main: run every test_* function above, then report.
# -----------------------------------------------------------------------

start_fake_registry_with_python

test_simple_package_without_dependencies
test_shared_dependency_is_only_loaded_once
test_dependency_loading_disabled_skips_recursive_dependencies
test_dependency_exclusion_skips_selected_dependencies
test_conflicting_versions_for_same_package_fail
test_duplicate_filename_is_renamed_instead_of_overwritten
test_circular_dependency_does_not_hang
test_missing_dependency_fails_with_download_error
test_broken_package_json_fails_with_parse_error
test_additional_packages_are_loaded
test_additional_packages_with_whitespace_after_comma_are_loaded
test_additional_packages_are_loaded_recursively_when_enabled
test_additional_package_already_in_main_tree_is_not_loaded_again
test_additional_package_conflicting_version_fails
test_invalid_additional_package_format_fails
test_multiple_additional_package_env_vars_fail
test_entrypoint_rejects_additional_packages_with_multiple_versions
test_entrypoint_allows_multiple_versions_without_additional_packages
test_entrypoint_allows_additional_packages_with_single_version

echo
if [ "$FAILED_TESTS" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILED_TESTS test(s) failed."
  exit 1
fi
