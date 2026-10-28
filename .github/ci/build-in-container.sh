#!/usr/bin/env bash
# The fast-changing half of a target build: runs INSIDE a container of the target's distro,
# as root, after setup-toolchain.sh (or in an image that has it baked in). Builds
# UnbiasedStrata AOT for the target (single-arch SASS, target CPU flags) with ccache, runs
# the GPU-less checks, and packages.
#
#   build-in-container.sh <profile.env> <upstream-src-dir> <out-dir> <label>
#
# In a plain distro image it runs setup-toolchain.sh first.
#
# Why a container of the target's distro: the binaries then link the same glibc/libstdc++
# and the same libcudart/libcublas sonames the target has -- nothing to guess.
set -euo pipefail

PROFILE=$(readlink -f "$1") SRC=$2 OUT=$(mkdir -p "$3" && readlink -f "$3") LABEL=$4
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1090
source "$PROFILE"
: "${TARGET_NAME:?}" "${CUDA_ARCHS:?}" "${HOST_GCC:?}"
mkdir -p "$OUT"
LOG="$OUT/checks-${TARGET_NAME}.txt"
: > "$LOG"
note() { echo "$*" | tee -a "$LOG"; }
warn() { echo "::warning::$*"; echo "WARN: $*" >> "$LOG"; }
group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }
. /etc/os-release

# the checkout belongs to the runner user, this container runs as root
git config --global --add safe.directory '*'
# a plain distro image: install the toolchain first (~2 min; the compile is what ccache saves)
[ -f /opt/xcc/toolchain.env ] || bash "$HERE/setup-toolchain.sh" "$PROFILE"
# shellcheck disable=SC1091
source /opt/xcc/toolchain.env
[ -z "$TC_PATH_PREFIX" ] || export PATH="$TC_PATH_PREFIX:$PATH"
NVCC=$(command -v nvcc)
nvcc_rel=$TC_NVCC_REL flags=$TC_CPU_FLAGS real_cxx=$TC_REAL_CXX
note "nvcc: V${nvcc_rel} (${CUDA_SOURCE}; target has ${CUDA_VERSION})"
note "target CPU flags: $flags"
[ -z "$TC_FLAG_NOTE" ] || warn "$TC_FLAG_NOTE"

# ccache: CCACHE_DIR is mounted from the runner and carried across runs by actions/cache.
# compilercheck=content: the wrapper's text holds the target flags, so it IS the identity.
export CCACHE_DIR=${CCACHE_DIR:-/w/.ccache} CCACHE_BASEDIR=$SRC CCACHE_COMPILERCHECK=content \
       CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-4G} CCACHE_NOHASHDIR=1
ccache -z >/dev/null
LAUNCH="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache"

group "make build (CUDA_ARCHS=${CUDA_ARCHS})"
cd "$SRC"
JOBS=${JOBS:-4}
set +e +o pipefail
make build NVCC="$NVCC" HOSTCXX="$TC_CXX" CUDA_ARCHS="$CUDA_ARCHS" JOBS="$JOBS" CMAKE_EXTRA="$LAUNCH" \
  2>&1 | tee "$OUT/build-${TARGET_NAME}.log" | grep --line-buffered -E '^\[ *[0-9]+%\]|error:|Error '
rc=${PIPESTATUS[0]}
set -e -o pipefail
[ "$rc" -eq 0 ] || { tail -80 "$OUT/build-${TARGET_NAME}.log"; echo "::error::make build failed (exit $rc)"; exit 1; }
# the retargeting must have applied: CMake compiled with the wrapper, and ggml-cpu asked for
# -march=native (which only the wrapper turns into the target's flags). Checked from the
# build files, not by counting wrapper calls -- a ccache hit never calls the compiler.
grep -q "^CMAKE_CXX_COMPILER:[A-Z]*=$TC_CXX\$" build/CMakeCache.txt \
  || { echo "::error::build did not use the target compiler wrapper $TC_CXX"; exit 1; }
grep -rqs --include=flags.make -- '-march=native' build/ggml \
  || warn "ggml-cpu flags.make has no -march=native (upstream changed how it picks CPU flags? retargeting may be moot)"
note "ccache (build): $(ccache -s 2>/dev/null | grep -iE '^ *(hits|misses)' | tr -s ' ' | paste -sd ',' )"
endgroup

group "make test (front end vs fake engine; runner-native, no GPU)"
# Separate build dir and the distro's default compiler WITHOUT the wrapper: these test
# binaries must run here, on the runner's CPU.
make test BUILD_DIR=build-ci-test JOBS="$JOBS" CMAKE_EXTRA="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache" > "$OUT/test-${TARGET_NAME}.log" 2>&1 \
  || { tail -60 "$OUT/test-${TARGET_NAME}.log"; echo "::error::make test failed"; exit 1; }
tail -5 "$OUT/test-${TARGET_NAME}.log"
note "make test: PASS"
endgroup

