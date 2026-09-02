#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname "$script_directory")
output_directory="$project_directory/dist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_directory/Sources/F1Live/Resources/Info.plist")
archive_name="F1-Live-$version-update.zip"
archive="$output_directory/$archive_name"
archives_directory="$output_directory/appcast-input"
release_notes="$archives_directory/F1-Live-$version-update.md"
appcast="$output_directory/appcast.xml"
account="dev.nocram.f1live.macos"
download_prefix="https://github.com/johndavidwright/f1-live-macos/releases/download/v$version/"
generate_appcast="$project_directory/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

if [ ! -f "$archive" ]; then
  printf 'Missing update archive: %s\nRun scripts/package-release.sh first.\n' "$archive" >&2
  exit 1
fi

if [ ! -x "$generate_appcast" ]; then
  swift package --package-path "$project_directory" resolve
fi

if [ -d "$archives_directory" ]; then
  rm -rf "$archives_directory"
fi
mkdir -p "$archives_directory"
cp "$archive" "$archives_directory/$archive_name"
cp "$project_directory/RELEASE_NOTES.md" "$release_notes"

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "$download_prefix" \
    --embed-release-notes \
    --maximum-deltas 0 \
    -o "$appcast" \
    "$archives_directory"
else
  "$generate_appcast" \
    --account "$account" \
    --download-url-prefix "$download_prefix" \
    --embed-release-notes \
    --maximum-deltas 0 \
    -o "$appcast" \
    "$archives_directory"
fi

test -s "$appcast"
xmllint --noout "$appcast"
printf 'Generated signed appcast: %s\n' "$appcast"
