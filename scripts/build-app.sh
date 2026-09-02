#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname "$script_directory")
output_directory="$project_directory/dist"
application="$output_directory/F1 Live.app"

cd "$project_directory"
swift build -c release --arch arm64
arm64_binary_directory=$(swift build -c release --arch arm64 --show-bin-path)
swift build -c release --arch x86_64
x86_64_binary_directory=$(swift build -c release --arch x86_64 --show-bin-path)

if [ -d "$application" ]; then
  rm -rf "$application"
fi
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources/Circuits"
lipo -create \
  "$arm64_binary_directory/F1Live" \
  "$x86_64_binary_directory/F1Live" \
  -output "$application/Contents/MacOS/F1Live"
cp "$project_directory/Sources/F1Live/Resources/Info.plist" "$application/Contents/Info.plist"
cp "$project_directory/Sources/F1Live/Resources/Circuits/"*.svg "$application/Contents/Resources/Circuits/"
chmod 755 "$application/Contents/MacOS/F1Live"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$application"
fi

lipo "$application/Contents/MacOS/F1Live" -verify_arch arm64 x86_64
printf 'Built %s\n' "$application"
