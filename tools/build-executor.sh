#!/bin/sh
# Copyright (C) 2026 hui contributors
# SPDX-License-Identifier: MIT
#
# 从 hui/third_party/ninja（上游 ninja 源码 + hui.patch）构建 hui 执行器，
# 产物安装到 hui/prebuilts/hui/hui。
#
# 用法: hui/tools/build-executor.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SRC="$ROOT/third_party/ninja"
OUT="$ROOT/prebuilts/hui"
[ $# -eq 0 ] || { echo "unknown argument: $1" >&2; exit 2; }

[ -f "$SRC/configure.py" ] || { echo "missing $SRC/configure.py" >&2; exit 1; }
[ -f "$SRC/hui.patch" ] || { echo "missing $SRC/hui.patch" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }

WORK="${TMPDIR:-/tmp}/hui-executor-build.$$"
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK"
cp -R "$SRC/src" "$SRC/misc" "$SRC/configure.py" "$SRC/COPYING" "$WORK/"

cd "$WORK"
patch -p1 --batch < "$SRC/hui.patch"
python3 configure.py --bootstrap

mkdir -p "$OUT"
install -m 755 ninja "$OUT/hui"
cp "$SRC/COPYING" "$OUT/COPYING"
cat > "$OUT/NOTICE" <<EOF
hui executor

Built from ninja ${HUI_NINJA_VERSION:-v1.12.1} (https://github.com/ninja-build/ninja),
Apache-2.0, with hui.patch from hui/third_party/ninja.

Local changes:
  * --parallelism-file FILE: read a runtime job limit from FILE without
    interrupting running commands (only affects edges that have not started).
  * HUI_POOL_<CLASS>_JOBS=N: cap the number of concurrent commands of a class
    (r8 / kotlin / javac / rust / .ld), classified by rule name.

Rebuild with hui/tools/build-executor.sh.
EOF

echo "built $OUT/hui"
sha256sum "$OUT/hui"
"$OUT/hui" --version
