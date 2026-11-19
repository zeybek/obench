#!/usr/bin/env bash
# Runs the build commands from step 3 of the README's Getting Started in a fresh copy of the
# repository, the way a new user would, so a step that only works in a used checkout fails
# CI. The line that runs the CLI on the reader's own project is left out.
# Usage: scripts/check_readme_build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/obench-readme.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The first sh block after "3. Build the CLI", without its four-space list indent.
cmds="$(awk '
  /^3\. Build the CLI/ { step = 1 }
  step && /^    ```sh/ { block = 1; next }
  block && /^    ```/ { exit }
  block { sub(/^    /, ""); print }
' "$ROOT/README.md" | grep -v 'path/to/project' || true)"
if [ -z "$cmds" ]; then
  echo "check_readme_build: no build commands found under step 3 of README.md" >&2
  exit 1
fi

git -C "$ROOT" archive HEAD | tar -x -C "$WORK"
cd "$WORK"
echo "$cmds"
bash -euo pipefail -c "$cmds"
./bin/obench version
