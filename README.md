# LLVM for Debian 10 (and newer)

Reproducible builds of a current LLVM toolchain that runs on **Debian 10
"buster"** (glibc 2.28) and every newer Debian release:

| Component   | What you get |
|-------------|--------------|
| clang 23.1.6 | C/C++/Objective-C compiler (all LLVM targets), `clang-format`, `clang-scan-deps`, `clang-repl`, scan-build, `libclang` |
| lld         | `ld.lld`, `wasm-ld`, `lld-link`, `ld64.lld`; LTO / ThinLTO |
| compiler-rt | builtins, crt, **ASan, UBSan, TSan, MSan, LSan, HWASan, DFSan, NSan, RTSan, TySan, SafeStack, CFI, Scudo, GWP-ASan, MemProf**, libFuzzer, XRay, profile/coverage runtime |
| libc++      | libc++, libc++abi, libunwind (shared and static), the `std` C++ module |
| LLVM tools  | `llvm-ar`, `llvm-nm`, `llvm-objdump`, `llvm-symbolizer`, `llvm-profdata`, `llvm-cov`, `llvm-dwarfdump`, `llvm-xray`, `sancov`, `opt`, `llc`, ... |

The official LLVM release binaries are built on recent Ubuntu and need a
newer glibc than Debian 10 has. This repository builds the toolchain inside a
Debian 10 container instead, from pinned and verified inputs, so that anyone
can rebuild it and get bit-for-bit the same tarball. Like the official
releases, the compiler is optimised with profile-guided optimisation (PGO)
and ThinLTO.

## Using a prebuilt package

Download `llvm-23.1.6-x86_64-debian10.tar.xz` from the
[releases](../../releases) page, check it, and unpack it anywhere (the tree is
relocatable; `/opt/llvm-23` is used below):

```bash
sha256sum -c llvm-23.1.6-x86_64-debian10.tar.xz.sha256
```

```bash
sudo mkdir -p /opt/llvm-23 && sudo tar -C /opt/llvm-23 --strip-components=1 -xJf llvm-23.1.6-x86_64-debian10.tar.xz
```

```bash
export PATH=/opt/llvm-23/bin:$PATH
```

The compiler needs the usual system headers and C runtime objects, which on
Debian come with the `libc6-dev`, `libgcc-*-dev` and `libstdc++-*-dev`
packages; installing `g++` pulls them all in.

### libc++

By default clang uses the system libstdc++. Pass `-stdlib=libc++` to use the
bundled libc++. The shared libraries live in
`lib/x86_64-unknown-linux-gnu/`, so either embed a run path, link libc++
statically, or ship the libraries with your program:

```bash
# shared libc++, found through RUNPATH
clang++ -std=c++23 -stdlib=libc++ -Wl,-rpath,/opt/llvm-23/lib/x86_64-unknown-linux-gnu main.cpp
# static libc++ and libc++abi, only glibc/libgcc_s are needed at run time
clang++ -std=c++23 -stdlib=libc++ -static-libstdc++ main.cpp
# fully static; glibc older than 2.34 (Debian 10, 11) needs -pthread for this
clang++ -std=c++23 -stdlib=libc++ -static -pthread main.cpp
```

`import std;` works too; build the module once, then use it:

```bash
clang++ -std=c++23 -stdlib=libc++ -Wno-reserved-module-identifier --precompile /opt/llvm-23/share/libc++/v1/std.cppm -o std.pcm
clang++ -std=c++23 -stdlib=libc++ -fmodule-file=std=std.pcm main.cpp std.pcm
```

### Sanitizers and friends

```bash
clang -g -fsanitize=address,undefined app.c   # ASan + UBSan
clang -g -fsanitize=thread app.c              # TSan
clang -g -fsanitize=memory app.c              # MSan
clang -g -fsanitize=fuzzer,address fuzz.c     # libFuzzer
clang -fprofile-instr-generate -fcoverage-mapping app.c   # coverage (llvm-profdata, llvm-cov)
clang++ -flto -fvisibility=hidden -fsanitize=cfi -fuse-ld=lld app.cpp   # CFI
```

