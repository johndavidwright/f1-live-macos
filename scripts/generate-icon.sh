#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname "$script_directory")
source_icon="$project_directory/Assets/AppIcon.png"
iconset_directory="$project_directory/.build/AppIcon.iconset"
output_icon="$project_directory/Sources/F1Live/Resources/AppIcon.icns"

if [ ! -f "$source_icon" ]; then
  printf 'Missing icon master: %s\n' "$source_icon" >&2
  exit 1
fi

mkdir -p "$iconset_directory"

make_icon() {
  size=$1
  filename=$2
  sips -z "$size" "$size" "$source_icon" --out "$iconset_directory/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$iconset_directory" -o "$output_icon"
printf 'Generated %s\n' "$output_icon"
