#!/usr/bin/env bash
# Runs INSIDE a container of the target's distro (debian:13 for the 3090 box), as root.
# Installs the target's exact CUDA toolkit + host gcc, builds UnbiasedStrata AOT for the
# target (single-arch SASS, target CPU flags), runs the GPU-less checks, and packages.
#
#   build-in-container.sh <profile.env> <upstream-src-dir> <out-dir> <label>
#
# Why a container of the target's distro: the binaries then link the same glibc/libstdc++
# and the same libcudart/libcublas sonames the target has -- nothing to guess.
#
# Why the compiler wrapper (/opt/xcc): upstream forces GGML_NATIVE=ON (CMake FORCE, no -D
# can override it), so ggml-cpu is compiled with -march=native. On a CI runner that would
# mean the RUNNER's CPU. The wrapper rewrites -march=native into the flags gcc resolved
# for -march=native ON THE TARGET (scraped by .github/scripts/scrape-target.sh), so the
# result is what `make build` on the target box itself would produce.
set -euo pipefail

PROFILE=$1 SRC=$2 OUT=$3 LABEL=$4
# shellcheck disable=SC1090
source "$PROFILE"
: "${TARGET_NAME:?}" "${CUDA_SOURCE:?}" "${CUDA_VERSION:?}" "${CUDA_ARCHS:?}" "${HOST_GCC:?}"
mkdir -p "$OUT"
LOG="$OUT/checks-${TARGET_NAME}.txt"
: > "$LOG"
note() { echo "$*" | tee -a "$LOG"; }
warn() { echo "::warning::$*"; echo "WARN: $*" >> "$LOG"; }
group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }
export DEBIAN_FRONTEND=noninteractive

. /etc/os-release
group "apt: base toolchain (${PRETTY_NAME})"
if [ "$ID" = debian ]; then
  # nvidia-cuda-toolkit lives in contrib/non-free
  if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    sed -i 's/^Components: .*/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
  else
    sed -i 's/ main$/ main contrib non-free non-free-firmware/' /etc/apt/sources.list
  fi
elif [ "$ID" = ubuntu ]; then
  sed -i 's/^Components: .*/Components: main restricted universe multiverse/' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
fi
apt-get update -q
apt-get install -y -q --no-install-recommends \
  build-essential "gcc-${HOST_GCC}" "g++-${HOST_GCC}" cmake make git python3 curl ca-certificates \
  patchelf file binutils gnupg
endgroup

group "CUDA ${CUDA_VERSION} via ${CUDA_SOURCE}"
case "$CUDA_SOURCE" in
  debian-apt)
    # the distro's own package: on Debian 13 this is exactly 12.4.131
    apt-get install -y -q --no-install-recommends nvidia-cuda-toolkit
    ;;
  nvidia-repo)
    # NVIDIA's apt repo (a target whose toolkit came from developer.nvidia.com)
    mm=$(echo "$CUDA_VERSION" | cut -d. -f1,2 | tr . -)
    repo="${ID}$(echo "$VERSION_ID" | tr -d .)"
    curl -fsSL -o /tmp/keyring.deb \
      "https://developer.download.nvidia.com/compute/cuda/repos/${repo}/x86_64/cuda-keyring_1.1-1_all.deb"
    dpkg -i /tmp/keyring.deb && apt-get update -q
    apt-get install -y -q --no-install-recommends "cuda-nvcc-${mm}" "cuda-cudart-dev-${mm}" \
      "libcublas-dev-${mm}" "cuda-driver-dev-${mm}" "cuda-cuobjdump-${mm}"
    export PATH="/usr/local/cuda-$(echo "$mm" | tr - .)/bin:$PATH"
    ;;
  *) echo "unknown CUDA_SOURCE=$CUDA_SOURCE"; exit 1 ;;
esac
NVCC=$(command -v nvcc)
nvcc_rel=$(nvcc --version | sed -nE 's/.*, V([0-9.]+)$/\1/p')
note "nvcc: $NVCC  V${nvcc_rel}  (target has ${CUDA_VERSION})"
# full release (12.4.131) = the target's own toolkit, must match exactly; X.Y = driver-only
# target, any patch of X.Y
case "$nvcc_rel" in "$CUDA_VERSION"|"$CUDA_VERSION".*) ok=1 ;; *) ok=0 ;; esac
if [ "$ok" != 1 ]; then
  echo "::error::CI nvcc is V${nvcc_rel} but the target has ${CUDA_VERSION} -- refusing to build a mismatched binary"
  exit 1
fi
endgroup

group "compiler wrapper: -march=native -> target CPU"
real_cxx=$(command -v "g++-${HOST_GCC}") real_cc=$(command -v "gcc-${HOST_GCC}")
flags="${CPU_FLAGS:-}"
if [ -n "$flags" ] && ! echo 'int main(){}' | "$real_cxx" $flags -x c++ - -o /dev/null 2>/tmp/flagerr; then
  warn "g++-${HOST_GCC} rejects the scraped CPU_FLAGS ($(head -c 300 /tmp/flagerr)); falling back to -march=${CPU_MARCH}"
  flags=""
fi
[ -n "$flags" ] || flags="-march=${CPU_MARCH:-x86-64-v3}"
echo 'int main(){}' | "$real_cxx" $flags -x c++ - -o /dev/null
mkdir -p /opt/xcc
for pair in "g++-${HOST_GCC}:$real_cxx" "gcc-${HOST_GCC}:$real_cc"; do
  name=${pair%%:*} real=${pair#*:}
  cat > "/opt/xcc/$name" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  case "\$a" in
    -march=native) args+=($flags); echo x >> /tmp/xcc-rewrites ;;
    -mtune=native) ;;
    *) args+=("\$a") ;;
  esac
done
exec $real "\${args[@]}"
EOF
  chmod +x "/opt/xcc/$name"
done
: > /tmp/xcc-rewrites
note "target CPU flags: $flags"
endgroup

group "make build (CUDA_ARCHS=${CUDA_ARCHS})"
cd "$SRC"
JOBS=${JOBS:-4}
set +e +o pipefail
make build NVCC="$NVCC" HOSTCXX="/opt/xcc/g++-${HOST_GCC}" CUDA_ARCHS="$CUDA_ARCHS" JOBS="$JOBS" \
  2>&1 | tee "$OUT/build-${TARGET_NAME}.log" | grep --line-buffered -E '^\[ *[0-9]+%\]|error:|Error '
rc=${PIPESTATUS[0]}
set -e -o pipefail
[ "$rc" -eq 0 ] || { tail -80 "$OUT/build-${TARGET_NAME}.log"; echo "::error::make build failed (exit $rc)"; exit 1; }
n=$(wc -l < /tmp/xcc-rewrites)
note "-march=native rewritten to target flags in $n compiler invocations"
[ "$n" -gt 0 ] || { echo "::error::wrapper never saw -march=native; the CPU retargeting did not apply"; exit 1; }
endgroup

group "make test (front end vs fake engine; runner-native, no GPU)"
# Separate build dir and the distro's default compiler WITHOUT the wrapper: these test
# binaries must run here, on the runner's CPU.
make test BUILD_DIR=build-ci-test JOBS="$JOBS" > "$OUT/test-${TARGET_NAME}.log" 2>&1 \
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
  elif [ $rc -eq 0 ]; then note "$f --help: exit 0"
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
