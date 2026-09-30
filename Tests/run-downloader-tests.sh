#!/bin/bash
# Local URLProtocol fixtures only. No accounts, group data, or network access.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/feedbar-downloader-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc "$project_dir"/Shared/*.swift \
    "$project_dir/FeedBarApp/MediaPreviewDownloader.swift" \
    "$project_dir/Tests/DownloaderRegressionTests.swift" -o "$test_dir/downloader-tests"
"$test_dir/downloader-tests"
