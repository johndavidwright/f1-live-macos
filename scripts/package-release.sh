#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname "$script_directory")
output_directory="$project_directory/dist"
application="$output_directory/F1 Live.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_directory/Sources/F1Live/Resources/Info.plist")
release_name="F1 Live $version"
release_directory="$output_directory/$release_name"
archive_name="F1-Live-$version-macOS-universal.zip"
archive="$output_directory/$archive_name"
checksum="$archive.sha256"
update_archive_name="F1-Live-$version-update.zip"
update_archive="$output_directory/$update_archive_name"

"$script_directory/build-app.sh"
lipo "$application/Contents/MacOS/F1Live" -verify_arch arm64 x86_64

if [ -d "$release_directory" ]; then
  rm -rf "$release_directory"
fi
rm -f "$archive" "$checksum" "$update_archive"

mkdir -p "$release_directory"
ditto "$application" "$release_directory/F1 Live.app"
cp "$project_directory/INSTALL.md" "$release_directory/INSTALL.md"
cp "$project_directory/RELEASE_NOTES.md" "$release_directory/RELEASE_NOTES.md"
cp "$project_directory/LICENSE" "$release_directory/LICENSE"
cp "$project_directory/ATTRIBUTIONS.md" "$release_directory/ATTRIBUTIONS.md"
cp "$application/Contents/Resources/Sparkle-LICENSE.txt" "$release_directory/Sparkle-LICENSE.txt"

ditto -c -k --sequesterRsrc --keepParent "$release_directory" "$archive"
ditto -c -k --sequesterRsrc --keepParent "$application" "$update_archive"
(
  cd "$output_directory"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
unzip -tq "$archive"
unzip -tq "$update_archive"

printf 'Release archive: %s\n' "$archive"
printf 'SHA-256: %s\n' "$checksum"
printf 'Sparkle update archive: %s\n' "$update_archive"
