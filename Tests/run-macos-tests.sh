#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
export ALBUMWINNOW_ROOT="$repo_root"
export ALBUMWINNOW_VERSION
ALBUMWINNOW_VERSION="$(python3 - <<'PY'
from pathlib import Path
import re
versions = set(re.findall(r'MARKETING_VERSION = ([^;]+);', Path('AlbumWinnow.xcodeproj/project.pbxproj').read_text()))
assert len(versions) == 1
print(versions.pop())
PY
)"
python3 Tools/Localization/export.py --check
Tools/Core/build-apple.sh release --if-needed
mkdir -p .local/mac-tests
xcodegen generate --spec Tests/macOS-project.yml --project-root "$repo_root/.local/mac-tests" --project .local/mac-tests
xcodebuild -project .local/mac-tests/MacAcceptance.xcodeproj -scheme MacAcceptance -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO -testLanguage en -testRegion US "$@" test
