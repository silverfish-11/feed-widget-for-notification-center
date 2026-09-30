#!/bin/bash
# Swift regression tests and local HTML extraction fixtures. Never opens a browser
# or contacts X/Instagram. No dependency downloads are performed by this script.
# Optional overrides: NODE_BIN=/path/to/node NODE_PATH=/path/to/node_modules
# Install the pinned test dependency with npm ci from the repository root.
set -euo pipefail

tests_root="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$tests_root/.." && pwd)"
node_bin="${NODE_BIN:-node}"
export NODE_PATH="${NODE_PATH:-$project_root/node_modules}"

if ! command -v "$node_bin" >/dev/null 2>&1; then
    echo 'Node.js is required. Set NODE_BIN to an existing Node executable.' >&2
    exit 1
fi
if ! "$node_bin" -e "require('jsdom')" >/dev/null 2>&1; then
    echo 'jsdom is required for the local HTML fixtures. Run npm ci at the repository root, or set NODE_PATH.' >&2
    echo 'This test runner does not install or download dependencies.' >&2
    exit 1
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/feedbar-scraper-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

xcrun swiftc "$project_root"/Shared/*.swift \
    "$project_root/FeedBarApp/JSScripts.swift" \
    "$project_root/FeedBarApp/FeedSettings.swift" \
    "$project_root/FeedBarApp/ScraperManager.swift" \
    "$project_root/FeedBarApp/MediaPreviewDownloader.swift" \
    "$project_root/FeedBarApp/FeedReplyContextResolver.swift" \
    "$tests_root/ScraperRegression.swift" \
    -framework Cocoa -framework WebKit -framework WidgetKit \
    -o "$scratch/scraper-regression"
"$scratch/scraper-regression"

cat > "$scratch/ExportScripts.swift" <<'SWIFT'
import Foundation
@main struct ExportScripts {
    static func main() throws {
        let payload = ["x": JSScripts.xExtraction, "ig": JSScripts.igExtraction, "xReply": JSScripts.xReplyContextExtraction(for: "300")]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: payload))
    }
}
SWIFT
xcrun swiftc "$project_root/FeedBarApp/JSScripts.swift" "$scratch/ExportScripts.swift" -o "$scratch/export-scripts"
"$scratch/export-scripts" > "$scratch/scripts.json"
"$node_bin" "$tests_root/extraction-fixtures.cjs" "$scratch/scripts.json"