BIN="$SRC/build/bin"
ELFS="strata strata-poly strata-dsv41 libstrata_kq.so unbiased-strata"
group "structural GPU checks (no GPU on this runner)"
want_sm=$(echo "$CUDA_ARCHS" | tr ';' '\n' | sed 's/-.*//' | sort -u | sed 's/^/sm_/' | tr '\n' ' ')
for f in strata strata-poly strata-dsv41 libstrata_kq.so; do
  elfs=$(cuobjdump --list-elf "$BIN/$f" 2>/dev/null | grep -oE 'sm_[0-9]+a?' | sort -u | tr '\n' ' ' || true)
  ptx=$(cuobjdump --list-ptx "$BIN/$f" 2>/dev/null | grep -c 'PTX file' || true)
  note "$f: SASS {${elfs}} PTX-entries=${ptx}"
  [ -n "$elfs" ] || { echo "::error::$f carries no device code"; exit 1; }
  for s in $elfs; do
    case " $want_sm " in *" ${s%a} "*) ;; *) echo "::error::$f has SASS for $s, expected only: $want_sm"; exit 1 ;; esac
  done
  case "$CUDA_ARCHS" in *-real*) [ "$ptx" -eq 0 ] || warn "$f embeds PTX although archs are -real" ;; esac
done
for f in $ELFS; do
  missing=$(ldd "$BIN/$f" | awk '/not found/ {print $1}' | grep -v '^libcuda\.so\.1$' || true)
  [ -z "$missing" ] || { echo "::error::$f: unresolved libraries: $missing"; exit 1; }
  note "$f NEEDED: $(readelf -d "$BIN/$f" | sed -nE 's/.*\(NEEDED\).*\[(.*)\]/\1/p' | tr '\n' ' ')"
done
maxglibc=$(for f in $ELFS; do objdump -T "$BIN/$f"; done | grep -oE 'GLIBC_[0-9.]+' | sed 's/GLIBC_//' | sort -uV | tail -1)
note "highest GLIBC symbol version required: $maxglibc (target glibc ${GLIBC:-unknown})"
if [ -n "${GLIBC:-}" ] && [ "$(printf '%s\n%s\n' "$maxglibc" "$GLIBC" | sort -V | tail -1)" != "$GLIBC" ]; then
  echo "::error::binaries need glibc $maxglibc but the target has $GLIBC"; exit 1
fi
endgroup

group "best-effort run checks (runner CPU may lack the target's ISA)"
for f in unbiased-strata strata strata-poly strata-dsv41; do
  set +e
  timeout 30 "$BIN/$f" --help > "/tmp/help-$f.txt" 2>&1; rc=$?
  set -e
  if [ $rc -eq 132 ]; then warn "$f --help: SIGILL -- the runner CPU lacks an instruction the TARGET has (expected if the target CPU is newer)"
  elif [ $rc -eq 0 ] || grep -qi '^usage:' "/tmp/help-$f.txt"; then note "$f --help: runs (exit $rc, prints usage)"
  else warn "$f --help: exit $rc: $(head -c 200 "/tmp/help-$f.txt" | tr '\n' ' ')"; fi
done
endgroup

group "package"
pkg="unbiased-strata-${LABEL}-${TARGET_NAME}"
stage="/tmp/stage/$pkg"
mkdir -p "$stage/bin"
for f in $ELFS; do cp "$BIN/$f" "$stage/bin/"; done
# binaries look in bin/ (libstrata_kq.so) and bin/lib (bundled CUDA libs, -cudalibs package only)
for f in $ELFS; do patchelf --set-rpath '$ORIGIN:$ORIGIN/lib' "$stage/bin/$f"; done
cp -r data "$stage/"
cp LICENSE README.md UPSTREAM.md "$stage/"
{
  echo "UnbiasedStrata build for target: ${TARGET_NAME}"
  echo "upstream: robertkarl/UnbiasedStrata @ $(git rev-parse HEAD)"
  echo "llama.cpp submodule: $(git -C third_party/llama.cpp rev-parse HEAD)"
  echo "built: $(date -u +%FT%TZ) in ${PRETTY_NAME} container on GitHub Actions"
  echo "nvcc: V${nvcc_rel} (${CUDA_SOURCE}); host compiler: $("$real_cxx" --version | head -1)"
  echo "CUDA archs: ${CUDA_ARCHS}"
  echo "CPU flags (ggml-cpu -march=native replaced by): ${flags}"
  echo; echo "--- target profile ---"; cat "$PROFILE"
  echo; echo "--- CI checks ---"; cat "$LOG"
} > "$stage/BUILDINFO.txt"
tar -C /tmp/stage -czf "$OUT/${pkg}.tar.gz" "$pkg"

# -cudalibs: same, plus the CUDA runtime libs the binaries link (never libcuda.so.1 -- that is the driver's)
mkdir -p "$stage/bin/lib"
for f in $ELFS; do ldd "$BIN/$f"; done | awk '$3 ~ /^\// {print $1" "$3}' | sort -u |
  { grep -E '^lib(cudart|cublas|cublasLt|nvJitLink|nvrtc)[^ ]*\.so' || true; } | while read -r so path; do
    cp -L "$path" "$stage/bin/lib/$so"; echo "bundled $so" | tee -a "$LOG"
  done
tar -C /tmp/stage -czf "$OUT/${pkg}-cudalibs.tar.gz" "$pkg"
(cd "$OUT" && sha256sum ./*.tar.gz | tee "SHA256SUMS-${TARGET_NAME}.txt")
ls -la "$OUT"
endgroup
