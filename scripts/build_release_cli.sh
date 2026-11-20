#!/usr/bin/env bash
# Builds the CLI the way releases ship it: build_release_cli.sh <output path>.
#
# On Linux the CLI is linked statically, so it doesn't depend on the build machine's glibc:
# linked dynamically on ubuntu-latest it needs GLIBC_2.34, and Debian 11 and Ubuntu 20.04
# ship 2.31. It only reads files and starts processes, so it needs nothing from glibc's
# dynamic parts (NSS, dlopen).
set -euo pipefail
out=$1
flags=(-o:speed)
if [ "$(uname -s)" = Linux ]; then
  flags+=(-extra-linker-flags:-static)
fi
odin build cmd/obench -out:"$out" "${flags[@]}"
