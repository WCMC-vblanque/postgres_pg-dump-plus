#!/usr/bin/env bash
#
# pg_dump_plus — build & install from source (portable; any Linux/macOS with a
# C toolchain). Clones PostgreSQL REL_17_STABLE, applies the pg_dump_plus patch,
# builds pg_dump/pg_restore, and installs them under a prefix in your home dir.
# No root required.
#
# Usage:
#   scripts/install-from-source.sh            # installs to ~/pgdumpplus
#   PREFIX=/opt/pgdp scripts/install-from-source.sh
#
# Requires: git, gcc/clang, make, bison, flex, and the -dev libraries
#   zlib1g-dev libicu-dev libreadline-dev  (Debian/Ubuntu names)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$SCRIPT_DIR/../patches/pg_dump_plus-REL_17_STABLE.patch"
PREFIX="${PREFIX:-$HOME/pgdumpplus}"
TAG="REL_17_STABLE"

[ -f "$PATCH" ] || { echo "patch not found: $PATCH (run from inside the repo)"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo ">> cloning PostgreSQL $TAG (shallow) into $WORK"
git clone --depth 1 --branch "$TAG" https://github.com/postgres/postgres.git "$WORK/postgres"

cd "$WORK/postgres"
echo ">> applying pg_dump_plus patch"
git apply "$PATCH"

echo ">> configure (prefix=$PREFIX)"
./configure --prefix="$PREFIX" --with-zlib --with-icu --with-readline >/dev/null

echo ">> building"
make -C src/backend generated-headers >/dev/null
make -C src/bin/pg_dump -j"$(nproc 2>/dev/null || echo 2)" >/dev/null

echo ">> installing to $PREFIX"
make -C src/bin/pg_dump install >/dev/null
make -C src/interfaces/libpq install >/dev/null

echo ">> done"
"$PREFIX/bin/pg_dump" --version
echo "Binary: $PREFIX/bin/pg_dump   (add $PREFIX/bin to PATH)"
