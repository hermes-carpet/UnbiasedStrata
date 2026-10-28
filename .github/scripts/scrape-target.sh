#!/usr/bin/env bash
# Run ON the machine the binaries are for. It profiles the box (distro, glibc, CUDA toolkit
# and where it came from, GPUs + compute capability, driver, the flags gcc resolves for
# -march=native), commits that as .github/targets/<name>.env to hermes-carpet/UnbiasedStrata,
# asks GitHub Actions to build for it, and follows the run.
#
#   curl -fsSL https://raw.githubusercontent.com/hermes-carpet/UnbiasedStrata/main/.github/scripts/scrape-target.sh | bash -s -- [name]
#   (or: bash scrape-target.sh [name] [--dry-run])
#
# name defaults to the hostname. Needs `gh` signed in as hermes-carpet (`gh auth login`), or
# GH_TOKEN set. Writes nothing to disk except a temp file under /tmp.
set -euo pipefail

REPO=hermes-carpet/UnbiasedStrata
NAME=""; DRY=0
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; *) NAME=$a ;; esac; done
NAME=${NAME:-$(hostname -s)}
die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -m)" = x86_64 ] || die "only x86_64 targets are supported (this is $(uname -m))"
. /etc/os-release

# --- CUDA toolkit: version and source --------------------------------------------------
NVCC=$(command -v nvcc || true)
[ -n "$NVCC" ] || for p in /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc; do [ -x "$p" ] && NVCC=$p && break; done
[ -n "$NVCC" ] || die "nvcc not found: install the CUDA toolkit the binaries should link against"
CUDA_VERSION=$("$NVCC" --version | sed -nE 's/.*, V([0-9.]+)$/\1/p')
real_nvcc=$(readlink -f "$NVCC")
if dpkg -S "$real_nvcc" 2>/dev/null | grep -q '^nvidia-cuda-toolkit'; then CUDA_SOURCE=debian-apt
elif dpkg -S "$real_nvcc" 2>/dev/null | grep -q '^cuda-nvcc'; then CUDA_SOURCE=nvidia-repo
else CUDA_SOURCE=nvidia-repo; echo "note: nvcc ($real_nvcc) is not from a .deb (runfile install?); CI will use NVIDIA's apt repo for ${CUDA_VERSION}" >&2
fi

# --- GPUs ---------------------------------------------------------------------------------
command -v nvidia-smi >/dev/null || die "nvidia-smi not found (no NVIDIA driver?)"
gpu_rows=$(nvidia-smi --query-gpu=name,compute_cap,driver_version --format=csv,noheader)
DRIVER=$(head -1 <<<"$gpu_rows" | awk -F', ' '{print $3}')
GPUS=$(awk -F', ' '{gsub(/\./,"",$2); print $1" (sm_"$2")"}' <<<"$gpu_rows" | sort | uniq -c | sed -E 's/^ *([0-9]+) /\1x /' | paste -sd ';' | sed 's/;/; /g')
CUDA_ARCHS=$(awk -F', ' '{gsub(/\./,"",$2); print $2"-real"}' <<<"$gpu_rows" | sort -u | paste -sd ';')

# --- host compiler: the newest gcc this nvcc accepts (same probe as upstream's Makefile) ---
HOST_GCC=""
t=$(mktemp /tmp/scrape-XXXXXX.cu); printf 'int main(){return 0;}\n' > "$t"
for v in 15 14 13 12 11; do
  c=$(command -v "g++-$v" || true); [ -n "$c" ] || continue
  if "$NVCC" -ccbin "$c" -c "$t" -o /dev/null >/dev/null 2>&1; then HOST_GCC=$v; break; fi
done
rm -f "$t"
[ -n "$HOST_GCC" ] || die "no g++-NN that $NVCC accepts (CUDA 12.4 needs g++-13 or older: apt install g++-13)"

# --- CPU: what -march=native means here, resolved by that same gcc ------------------------
gcc_bin=$(command -v "gcc-$HOST_GCC")
CPU_MODEL=$(sed -nE 's/^model name\s*:\s*//p' /proc/cpuinfo | head -1)
cc1=$("$gcc_bin" -march=native -E -v - </dev/null 2>&1 | grep -m1 '/cc1 ')
CPU_MARCH=$(grep -oE -- '-march=[^ ]+' <<<"$cc1" | head -1 | cut -d= -f2)
CPU_FLAGS=$(tr ' ' '\n' <<<"$cc1" | grep -E -- '^-m(arch|tune|[a-z0-9])|^--param=' | grep -v -- '^-mtune=generic$' | paste -sd ' ')
[ -n "$CPU_MARCH" ] || die "could not resolve -march=native with $gcc_bin"

