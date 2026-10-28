# UnbiasedStrata — auto-built binaries

Fork of [robertkarl/UnbiasedStrata](https://github.com/robertkarl/UnbiasedStrata) that **only adds CI**:
upstream's code is untouched (everything here lives under `.github/`). GitHub Actions builds the engines
(`strata`, `strata-poly`, `strata-dsv41`, `libstrata_kq.so`) and the `unbiased-strata` front end
ahead of time for specific machines, and publishes them under **[Releases](../../releases)**.

Upstream's own README is [`/README.md`](../README.md).

## How it works

- **Daily** (06:41 UTC) [`autobuild`](workflows/autobuild.yml) polls upstream `main`. When it moved past the
  last published commit ([`upstream-sha`](upstream-sha)), it builds every target, publishes release
  `strata-<date>-<sha7>`, then merges that upstream commit into this fork's `main` and commits as
  `hermes-carpet` (that commit also keeps GitHub from disabling the cron; a 45-day-quiet upstream gets a
  keepalive commit).
- A failed build publishes nothing. It opens or comments on **one issue labelled `auto-build`**, and the next
  green run closes it.
- **Targets** are [`targets/<name>.env`](targets) profiles. Each is built in a container of the target's
  distro with the target's exact CUDA toolkit, **SASS-only for its GPU arch** (`86-real`: no PTX, no JIT), and
  ggml-cpu's `-march=native` replaced by the flags gcc resolves for `-march=native` *on the target CPU*.
  The result matches running `make build` on that box.
- **Fast rebuilds:** the toolchain half (distro, CUDA, gcc: ~2 min) only depends on the profile; the
  compile (~20 min cold) runs through **ccache** kept across runs, so an upstream commit recompiles only what
  it touched.
- **No GPU in CI.** Checks: upstream `make test` (front end vs. fake engine), nvcc version == target's,
  device code is exactly the target SASS, no unresolved libs except the driver's `libcuda.so.1`, glibc
  floor ≤ target's, `--help` smoke runs (best effort).

## Add or refresh a target

On the target machine, signed in to `gh` as hermes-carpet (`sudo apt install gh && gh auth login`):

```bash
curl -fsSL https://raw.githubusercontent.com/hermes-carpet/UnbiasedStrata/main/.github/scripts/scrape-target.sh | bash -s -- 3090-debian13
```

It profiles the box (distro, glibc, CUDA toolkit and where it came from, GPU model/compute capability,
CPU flags; no hostname, kernel, driver version or CPU model string: this repo is public), commits `targets/<name>.env` if it changed, dispatches a build for it and follows the run.
Add `--dry-run` to only print the profile.

## Packages

| File | Use |
|---|---|
| `unbiased-strata-<label>-<target>.tar.gz` | links the target's installed CUDA runtime (`libcudart.so.12`, `libcublas*.so.12`) |
| `unbiased-strata-<label>-<target>-cudalibs.tar.gz` | same, plus those libs in `bin/lib` (needs only the NVIDIA driver) |

`BUILDINFO.txt` inside each has the target profile, the exact flags and the CI check results.
