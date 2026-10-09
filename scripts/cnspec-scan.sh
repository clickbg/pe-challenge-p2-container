#!/usr/bin/env bash
# Run cnspec against one target with the hello-mondoo policy and gate on it.
#
#   scripts/cnspec-scan.sh <cnspec scan target args...>
#
# Examples:
#   scripts/cnspec-scan.sh docker file Dockerfile
#   scripts/cnspec-scan.sh docker container <container-id>
#   scripts/cnspec-scan.sh k8s k8s/ --discover clusters
#
# Fails if any check failed, errored or was skipped, or if no check ran at all
# (a policy filter that matches nothing must not pass). If SARIF_OUT is set, a
# SARIF report is also written there.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  sed -n '2,13p' "$0" >&2
  exit 2
fi

POLICY="${POLICY:-policies/hello-mondoo.mql.yaml}"
common=(--policy-bundle "$POLICY" --incognito)
junit=$(mktemp)
trap 'rm -f "$junit"' EXIT

# 1. Human-readable report for the log. --risk-threshold is set because
#    cnspec's default (101) never fails, but on its own it isn't enough: a
#    check that errors does not lower the score.
status=0
cnspec scan "$@" "${common[@]}" --risk-threshold 50 --output full || status=$?

# 2. JUnit report, used as the strict gate. Errored checks show up as
#    <failure type="error">, checks that could not be evaluated as <skipped>.
cnspec scan "$@" "${common[@]}" --output junit --output-target "$junit" || true
count() { { grep -o "$1" "$junit" || true; } | wc -l | tr -d ' '; }
tests=$(count '<testcase')
failures=$(count '<failure')
skipped=$(count '<skipped')
echo "cnspec gate: ${tests} checks, ${failures} failed or errored, ${skipped} skipped"
if [[ "$tests" -eq 0 || "$failures" -gt 0 || "$skipped" -gt 0 ]]; then
  status=1
fi

# 3. Optional SARIF for code scanning. Report only, the gate is above.
if [[ -n "${SARIF_OUT:-}" ]]; then
  cnspec scan "$@" "${common[@]}" --output sarif --output-target "$SARIF_OUT" || true
fi

exit "$status"