* Keep `/opt/llvm-23/bin` in `PATH` (or set `ASAN_SYMBOLIZER_PATH` etc.)
  so reports are symbolized by `llvm-symbolizer`.
* MSan reports false positives for code that is not instrumented. C works out
  of the box; C++ needs a libc++ built with `-fsanitize=memory`, which is not
  part of the package.
* TSan disables ASLR for itself by re-executing with
  `personality(ADDR_NO_RANDOMIZE)`. Docker's default seccomp profile blocks
  that, so in containers run with `--security-opt seccomp=unconfined` (or run
  the program under `setarch -R`).
* HWASan on x86-64 needs Intel LAM support in the CPU and kernel; it is
  shipped but not covered by the smoke tests.

## Building it yourself

Requirements: a Linux x86-64 (or aarch64) machine with Docker, `curl`, about
40 GB of free disk space and ideally 16+ GB of RAM. `gpg` is optional (used to
check the LLVM source signature). Builds are always native: an x86-64 host
produces an x86-64 toolchain.

```bash
./build.sh all
```

This fetches and verifies the sources, builds the builder image, builds the
toolchain, packages it and runs the smoke tests. On a 28-thread machine a
clean build takes about 40 minutes (stage 1 ~8, PGO ~10, stage 2 ~19,
packaging ~4; with `LTO=OFF` stage 2 takes ~6); on a 4-vCPU GitHub runner it
is several hours. The build tree needs about 26 GB; the package is ~610 MB
(3.3 GB unpacked). Results land in `out/`:

```
out/llvm-23.1.6-x86_64-debian10.tar.xz          the toolchain
out/llvm-23.1.6-x86_64-debian10.tar.xz.sha256
out/llvm-23.1.6-x86_64-debian10.BUILD-INFO.txt  what went into it
```

The steps can also be run one at a time:

| Command | Does |
|---------|------|
| `./build.sh fetch`   | download everything in `config/sources.lock` into `sources/` and verify it |
| `./build.sh image`   | build the builder image `llvm-debian-builder:<distro>-<arch>` |
| `./build.sh stage1`  | stage 1: the distro's gcc builds a minimal clang + lld |
| `./build.sh pgo`     | build an instrumented clang, run the training workload, write `clang.profdata` |
| `./build.sh stage2`  | stage 2: the stage-1 clang builds the final toolchain (with the profile) and the runtimes |
| `./build.sh package` | produce the tarball in `out/` |
| `./build.sh build`   | stage1 + pgo + stage2 + package |
| `./build.sh test`    | smoke tests in clean containers of `$TEST_DISTROS` |
| `./build.sh shell`   | a shell in the builder container, with the build tree mounted |
| `./build.sh clean`   | delete the build tree |

Settings are environment variables:

| Variable | Default | Meaning |
|----------|---------|---------|
| `DISTRO` | `buster` | Debian release to build on: `buster`, `bullseye`, `bookworm`, `trixie`. The result runs on that release and newer ones. |
| `JOBS` | `nproc` | parallel jobs |
| `TARGETS` | `all` | `LLVM_TARGETS_TO_BUILD` of the final compiler, e.g. `X86;AArch64` for a faster build |
| `PROJECTS` | `clang;lld` | e.g. `clang;lld;clang-tools-extra` to add clangd and clang-tidy |
| `PGO` | `ON` | `OFF` skips the instrumented build and training (faster build, slower compiler) |
| `LTO` | `Thin` | LTO of the compiler and tools: `Thin`, `Full` (much slower to build, needs a lot of RAM) or `OFF` (stage 2 about three times faster to build, slightly slower compiler). The runtimes are never built with LTO. |
| `INSTALL_MODE` | `toolchain` | `full` additionally ships the LLVM/Clang libraries, headers and CMake packages (for building plugins and tools against LLVM); with LTO they are built as FatLTO objects, so any linker can use them |
| `EXTRA_CMAKE_ARGS` | | extra arguments for the stage 2 `cmake` |
| `WORK_DIR` | `build/<distro>-<arch>` | build tree |
| `OUT_DIR` | `out` | results |
| `TEST_DISTROS` | `$DISTRO` | space-separated distros to test on, or `compatible` for the build distro and all newer ones |

