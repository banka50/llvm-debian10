#!/usr/bin/env bash
# Reproducible LLVM/Clang toolchain builds for Debian. See README.md.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config/versions.env
source "$REPO/config/versions.env"

# ---- Settings (override through the environment) ----------------------------
DISTRO=${DISTRO:-buster}
ARCH=${ARCH:-$(uname -m)}
JOBS=${JOBS:-$(nproc)}
# Only the host's backend by default (the runtimes are built for the host
# only anyway); e.g. TARGETS="X86;AArch64" or TARGETS=all for cross-compiling.
case $ARCH in
    x86_64) TARGETS=${TARGETS:-X86} ;;
    aarch64) TARGETS=${TARGETS:-AArch64} ;;
    *) TARGETS=${TARGETS:-Native} ;;
esac
PROJECTS=${PROJECTS:-clang;lld}
PGO=${PGO:-ON}
LTO=${LTO:-Thin}
INSTALL_MODE=${INSTALL_MODE:-toolchain}
EXTRA_CMAKE_ARGS=${EXTRA_CMAKE_ARGS:-}
WORK_DIR=${WORK_DIR:-$REPO/build/$DISTRO-$ARCH}
OUT_DIR=${OUT_DIR:-$REPO/out}
TEST_DISTROS=${TEST_DISTROS:-$DISTRO}
DOCKER=${DOCKER:-docker}

usage() {
    cat <<EOF
Usage: ./build.sh [command...]

Commands (default: all):
  fetch     download and verify all pinned inputs into sources/
  image     build the builder image for \$DISTRO
  stage1    build stage 1 (host gcc -> clang, lld)
  pgo       build an instrumented clang and collect a PGO profile
  stage2    build stage 2 (stage-1 clang -> clang, lld, runtimes)
  package   create out/llvm-<version>-<arch>-<distro>.tar.xz
  build     stage1 + pgo + stage2 + package (pgo is skipped with PGO=OFF)
  test      run smoke tests of the package on \$TEST_DISTROS
  all       fetch + image + build + test
  shell     interactive shell in the builder container
  clean     remove \$WORK_DIR

Settings (environment variables):
  DISTRO=$DISTRO            buster | bullseye | bookworm | trixie
  JOBS=$JOBS
  TARGETS=$TARGETS             LLVM_TARGETS_TO_BUILD for the final compiler
  PROJECTS=$PROJECTS     e.g. "clang;lld;clang-tools-extra"
  PGO=$PGO                   ON | OFF: optimise the compiler with a training profile
  LTO=$LTO                 Thin | Full | OFF: link-time optimisation of the compiler
  INSTALL_MODE=$INSTALL_MODE   toolchain | full (full also ships LLVM/Clang libs and headers)
  EXTRA_CMAKE_ARGS=...      extra arguments for the stage 2 cmake invocation
  WORK_DIR=$WORK_DIR
  OUT_DIR=$OUT_DIR
  TEST_DISTROS="$TEST_DISTROS"   distros to run the smoke tests on
EOF
}

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

load_distro() {
    local f=$REPO/distros/$1/distro.env
    [[ -f $f ]] || die "unknown distro '$1' (available: $(cd "$REPO/distros" && echo *))"
    unset DISTRO_NAME BASE_IMAGE BUILD_PYTHON
    # shellcheck disable=SC1090
    source "$f"
}

load_distro "$DISTRO"
[[ $ARCH == "$(uname -m)" ]] || die "only native builds are supported (host is $(uname -m), ARCH=$ARCH)"
case $INSTALL_MODE in toolchain | full) ;; *) die "INSTALL_MODE must be toolchain or full" ;; esac
case $PGO in ON | OFF) ;; *) die "PGO must be ON or OFF" ;; esac

IMAGE=llvm-debian-builder:$DISTRO-$ARCH
PKG_NAME=llvm-$LLVM_VERSION-$ARCH-$DISTRO_NAME
REPO_REVISION=$(git -C "$REPO" describe --always --dirty --abbrev=12 2>/dev/null || echo unknown)
export LLVM_VERSION SOURCE_DATE_EPOCH DISTRO DISTRO_NAME BASE_IMAGE ARCH JOBS TARGETS \
    PROJECTS PGO LTO INSTALL_MODE EXTRA_CMAKE_ARGS REPO_REVISION

cmd_fetch() {
    log "Fetching sources"
    ARCH=$ARCH "$REPO/scripts/fetch-sources.sh"
}

