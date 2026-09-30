#!/bin/bash
set -euo pipefail

# Local build only: never installs, registers, launches, or uploads the app.
# All generated files, signing metadata, and logs stay in the build directory.
FEEDBAR_MODE="${1:---unsigned}"
if [[ $# -gt 1 || ( "$FEEDBAR_MODE" != --unsigned && "$FEEDBAR_MODE" != --signed ) ]]; then
    echo 'Usage: ./build.sh [--unsigned|--signed]' >&2
    exit 2
fi
FEEDBAR_SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
FEEDBAR_BUILD_ROOT="${FEEDBAR_BUILD_DIR:-$FEEDBAR_SOURCE_DIR/build}"
FEEDBAR_BUILD_ID="$(date -u +%Y%m%dT%H%M%SZ)"
FEEDBAR_TEAM_ID="${FEEDBAR_TEAM_ID:-}"
FEEDBAR_SIGNING_IDENTITY="${FEEDBAR_SIGNING_IDENTITY:-}"
FEEDBAR_APP_GROUP="${FEEDBAR_APP_GROUP:-}"

# Process-local selection; never changes the machine's xcode-select setting.
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    echo 'Select a full Xcode installation, or set DEVELOPER_DIR to its Contents/Developer directory.' >&2
    exit 1
fi
for FEEDBAR_TOOL in xcodegen python3; do
    command -v "$FEEDBAR_TOOL" >/dev/null || { echo "Missing build tool: $FEEDBAR_TOOL" >&2; exit 1; }
done
if [[ "$FEEDBAR_MODE" == --signed ]]; then
    [[ "$FEEDBAR_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Set FEEDBAR_TEAM_ID to your 10-character Apple Developer Team ID.' >&2; exit 1; }
    [[ -n "$FEEDBAR_SIGNING_IDENTITY" && "$FEEDBAR_SIGNING_IDENTITY" != - ]] || { echo 'Set FEEDBAR_SIGNING_IDENTITY to your Apple Development or Developer ID Application identity.' >&2; exit 1; }
    FEEDBAR_APP_GROUP="${FEEDBAR_APP_GROUP:-$FEEDBAR_TEAM_ID.com.feedbar.shared}"
    if [[ "$FEEDBAR_APP_GROUP" != "$FEEDBAR_TEAM_ID."* || ! "$FEEDBAR_APP_GROUP" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo 'FEEDBAR_APP_GROUP must be a valid group identifier beginning with your Team ID and a dot.' >&2
        exit 1
    fi
else
    # An unsigned bundle must not accidentally access an existing user's group.
    FEEDBAR_TEAM_ID=""
    FEEDBAR_APP_GROUP=""
fi

mkdir -p "$FEEDBAR_BUILD_ROOT"
FEEDBAR_RUN_DIR="$(mktemp -d "$FEEDBAR_BUILD_ROOT/run-$FEEDBAR_BUILD_ID-XXXXXX")"
FEEDBAR_RUN_DIR="$(cd "$FEEDBAR_RUN_DIR" && pwd)"
FEEDBAR_LOG="$FEEDBAR_RUN_DIR/build.log"
exec > >(tee "$FEEDBAR_LOG") 2>&1
echo "Building FeedBar ($FEEDBAR_BUILD_ID, $FEEDBAR_MODE)"

# XcodeGen also writes plists. Stage only source so generated configuration and
# absolute paths cannot leak back into the repository.
python3 - "$FEEDBAR_SOURCE_DIR" "$FEEDBAR_RUN_DIR/Source" <<'PY'
from pathlib import Path
import shutil
import sys
source, staging = map(Path, sys.argv[1:])
staging.mkdir()
shutil.copyfile(source / 'project.yml', staging / 'project.yml')
for folder in ['FeedBarApp', 'FeedBarWidget', 'Shared']:
    (staging / folder).mkdir()
    for path in (source / folder).iterdir():
        if path.is_file() and path.suffix in {'.swift', '.plist', '.entitlements'}:
            shutil.copyfile(path, staging / folder / path.name)
PY
xcodegen generate --no-env --spec "$FEEDBAR_RUN_DIR/Source/project.yml"
xcodebuild \
    -project "$FEEDBAR_RUN_DIR/Source/FeedBar.xcodeproj" \
    -scheme FeedBarApp -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$FEEDBAR_RUN_DIR/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    PROVISIONING_PROFILE_SPECIFIER= PROVISIONING_PROFILE= \
    "FEEDBAR_BUILD_ID=$FEEDBAR_BUILD_ID" \
    "FEEDBAR_APP_GROUP=$FEEDBAR_APP_GROUP" build

FEEDBAR_APP="$FEEDBAR_RUN_DIR/DerivedData/Build/Products/Release/FeedBar.app"
FEEDBAR_WIDGET="$FEEDBAR_APP/Contents/PlugIns/FeedBarWidget.appex"
[[ -x "$FEEDBAR_APP/Contents/MacOS/FeedBar" ]] || { echo 'Built app executable is missing.' >&2; exit 1; }
[[ -x "$FEEDBAR_WIDGET/Contents/MacOS/FeedBarWidget" ]] || { echo 'Built widget executable is missing.' >&2; exit 1; }
if [[ -n "$(find "$FEEDBAR_APP" -name '*.provisionprofile' -o -name '*.mobileprovision')" ]]; then
    echo 'Unexpected provisioning profile in fresh build.' >&2
    exit 1
fi

if [[ "$FEEDBAR_MODE" == --signed ]]; then
    # Direct codesign does not expand Xcode variables. Resolve templates in the
    # build directory with the exact group passed to both bundle Info files.
    python3 - "$FEEDBAR_RUN_DIR/Source" "$FEEDBAR_RUN_DIR" "$FEEDBAR_APP_GROUP" <<'PY'
from pathlib import Path
import plistlib
import sys
source, output = map(Path, sys.argv[1:3])
group = sys.argv[3]
for folder, name in [('FeedBarApp', 'FeedBar'), ('FeedBarWidget', 'FeedBarWidget')]:
    value = plistlib.loads((source / folder / f'{name}.entitlements').read_bytes())
    value['com.apple.security.application-groups'] = [group]
    (output / f'{name}.entitlements').write_bytes(plistlib.dumps(value))
PY
    # Sign inside out; --deep signing can give children inappropriate rights.
    while IFS= read -r -d '' FEEDBAR_DYLIB; do
        codesign --force --sign "$FEEDBAR_SIGNING_IDENTITY" --options runtime --timestamp "$FEEDBAR_DYLIB"
    done < <(find "$FEEDBAR_APP" -type f -name '*.dylib' -print0)
    codesign --force --sign "$FEEDBAR_SIGNING_IDENTITY" --options runtime --timestamp \
        --entitlements "$FEEDBAR_RUN_DIR/FeedBarWidget.entitlements" "$FEEDBAR_WIDGET"
    codesign --force --sign "$FEEDBAR_SIGNING_IDENTITY" --options runtime --timestamp \
        --entitlements "$FEEDBAR_RUN_DIR/FeedBar.entitlements" "$FEEDBAR_APP"
    codesign --verify --deep --strict --verbose=2 "$FEEDBAR_APP"
fi

# Verify this fresh output, including the runtime group shared by both bundles.
python3 - "$FEEDBAR_APP" "$FEEDBAR_BUILD_ID" "$FEEDBAR_TEAM_ID" "$FEEDBAR_APP_GROUP" "$FEEDBAR_MODE" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys
app = Path(sys.argv[1])
build_id, team, group, mode = sys.argv[2:]
widget = app / 'Contents/PlugIns/FeedBarWidget.appex'
infos = []
for bundle, identifier, sandboxed in [
    (app, 'com.feedbar.app', False), (widget, 'com.feedbar.app.widget', True),
]:
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    infos.append(info)
    assert info['CFBundleIdentifier'] == identifier, 'Incorrect bundle identifier'
    assert info['FeedBarBuildID'] == build_id, 'Stale build'
    assert info.get('FeedBarAppGroup', '') == group, 'Incorrect runtime App Group'
    assert not list(bundle.rglob('*.provisionprofile')), 'Unexpected provisioning profile'
    assert not list(bundle.rglob('*.mobileprovision')), 'Unexpected provisioning profile'
    if mode == '--signed':
        result = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(bundle)],
                                check=True, capture_output=True)
        entitlements = plistlib.loads(result.stdout)
        assert entitlements.get('com.apple.security.application-groups') == [group], 'Incorrect signing group'
        assert bool(entitlements.get('com.apple.security.app-sandbox')) == sandboxed, 'Incorrect sandbox'
        assert not entitlements.get('com.apple.security.get-task-allow'), 'Unexpected debug entitlement'
        details = subprocess.run(['codesign', '-dv', '--verbose=4', str(bundle)],
                                 check=True, capture_output=True, text=True).stderr
        assert f'TeamIdentifier={team}' in details, 'Incorrect signing team'
        assert 'runtime' in details, 'Hardened runtime missing'
    print(f'Verified: {identifier} ({mode})')
assert infos[0]['CFBundleShortVersionString'] == infos[1]['CFBundleShortVersionString']
assert infos[0]['CFBundleVersion'] == infos[1]['CFBundleVersion']
assert infos[0].get('LSUIElement') is True
assert any('feedbar' in item.get('CFBundleURLSchemes', []) for item in infos[0].get('CFBundleURLTypes', []))
assert infos[1]['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
PY
printf '%s\n' "$FEEDBAR_APP" > "$FEEDBAR_RUN_DIR/app-path.txt"
echo "Build verified: $FEEDBAR_APP"
echo "Build log: $FEEDBAR_LOG"
if [[ "$FEEDBAR_MODE" == --unsigned ]]; then
    echo 'Compile-only artifact. Use --signed with your own identity to run the app and widget.'
fi
