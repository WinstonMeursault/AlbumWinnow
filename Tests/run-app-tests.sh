#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
simulator_id="${1:?Usage: Tests/run-app-tests.sh SIMULATOR_UDID}"
shift
export ALBUMWINNOW_ROOT="$repo_root"
export ALBUMWINNOW_VERSION
ALBUMWINNOW_VERSION="$(python3 - <<'PY'
from pathlib import Path
import re
versions = set(re.findall(r'MARKETING_VERSION = ([^;]+);', Path('AlbumWinnow.xcodeproj/project.pbxproj').read_text()))
assert len(versions) == 1, 'App versions must agree'
print(versions.pop())
PY
)"
python3 Tools/Localization/export.py --check
xcrun simctl bootstatus "$simulator_id" -b
mkdir -p .local/app-tests
xcodegen generate --spec Tests/project.yml --project-root "$repo_root/.local/app-tests" --project .local/app-tests
common=(-project .local/app-tests/AppAcceptance.xcodeproj -scheme AppAcceptance -configuration Debug
        -destination "platform=iOS Simulator,id=$simulator_id" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO -testLanguage en -testRegion US)
xcodebuild "${common[@]}" "$@" test
