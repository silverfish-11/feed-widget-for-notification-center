#!/bin/bash
# Uses isolated preferences and fake timers; no accounts, network, or windows.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/feedbar-settings-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc "$project_dir/FeedBarApp/FeedSettings.swift" \
    "$project_dir/Tests/SettingsRegressionTests.swift" -o "$test_dir/settings-tests"
"$test_dir/settings-tests"
