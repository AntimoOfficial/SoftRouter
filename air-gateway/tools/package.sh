#!/bin/bash
# Only archive an audited Git commit, never the working directory.
set -eu
set -o pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"
python3 air-gateway/tools/check-publication.py --head
commit=$(git rev-parse --short=12 HEAD)
version=$(git show HEAD:air-gateway/VERSION)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || { printf 'Invalid release version\n' >&2; exit 1; }
if [ -L dist ] || { [ -e dist ] && [ ! -d dist ]; }; then printf 'Invalid output directory\n' >&2; exit 1; fi
mkdir -p dist
archive="air-gateway-$version-$commit.tar.gz"
[ ! -e "dist/$archive" ] && [ ! -L "dist/$archive" ] || { printf 'Archive already exists: dist/%s\n' "$archive" >&2; exit 1; }
scratch=$(mktemp -d dist/.package.XXXXXXXX)
trap 'rm -rf "$scratch"' EXIT
git archive --format=tar.gz --prefix="air-gateway-$version/" HEAD > "$scratch/$archive"
(cd "$scratch" && shasum -a 256 "$archive" > "$archive.sha256")
mv "$scratch/$archive" "$scratch/$archive.sha256" dist/
printf 'Source archive: %s/dist/%s\n' "$REPO" "$archive"
printf 'Checksum: %s/dist/%s.sha256\n' "$REPO" "$archive"
printf 'This package contains committed files; uncommitted work is excluded.\n'