Changing `TARGETS`, `PROJECTS`, `PGO`, `LTO`, `INSTALL_MODE` or `EXTRA_CMAKE_ARGS`
changes the output, and they are recorded in `BUILD-INFO.txt`. `JOBS`,
`WORK_DIR` and `OUT_DIR` do not affect the result.

### How the build works

```
 Debian 10 container (pinned image, frozen apt archive, no network)
 ┌──────────────────────────────────────────────────────────────────────┐
 │ stage 1   gcc 8.3  ──►  clang + lld + llvm-ar/... + profile runtime  │
 │                         (host target only)                           │
 │ pgo       stage-1 clang  ──►  instrumented clang                     │
 │           instrumented clang compiles a fixed training set           │
 │           (LLVM Support, IR, Clang Sema; -O3 and -O0 -g)             │
 │           ──►  clang.profdata                                        │
 │ stage 2   stage-1 clang/lld + profile  ──►  clang, lld, LLVM tools   │
 │           (PGO + ThinLTO; only what gets installed is built)         │
 │           stage-2 clang      ──►  compiler-rt, libc++, libc++abi,    │
 │                                   libunwind                          │
 │ package   install/strip, licenses, BUILD-INFO, deterministic tar.xz  │
 └──────────────────────────────────────────────────────────────────────┘
```

The final binaries depend only on glibc (2.27 or newer), libstdc++/libgcc and
zlib, which every Debian installation has; zstd is linked statically,
libxml2, libedit and terminfo are not used.

### What PGO and ThinLTO buy

Compile time (CPU seconds, best of 5) of sources that are *not* part of the
PGO training set, with three builds of the same configuration:
`PGO=OFF LTO=OFF`, `PGO=ON LTO=OFF` and the default `PGO=ON LTO=Thin`:

| Source | Mode | plain | PGO | PGO + ThinLTO |
|--------|------|------:|----:|--------------:|
| `llvm/lib/Analysis/ScalarEvolution.cpp` | `-O3` | 6.91 s | 5.33 s | 5.16 s |
| `llvm/lib/Analysis/ScalarEvolution.cpp` | `-O0 -g` | 3.03 s | 2.28 s | 2.25 s |
| `llvm/lib/Transforms/Vectorize/LoopVectorize.cpp` | `-O3` | 6.34 s | 4.81 s | 4.67 s |
| `llvm/lib/Transforms/Vectorize/LoopVectorize.cpp` | `-O0 -g` | 4.03 s | 3.06 s | 3.00 s |
| `clang/lib/AST/ExprConstant.cpp` | `-O3` | 8.85 s | 7.02 s | 6.77 s |
| `clang/lib/AST/ExprConstant.cpp` | `-O0 -g` | 4.15 s | 3.16 s | 3.08 s |
| **total, speed-up vs. plain** | `-O3` | | **29 %** | **33 %** |
| **total, speed-up vs. plain** | `-O0 -g` | | **32 %** | **35 %** |

PGO does most of the work; ThinLTO adds 2–3 % on top, at the price of a
three times longer stage 2 and ~7 % larger binaries. The instrumented build
is host-target only, so code of the other backends has no profile and is
optimised as usual rather than treated as cold.

### Reproducibility

Everything that goes into a build is pinned:

* **Base image** by digest (`distros/<distro>/distro.env`).
* **Debian packages** from an archive that no longer changes: for buster,
  `archive.debian.org`; for the other releases, a fixed
  `snapshot.debian.org` timestamp (`distros/<distro>/sources.list`).
* **Sources** of LLVM, CMake, Ninja, zstd and Python by SHA-256
  (`config/sources.lock`); the LLVM tarball is also checked against the LLVM
  release signing keys in `keys/`.
* **Build configuration** in `cmake/stage1.cmake` and `cmake/stage2.cmake`.