cmd_image() {
    log "Building builder image $IMAGE (base: $BASE_IMAGE)"
    $DOCKER build \
        --file "$REPO/docker/Dockerfile" \
        --build-arg BASE_IMAGE="$BASE_IMAGE" \
        --build-arg DISTRO="$DISTRO" \
        --build-arg ARCH="$ARCH" \
        --build-arg BUILD_PYTHON="$BUILD_PYTHON" \
        --build-arg CMAKE_VERSION="$CMAKE_VERSION" \
        --build-arg NINJA_VERSION="$NINJA_VERSION" \
        --build-arg ZSTD_VERSION="$ZSTD_VERSION" \
        --build-arg PYTHON_VERSION="$PYTHON_VERSION" \
        --tag "$IMAGE" \
        "$REPO"
}

run_container() {
    mkdir -p "$WORK_DIR" "$OUT_DIR"
    local tty=()
    [[ -t 0 && -t 1 ]] && tty=(--interactive --tty)
    # seccomp=unconfined: the PGO training runs the instrumented compiler with
    # ASLR disabled (setarch -R) to get identical profiles on every run, and
    # Docker's default seccomp profile forbids personality(ADDR_NO_RANDOMIZE).
    $DOCKER run --rm --init "${tty[@]}" \
        --security-opt seccomp=unconfined \
        --user "$(id -u):$(id -g)" \
        --env HOME=/tmp \
        --env LLVM_VERSION --env SOURCE_DATE_EPOCH --env DISTRO --env DISTRO_NAME \
        --env BASE_IMAGE --env ARCH --env JOBS --env TARGETS --env PROJECTS --env PGO --env LTO \
        --env INSTALL_MODE --env EXTRA_CMAKE_ARGS --env REPO_REVISION \
        --volume "$REPO:/repo:ro" \
        --volume "$WORK_DIR:/work" \
        --volume "$OUT_DIR:/out" \
        --workdir /work \
        "$IMAGE" "$@"
}

ensure_image() {
    $DOCKER image inspect "$IMAGE" >/dev/null 2>&1 || cmd_image
}

cmd_stage1() { ensure_image; run_container /repo/scripts/container-build.sh stage1; }
cmd_pgo() { ensure_image; run_container /repo/scripts/container-build.sh pgo; }
cmd_stage2() { ensure_image; run_container /repo/scripts/container-build.sh stage2; }
cmd_package() { ensure_image; run_container /repo/scripts/container-build.sh package; }
cmd_build() {
    local steps=(stage1 pgo stage2 package)
    [[ $PGO == ON ]] || steps=(stage1 stage2 package)
    ensure_image
    run_container /repo/scripts/container-build.sh "${steps[@]}"
}
cmd_shell() { ensure_image; run_container bash; }

# Expands TEST_DISTROS=compatible to the build distro and every newer one.
test_distros() {
    if [[ $TEST_DISTROS != compatible ]]; then
        echo "$TEST_DISTROS"
        return
    fi
    local d n self=${DISTRO_NAME#debian}
    for d in "$REPO"/distros/*/; do
        d=$(basename "$d")
        # shellcheck disable=SC1090
        n=$(source "$REPO/distros/$d/distro.env" && echo "${DISTRO_NAME#debian}")
        ((n >= self)) && echo "$n $d"
    done | sort -n | cut -d' ' -f2 | tr '\n' ' '
}

cmd_test() {
    local tarball=$OUT_DIR/$PKG_NAME.tar.xz
    [[ -f $tarball ]] || die "$tarball not found, run './build.sh build' first"
    local td
    for td in $(test_distros); do
        (
            load_distro "$td"
            log "Smoke tests of $PKG_NAME on $td ($BASE_IMAGE)"
            # seccomp=unconfined: TSan re-execs itself with ASLR disabled
            # (personality(ADDR_NO_RANDOMIZE)), which Docker's default seccomp
            # profile forbids.
            $DOCKER run --rm --init \
                --security-opt seccomp=unconfined \
                --volume "$tarball:/pkg/toolchain.tar.xz:ro" \
                --volume "$REPO/tests:/tests:ro" \
                --volume "$REPO/distros/$td/sources.list:/pkg/sources.list:ro" \
                "$BASE_IMAGE" /tests/smoke-test.sh
        )
    done
}

cmd_clean() {
    log "Removing $WORK_DIR"
    rm -rf "$WORK_DIR"
}

cmd_all() {
    cmd_fetch
    cmd_image
    cmd_build
    cmd_test
}

[[ $# -gt 0 ]] || set -- all
for cmd in "$@"; do
    case $cmd in
        fetch | image | stage1 | pgo | stage2 | package | build | test | all | shell | clean) "cmd_$cmd" ;;
        -h | --help | help) usage ;;
        *) usage >&2; die "unknown command '$cmd'" ;;
    esac
done
