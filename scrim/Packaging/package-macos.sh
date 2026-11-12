#!/bin/bash
set -euo pipefail

scrim_dir=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
dist_dir="$scrim_dir/../dist"
scratch_dir="${SCRIM_SWIFT_SCRATCH_PATH:-$scrim_dir/.build}"
build_args=(--package-path "$scrim_dir" --scratch-path "$scratch_dir" --configuration release --disable-automatic-resolution)

swift build "${build_args[@]}" --product ScrimMac
bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
arch=$(/usr/bin/lipo -archs "$bin_dir/ScrimMac")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$scrim_dir/Packaging/Info.plist")

mkdir -p "$dist_dir"
package_dir=$(mktemp -d "$dist_dir/Scrim-$version-$arch.XXXXXX")
app_dir="$package_dir/Scrim.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/Notices"
install -m 755 "$bin_dir/ScrimMac" "$app_dir/Contents/MacOS/ScrimMac"
install -m 644 "$scrim_dir/Packaging/Info.plist" "$app_dir/Contents/Info.plist"
install -m 644 "$scrim_dir/Assets/ScrimIcon.icns" "$app_dir/Contents/Resources/ScrimIcon.icns"
if [[ -n "${SCRIM_REPOSITORY_URL:-}" ]]; then
    /usr/bin/plutil -replace ScrimRepositoryURL -string "$SCRIM_REPOSITORY_URL" "$app_dir/Contents/Info.plist"
fi
install -m 644 "$scrim_dir/../LICENSE" "$app_dir/Contents/Resources/Notices/FreeShow-LICENSE.txt"
for dependency in Starscream socket.io-client-swift; do
    install -m 644 "$scratch_dir/checkouts/$dependency/LICENSE" "$app_dir/Contents/Resources/Notices/$dependency-LICENSE.txt"
done

# This dependency bundle contains its privacy manifest, not runtime assets.
/usr/bin/ditto "$bin_dir/Starscream_Starscream.bundle" "$app_dir/Contents/Resources/Starscream_Starscream.bundle"
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"
/usr/bin/ditto -c -k --keepParent "$app_dir" "$package_dir/Scrim-$version-$arch.zip"
printf '\nLocal test package: %s\n' "$package_dir"
