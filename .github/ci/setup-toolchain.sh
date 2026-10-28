#!/usr/bin/env bash
# The slow-changing half of a target build: everything that depends only on the target
# profile, never on upstream's code. Run before each compile (~2 min); its inputs' hash
# (toolchain-tag.sh) keys the ccache, so a changed toolchain never reuses stale objects.
#
#   setup-toolchain.sh <profile.env>
#
# Installs the target's exact CUDA toolkit + host gcc + ccache in a container of the
# target's distro, and the compiler wrapper /opt/xcc/{gcc,g++}-<N>.
#
# Why the wrapper: upstream forces GGML_NATIVE=ON (CMake FORCE, no -D can override it), so
# ggml-cpu is compiled with -march=native, which on a CI runner means the RUNNER's CPU. The
# wrapper rewrites -march=native into the flags gcc resolved for -march=native ON THE TARGET
# (scraped by .github/scripts/scrape-target.sh): the result is what `make build` on the
# target box itself would produce. Its flags are baked into its text, so ccache (which
# hashes the compiler's content) never mixes objects of two targets.
set -euo pipefail

PROFILE=$1
# shellcheck disable=SC1090
source "$PROFILE"
: "${TARGET_NAME:?}" "${CUDA_SOURCE:?}" "${CUDA_VERSION:?}" "${HOST_GCC:?}"
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release

echo "::group::apt: base toolchain (${PRETTY_NAME})"
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
  patchelf file binutils gnupg ccache
echo "::endgroup::"

echo "::group::CUDA ${CUDA_VERSION} via ${CUDA_SOURCE}"
cuda_bin=""
case "$CUDA_SOURCE" in
  debian-apt)
    # the distro's own package: on Debian 13 this is exactly 12.4.131
    apt-get install -y -q --no-install-recommends nvidia-cuda-toolkit
    ;;
  nvidia-repo)
    # NVIDIA's apt repo (a target whose toolkit came from developer.nvidia.com, or a
    # driver-only target)
    mm=$(echo "$CUDA_VERSION" | cut -d. -f1,2 | tr . -)
    repo="${ID}$(echo "$VERSION_ID" | tr -d .)"
    curl -fsSL -o /tmp/keyring.deb \
      "https://developer.download.nvidia.com/compute/cuda/repos/${repo}/x86_64/cuda-keyring_1.1-1_all.deb"
    dpkg -i /tmp/keyring.deb && rm /tmp/keyring.deb && apt-get update -q
    apt-get install -y -q --no-install-recommends "cuda-nvcc-${mm}" "cuda-cudart-dev-${mm}" \
      "libcublas-dev-${mm}" "cuda-driver-dev-${mm}" "cuda-cuobjdump-${mm}"
    cuda_bin="/usr/local/cuda-$(echo "$mm" | tr - .)/bin"
    export PATH="$cuda_bin:$PATH"
    ;;
  *) echo "unknown CUDA_SOURCE=$CUDA_SOURCE"; exit 1 ;;
esac
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
nvcc_rel=$(nvcc --version | sed -nE 's/.*, V([0-9.]+)$/\1/p')
echo "nvcc V${nvcc_rel} (target has ${CUDA_VERSION})"
# full release (12.4.131) = the target's own toolkit, must match exactly; X.Y = driver-only
# target, any patch of X.Y
case "$nvcc_rel" in "$CUDA_VERSION"|"$CUDA_VERSION".*) ;; *)
  echo "::error::CI nvcc is V${nvcc_rel} but the target has ${CUDA_VERSION} -- refusing to build a mismatched binary"
  exit 1 ;;
esac
echo "::endgroup::"

echo "::group::compiler wrapper: -march=native -> target CPU"
real_cxx=$(command -v "g++-${HOST_GCC}") real_cc=$(command -v "gcc-${HOST_GCC}")
accepts() { echo 'int main(){}' | "$real_cxx" "$@" -x c++ - -o /dev/null 2>/dev/null; }
# the scraped -march (CPU name or x86-64 level) first, else the level; then each other flag on
# top of it, dropping only the ones this gcc does not know (a newer gcc's ISA or CPU names)
march=$(tr ' ' '\n' <<<"${CPU_FLAGS:-}" | sed -n '/^-march=/{p;q}')
[ -n "$march" ] && accepts "$march" || march="-march=${CPU_MARCH:-x86-64-v3}"
accepts "$march"
flags=$march dropped=""
for f in $(tr ' ' '\n' <<<"${CPU_FLAGS:-}" | grep -v -- '^-march='); do
  if accepts $flags "$f"; then flags+=" $f"; else dropped+=" $f"; fi
done
flag_note=""
if [ -n "$dropped" ] || { [ -n "${CPU_FLAGS:-}" ] && ! grep -qx -- "$march" <<<"$(tr ' ' '\n' <<<"$CPU_FLAGS")"; }; then
  flag_note="g++-${HOST_GCC} does not know some scraped CPU flags; built with ${march} and without:${dropped:- (none)}"
  echo "::warning::$flag_note"
fi
mkdir -p /opt/xcc
for pair in "g++-${HOST_GCC}:$real_cxx" "gcc-${HOST_GCC}:$real_cc"; do
  name=${pair%%:*} real=${pair#*:}
  cat > "/opt/xcc/$name" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  case "\$a" in
    -march=native) args+=($flags) ;;
    -mtune=native) ;;
    *) args+=("\$a") ;;
  esac
done
exec $real "\${args[@]}"
EOF
  chmod +x "/opt/xcc/$name"
done
# what the build half reads back
cat > /opt/xcc/toolchain.env <<EOF
TC_PATH_PREFIX='${cuda_bin}'
TC_NVCC_REL='${nvcc_rel}'
TC_CPU_FLAGS='${flags}'
TC_FLAG_NOTE='${flag_note}'
TC_CXX='/opt/xcc/g++-${HOST_GCC}'
TC_REAL_CXX='${real_cxx}'
EOF
cat /opt/xcc/toolchain.env
echo "::endgroup::"
