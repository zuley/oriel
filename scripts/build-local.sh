#!/bin/bash
set -euo pipefail

# Verification fallback only. The Xcode app target remains the canonical build.
# Build the same sources, statically link OrielCore, and ad-hoc sign a local app.
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$project_root/.build/local"
module_dir="$output_dir/modules"
app_bundle="$output_dir/Oriel.app"
sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
swift_compiler="$(/usr/bin/xcrun --find swiftc)"
target_arch="$(/usr/bin/uname -m)"
target_triple="$target_arch-apple-macosx14.0"

core_sources=()
while IFS= read -r -d '' source_file; do
  core_sources+=("$source_file")
done < <(/usr/bin/find "$project_root/Packages/OrielCore/Sources/OrielCore" -name '*.swift' -type f -print0)

if [[ ${#core_sources[@]} -eq 0 ]]; then
  printf '%s\n' 'No OrielCore sources found; complete the local package before building.' >&2
  exit 1
fi

app_sources=(
  "$project_root/OrielApp/OrielPalette.swift"
  "$project_root/OrielApp/MiniWindowSession.swift"
  "$project_root/OrielApp/DataExport.swift"
  "$project_root/OrielApp/ManagementSettingsView.swift"
  "$project_root/OrielApp/ManagementView.swift"
  "$project_root/OrielApp/ManagementWindow.swift"
  "$project_root/OrielApp/AppPreferences.swift"
  "$project_root/OrielApp/OrielApp.swift"
  "$project_root/OrielApp/AppModel.swift"
  "$project_root/OrielApp/MiniPanel.swift"
  "$project_root/OrielApp/BrowserModel.swift"
  "$project_root/OrielApp/BrowserView.swift"
  "$project_root/OrielApp/StockMarket.swift"
  "$project_root/OrielApp/StockChart.swift"
  "$project_root/OrielApp/StocksView.swift"
  "$project_root/OrielApp/NovelSession.swift"
  "$project_root/OrielApp/NovelView.swift"
  "$project_root/OrielApp/NotesStore.swift"
  "$project_root/OrielApp/NotesWorkspace.swift"
  "$project_root/OrielApp/NotesView.swift"
  "$project_root/OrielApp/PageKind.swift"
  "$project_root/OrielApp/ChromeLayout.swift"
  "$project_root/OrielApp/ChromeHomeView.swift"
  "$project_root/OrielApp/WindowTabStrip.swift"
  "$project_root/OrielApp/MiniWindowChromeView.swift"
)

mkdir -p "$module_dir" "$output_dir/ModuleCache" "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"

terminal_package="$project_root/Packages/OrielTerminal"
terminal_build_flags=(--package-path "$terminal_package" --scratch-path "$output_dir/terminal-build" --triple "$target_triple")
/usr/bin/xcrun swift build "${terminal_build_flags[@]}" --product OrielTerminal
terminal_bin="$(/usr/bin/xcrun swift build "${terminal_build_flags[@]}" --show-bin-path)"

reading_build_flags=(--package-path "$project_root/Packages/OrielReading" --scratch-path "$output_dir/reading-build" --triple "$target_triple")
/usr/bin/xcrun swift build "${reading_build_flags[@]}" --product OrielReading
reading_bin="$(/usr/bin/xcrun swift build "${reading_build_flags[@]}" --show-bin-path)"

common_flags=(
  -swift-version 6
  -target "$target_triple"
  -sdk "$sdk_path"
  -module-cache-path "$output_dir/ModuleCache"
  -Onone -g -D DEBUG
)

"$swift_compiler" "${common_flags[@]}" \
  -parse-as-library -emit-library -static -emit-module \
  -module-name OrielCore \
  -emit-module-path "$module_dir/OrielCore.swiftmodule" \
  "${core_sources[@]}" \
  -o "$module_dir/libOrielCore.a"

"$swift_compiler" "${common_flags[@]}" \
  -parse-as-library -module-name Oriel \
  -I "$module_dir" -L "$module_dir" -lOrielCore \
  -I "$terminal_bin" -I "$terminal_bin/Modules" -L "$terminal_bin" -lOrielTerminal \
  -I "$reading_bin" -I "$reading_bin/Modules" -L "$reading_bin" -lOrielReading \
  -framework AppKit -framework SwiftUI -framework WebKit \
  "${app_sources[@]}" \
  -o "$app_bundle/Contents/MacOS/Oriel"

cp "$project_root/Config/Info.plist" "$app_bundle/Contents/Info.plist"
bundle_plist="$app_bundle/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDevelopmentRegion -string en "$bundle_plist"
/usr/bin/plutil -replace CFBundleExecutable -string Oriel "$bundle_plist"
/usr/bin/plutil -replace CFBundleIdentifier -string app.oriel.mac "$bundle_plist"
/usr/bin/plutil -replace CFBundleName -string Oriel "$bundle_plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string 0.1.0 "$bundle_plist"
/usr/bin/plutil -replace CFBundleVersion -string 1 "$bundle_plist"
/usr/bin/plutil -replace LSMinimumSystemVersion -string 14.0 "$bundle_plist"
cp "$project_root/OrielApp/Resources/SwiftTerm-LICENSE.txt" "$app_bundle/Contents/Resources/SwiftTerm-LICENSE.txt"
if [[ -d "$reading_bin/ZIPFoundation_ZIPFoundation.bundle" ]]; then
  /usr/bin/ditto "$reading_bin/ZIPFoundation_ZIPFoundation.bundle" "$app_bundle/Contents/Resources/ZIPFoundation_ZIPFoundation.bundle"
fi
/usr/bin/install -m 644 "$project_root/OrielApp/Resources/ZIPFoundation-LICENSE.txt" "$app_bundle/Contents/Resources/ZIPFoundation-LICENSE.txt"
cp -R "$project_root/OrielApp/Resources/OrielZsh" "$app_bundle/Contents/Resources/"
/usr/bin/ditto "$project_root/OrielApp/Resources/Brand" "$app_bundle/Contents/Resources/Brand"
printf 'APPL????' > "$app_bundle/Contents/PkgInfo"
/usr/bin/codesign --force --sign - "$app_bundle"
/usr/bin/codesign --verify --strict "$app_bundle"

printf 'Local verification app: %s\n' "$app_bundle"
printf '%s\n' 'This CLT fallback does not validate the Xcode project, signing for distribution, or notarization.'
