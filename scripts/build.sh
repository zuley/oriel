#!/bin/bash
set -euo pipefail

# Canonical app build. Select Xcode for this process only; never run xcode-select -s.
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  xcode_developer_dir="$DEVELOPER_DIR"
else
  xcode_developer_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [[ ! -x "$xcode_developer_dir/usr/bin/xcodebuild" ]]; then
    for candidate in /Applications/Xcode.app/Contents/Developer /Applications/Xcode-*.app/Contents/Developer; do
      if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
        xcode_developer_dir="$candidate"
        break
      fi
    done
  fi
fi

# Accept either the .app path or its Contents/Developer directory.
if [[ "$xcode_developer_dir" == *.app ]]; then
  xcode_developer_dir="$xcode_developer_dir/Contents/Developer"
fi

if [[ ! -x "$xcode_developer_dir/usr/bin/xcodebuild" ]]; then
  cat >&2 <<'MESSAGE'
Oriel's standard app build needs the full Xcode application (Swift 6 or newer).
Install Xcode, complete its first launch, then run:
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build.sh
No global developer-directory change is required.
For local verification with Command Line Tools only, use ./scripts/build-local.sh.
That fallback does not validate the Xcode project or produce a release build.
MESSAGE
  exit 1
fi

export DEVELOPER_DIR="$xcode_developer_dir"
exec "$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project "$project_root/Oriel.xcodeproj" \
  -scheme Oriel \
  -configuration Debug \
  -destination "platform=macOS,arch=$(/usr/bin/uname -m)" \
  -derivedDataPath "$project_root/.build/xcode" \
  build "$@"
