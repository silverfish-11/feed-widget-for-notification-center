#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/feedbar-media-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc "$project_dir"/Shared/*.swift "$project_dir/Tests/MediaRegressionTests.swift" -o "$test_dir/media-tests"
"$test_dir/media-tests"