PGO profiles are normally not reproducible: clang hashes pointers, so with
ASLR the branch counts differ from run to run, and CMake's compiler checks
use random directory names. The training here therefore replays compile
commands from a `compile_commands.json` (nothing is configured with the
instrumented compiler), runs every compile with ASLR disabled
(`setarch -R`) and a fixed environment, and merges the raw profiles
single-threaded in job order, in chunks of a fixed size that does not depend
on `JOBS` (see [scripts/pgo-train.py](scripts/pgo-train.py)). The only counts
that still vary are in a few functions keyed by file inode numbers (clang's
`FileManager` maps over `llvm::sys::fs::UniqueID`); they are dropped from the
profile. Disabling ASLR needs the
`personality` syscall, which Docker's default seccomp profile blocks, so
the build container runs with `--security-opt seccomp=unconfined`.

Incremental rebuilds give the same result as clean ones: whenever a build
tree's CMake cache script (`cmake/*.cmake`) or CMake arguments change, or the
compiler that builds it changes (new stage 1, new builder image, new PGO
profile), the tree is deleted and built again. A fresh CMake cache is not
enough: the runtimes are configured halfway through stage 2 with the new
clang, and their CMake checks see whatever the tree already contains (an
old libc++, for example, changes how `libc++.so` is linked). For the same
reason C++ module scanning is switched off for the runtimes; otherwise it
would depend on whether `clang-scan-deps` happens to be linked before the
runtimes are configured. ThinLTO itself is deterministic: its output does
not depend on the number of threads or on its cache.

The build runs in the container at fixed paths (`/repo`, `/work`, `/out`)
under `LC_ALL=C.UTF-8`, `TZ=UTC`, with no VCS revision in version strings
(`LLVM_APPEND_VC_REV=OFF`). The package is a tar with sorted entries,
owner `0:0` and every timestamp set to `SOURCE_DATE_EPOCH` (the LLVM release
date, from `config/versions.env`), compressed by `xz` with a fixed thread
count.

This has been verified: a complete build from empty build trees
(`JOBS=28`) and a clean stage 2 in another directory, run at the same time
(`JOBS=12`), produced the same `llvm-23.1.6-x86_64-debian10.tar.xz`, byte
for byte; stage 1 and the PGO profile also came out identical to those of
earlier builds.

To check a release, build the same tag and compare checksums:

```bash
git checkout v23.1.6-1
./build.sh fetch image build
sha256sum out/*.tar.xz      # compare with the .sha256 file of the release
```

### Updating LLVM

```bash
./scripts/update-llvm.sh 23.1.7   # pins the new release and verifies it
./build.sh all
```

The other pinned inputs are updated by editing `config/versions.env` and
`config/sources.lock` together. Patches for a release go into
`patches/<major>/` (see [patches/README.md](patches/README.md)).

### Other Debian releases

`DISTRO=bookworm ./build.sh all` builds on Debian 12 instead. A build on an
older release also runs on all newer ones, so the Debian 10 build is the one
to use unless you specifically want a newer baseline. To add a release, copy
one of the directories in `distros/` and update the image digest and the
snapshot date.

## CI and releases

[`.github/workflows/build.yml`](.github/workflows/build.yml) builds on
GitHub-hosted runners. Stage 1, the PGO training and stage 2 run as separate
jobs to stay under the 6-hour job limit; the package is then tested on
Debian 10–13.

* **Run workflow** (manual): choose the Debian release, architecture,
  targets and LTO (`OFF` if a ThinLTO stage 2 does not fit into the time
  limit).
* **Push a tag** `v<llvm version>-<n>`, e.g. `v23.1.6-1`: builds the Debian 10
  x86-64 package and publishes it as a GitHub release.

## Repository layout

```
build.sh                 entry point
config/versions.env      LLVM and tool versions, SOURCE_DATE_EPOCH
config/sources.lock      URL + SHA-256 of every downloaded input
distros/<name>/          base image digest and pinned apt sources per Debian release
docker/                  builder image
cmake/stage{1,2}.cmake   CMake configuration of the two stages
scripts/                 fetch, in-container build, PGO training, LLVM version bump
tests/                   smoke tests run against the finished package
keys/                    LLVM release signing keys
patches/                 optional patches to the LLVM sources
```

## License

The scripts in this repository are under the MIT license (see
[LICENSE](LICENSE)). LLVM itself is under the Apache License 2.0 with LLVM
Exceptions; the license files of all included LLVM projects are in
`LICENSES/` inside the package.
