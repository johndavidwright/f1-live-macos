#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname "$script_directory")
cd "$project_directory"

swift build
swift run --skip-build F1Live --self-test
swift run --skip-build F1Live --api-smoke-test
