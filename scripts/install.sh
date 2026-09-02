#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname "$script_directory")
source_application="$project_directory/dist/F1 Live.app"
applications_directory="$HOME/Applications"
installed_application="$applications_directory/F1 Live.app"

"$script_directory/build-app.sh"
mkdir -p "$applications_directory"
if [ -d "$installed_application" ]; then
  rm -rf "$installed_application"
fi
cp -R "$source_application" "$installed_application"
open "$installed_application"

printf 'Installed and opened %s\n' "$installed_application"
