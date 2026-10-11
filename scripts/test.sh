#!/bin/bash
# Runs `swift test`, retrying when the toolchain flakes with "plugin for module 'TestingMacros' not found"
# (an intermittent build-system race with Swift Testing macros). Real test failures are not retried.
cd "$(dirname "$0")/.."
for attempt in 1 2 3 4; do
    output="$(swift test "$@" 2>&1)" && status=0 || status=$?
    if [[ $status -ne 0 ]] && grep -q "plugin for module 'TestingMacros' not found" <<<"$output"; then
        echo "TestingMacros plugin flake (attempt $attempt), retrying..." >&2
        continue
    fi
    grep -v "ld: warning" <<<"$output"
    exit $status
done
echo "Gave up after repeated TestingMacros plugin errors; try: rm -rf .build" >&2
exit 1
