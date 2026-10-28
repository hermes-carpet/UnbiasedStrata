#!/usr/bin/env bash
# toolchain-tag.sh <target.env>: prints <target>-<hash>, the identity of that target's
# toolchain (the ccache key prefix). It hashes everything setup-toolchain.sh builds from, so
# a changed profile (rescraped box, Debian bumping its CUDA package) or a changed setup
# script starts a fresh cache instead of reusing objects from another toolchain.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
name=$(basename "$1" .env)
hash=$(cat "$1" "$here/setup-toolchain.sh" | sha256sum | cut -c1-12)
echo "${name}-${hash}"
