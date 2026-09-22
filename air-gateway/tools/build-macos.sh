#!/bin/bash
# Build an application-only pkg. No postinstall script and no host mutations.
set -eu
set -o pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"
[ "$(uname -s)" = Darwin ] || { printf 'Build on macOS with Command Line Tools.\n' >&2; exit 1; }
mode=${1---head}
case "$mode" in --head|--worktree) [ "$#" -le 1 ] ;; *) printf 'Usage: build-macos.sh [--head|--worktree]\n' >&2; exit 1 ;; esac
if [ "$mode" = --head ]; then
  python3 air-gateway/tools/check-publication.py --head
else
  python3 air-gateway/tools/check-publication.py
fi
[ ! -L dist ] && { [ ! -e dist ] || [ -d dist ]; } || { printf 'Invalid dist directory\n' >&2; exit 1; }
mkdir -p dist
scratch=$(mktemp -d dist/.macos-build.XXXXXXXX)
scratch=$(cd "$scratch" && pwd)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/source"
if [ "$mode" = --head ]; then
  revision=$(git rev-parse HEAD)
  git archive "$revision" | tar -x -C "$scratch/source"
else
  revision=uncommitted-preview
  python3 - "$REPO" "$scratch/source" <<'PY'
import pathlib,shutil,sys
root,out=map(pathlib.Path,sys.argv[1:])
for line in (root/'PUBLISH_FILES.txt').read_text().splitlines():
    if not line or line.startswith('#'): continue
    target=out/line
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(root/line,target)
PY
fi
source="$scratch/source/air-gateway"
version=$(cat "$source/VERSION")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$ ]] || { printf 'Expected an alpha version\n' >&2; exit 1; }
numeric=${version/-alpha./.}
output="$REPO/dist/Air-Gateway-$version-unsigned.pkg"
[ ! -e "$output" ] && [ ! -L "$output" ] || { printf 'Output already exists: %s\n' "$output" >&2; exit 1; }
app="$scratch/root/Applications/Air Gateway.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/core"
cp "$source/macos/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version%%-*}" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $numeric" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :AirGatewayReleaseVersion $version" "$app/Contents/Info.plist"
sdk=$(xcrun --sdk macosx --show-sdk-path)
for architecture in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -target "$architecture-apple-macosx14.0" \
    -sdk "$sdk" -module-cache-path "$scratch/cache-$architecture" \
    -file-prefix-map "$scratch=/AirGatewayBuild" \
    "$source/macos/AirGateway.swift" -o "$scratch/AirGateway-$architecture"
done
/usr/bin/lipo -create "$scratch/AirGateway-arm64" "$scratch/AirGateway-x86_64" -output "$app/Contents/MacOS/AirGateway"
for file in install.sh gateway.sh gatewayctl config.sh org.airgateway.gateway.plist; do
  cp "$source/$file" "$app/Contents/Resources/core/$file"
done
cp "$source/macos/gui-install.sh" "$app/Contents/Resources/core/gui-install.sh"
cp "$source/LICENSE" "$app/Contents/Resources/LICENSE"
printf 'Version: %s\nSource commit: %s\nSignature: ad-hoc only; no Developer ID or notarization\n' "$version" "$revision" > "$app/Contents/Resources/build-info.txt"
find "$scratch/root" -type d -exec chmod 755 {} +
find "$scratch/root" -type f -exec chmod 644 {} +
chmod 755 "$app/Contents/MacOS/AirGateway"
# Required for a valid arm64 executable. This does not establish publisher trust.
/usr/bin/codesign --force --sign - --timestamp=none "$app"
/usr/bin/codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/AirGateway" --self-test
python3 - "$scratch/components.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
    plistlib.dump([{'RootRelativeBundlePath':'Applications/Air Gateway.app',
                   'BundleIsRelocatable':False,'BundleHasStrictIdentifier':True,
                   'BundleIsVersionChecked':True,'BundleOverwriteAction':'upgrade'}],f)
PY
/usr/bin/pkgbuild --root "$scratch/root" --ownership recommended --install-location / \
  --component-plist "$scratch/components.plist" --identifier org.airgateway.installer \
  --version "$numeric" "$scratch/AirGateway-component.pkg"
/usr/bin/productbuild --distribution "$source/macos/Distribution.xml" \
  --resources "$source/macos/resources" --package-path "$scratch" "$output"
python3 "$source/tools/verify-macos.py" "$output"
(cd "$REPO/dist" && shasum -a 256 "$(basename "$output")" > "$(basename "$output").sha256")
# Preserve one disposable GUI preview; this is not installed or started.
preview="$REPO/dist/macos-preview-$version"
if [ ! -e "$preview" ]; then
  mkdir "$preview"
  /usr/bin/ditto "$app" "$preview/Air Gateway.app"
fi
printf 'Package: %s\nSource: %s\nUnsigned preview; no live installation performed.\n' "$output" "$revision"