GLIBC=$(getconf GNU_LIBC_VERSION | awk '{print $2}')
IMAGE="${ID}:${VERSION_ID}"

profile=$(mktemp /tmp/target-XXXXXX.env)
trap 'rm -f "$profile"' EXIT
cat > "$profile" <<EOF
# Build target profile, scraped on $(hostname -s) by .github/scripts/scrape-target.sh.
TARGET_NAME='$NAME'
SCRAPED='$(date -u +%FT%TZ) on $(hostname -s)'
IMAGE='$IMAGE'
CUDA_SOURCE='$CUDA_SOURCE'
CUDA_VERSION='$CUDA_VERSION'
CUDA_ARCHS='$CUDA_ARCHS'
HOST_GCC='$HOST_GCC'
GPUS='$GPUS'
DRIVER='$DRIVER'
KERNEL='$(uname -r)'
GLIBC='$GLIBC'
CPU_MODEL='$CPU_MODEL'
CPU_MARCH='$CPU_MARCH'
CPU_FLAGS='$CPU_FLAGS'
EOF
echo "=== profile for target '$NAME' ==="; cat "$profile"; echo

# CUDA 12.4 needs driver >= 550.54.14 on Linux (550.x is what 12.4 shipped with)
drv_major=${DRIVER%%.*}
[ "${CUDA_VERSION%%.*}" != 12 ] || [ "$drv_major" -ge 525 ] || echo "WARNING: driver $DRIVER is older than CUDA 12.x minimum compatibility (525)" >&2

[ "$DRY" = 0 ] || { echo "(dry run: nothing pushed)"; exit 0; }

command -v gh >/dev/null || die "gh not installed: sudo apt install gh && gh auth login"
gh auth status >/dev/null 2>&1 || [ -n "${GH_TOKEN:-}" ] || die "gh is not signed in: gh auth login (as hermes-carpet)"
who=$(gh api user --jq .login)
[ "$who" = hermes-carpet ] || echo "note: signed in as $who, not hermes-carpet" >&2

path=".github/targets/${NAME}.env"
old_sha=$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)
old=$( [ -n "$old_sha" ] && gh api "repos/$REPO/contents/$path" --jq .content | base64 -d || true)
# ignore the SCRAPED line when deciding whether anything changed
if [ -n "$old" ] && diff <(grep -v '^SCRAPED=\|^#' <<<"$old") <(grep -v '^SCRAPED=\|^#' "$profile") >/dev/null; then
  echo "profile unchanged in $REPO; not committing"
else
  [ -z "$old" ] || { echo "=== changes vs the committed profile ==="; diff <(echo "$old") "$profile" || true; }
  args=(-X PUT "repos/$REPO/contents/$path" -f "message=target: ${NAME} profile scraped on $(hostname -s)"
        -f "content=$(base64 -w0 "$profile")")
  [ -z "$old_sha" ] || args+=(-f "sha=$old_sha")
  gh api "${args[@]}" --jq '.commit.html_url'
fi

before=$(date -u +%FT%TZ)
gh workflow run autobuild.yml --repo "$REPO" -f target="$NAME" -f force=true
echo "build requested; waiting for the run to appear..."
run=""
for _ in $(seq 1 20); do
  sleep 3
  run=$(gh run list --repo "$REPO" --workflow autobuild.yml --event workflow_dispatch --limit 5 \
         --json databaseId,createdAt --jq "[.[] | select(.createdAt >= \"$before\")][0].databaseId // empty")
  [ -n "$run" ] && break
done
[ -n "$run" ] || die "run not found; see https://github.com/$REPO/actions"
echo "https://github.com/$REPO/actions/runs/$run  (build takes ~1h; Ctrl-C stops watching, not the build)"
gh run watch "$run" --repo "$REPO" --interval 60 --exit-status \
  && echo "done: https://github.com/$REPO/releases/latest"
