#!/bin/bash
# Isolated preference storage and actual widget layout; no live account access.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/feedbar-widget-preferences-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc "$project_dir"/Shared/*.swift \
    "$project_dir/FeedBarWidget/FeedTimelineProvider.swift" \
    "$project_dir/Tests/WidgetPreferencesRegressionTests.swift" -o "$test_dir/preferences-tests"
"$test_dir/preferences-tests"
