#!/usr/bin/env sh

log() {
  local severity="$1"
  local msg="$2"

  jq -cn \
    --arg time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg scope "fhir-package-initializer" \
    --arg severity "$severity" \
    --arg msg "$msg" \
    '{
      "@timestamp": $time,
      scope: $scope,
      severity: $severity,
      message: $msg
    }'
}
