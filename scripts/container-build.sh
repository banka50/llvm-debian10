#!/usr/bin/env bash
# Runs inside the builder container (started by ./build.sh).
# Usage: container-build.sh <step>...    steps: stage1 pgo stage2 package
#
# Fixed paths inside the container (identical on every machine, which keeps
# the output independent of where the repository is checked out):
#   /repo  this repository (read-only), including sources/
#   /work  build tree
#   /out   results
set -euo pipefail

: "${LLVM_VERSION:?}" "${SOURCE_DATE_EPOCH:?}" "${DISTRO:?}" "${DISTRO_NAME:?}" "${ARCH:?}" "${BASE_IMAGE:?}"
JOBS=${JOBS:-$(nproc)}
TARGETS=${TARGETS:-Native}
PROJECTS=${PROJECTS:-clang;lld}
RUNTIMES="compiler-rt;libcxx;libcxxabi;libunwind"
LTO=${LTO:-Thin}
PGO=${PGO:-ON}
INSTALL_MODE=${INSTALL_MODE:-toolchain}
EXTRA_CMAKE_ARGS=${EXTRA_CMAKE_ARGS:-}
REPO_REVISION=${REPO_REVISION:-unknown}

LLVM_MAJOR=${LLVM_VERSION%%.*}
SRC=/work/llvm-project
STAGE1_BUILD=/work/stage1-build
STAGE1=/work/stage1-install
STAGE2_BUILD=/work/stage2-build
PGO_BUILD=/work/pgo-instrumented
PGO_TRAIN=/work/pgo-training
PGO_PROFILES=/work/pgo-profiles
PROFDATA=/work/clang.profdata
DESTDIR=/work/destdir
PKG_ROOT=/work/package
PREFIX=/opt/llvm-$LLVM_MAJOR
PKG_NAME=llvm-$LLVM_VERSION-$ARCH-$DISTRO_NAME
PATCH_DIR=/repo/patches/$LLVM_MAJOR
PYTHON=$(command -v python3)

export LC_ALL=C.UTF-8 TZ=UTC PYTHONHASHSEED=0 PYTHONDONTWRITEBYTECODE=1 SOURCE_DATE_EPOCH
umask 022

log() { printf '\n==> [%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# Limit concurrent links by memory: GNU ld (stage 1) needs a few GB per link,
# ThinLTO links use all cores and much more memory.
mem_gb=$(awk '/^MemTotal:/ {print int($2 / 1048576)}' /proc/meminfo)
link_jobs() {
    local per_link=$1 n
    n=$((mem_gb / per_link))
    ((n < 1)) && n=1
    ((n > JOBS)) && n=$JOBS
    echo "$n"
}

patches() {
    [[ -d $PATCH_DIR ]] || return 0
    find "$PATCH_DIR" -maxdepth 1 -name '*.patch' | LC_ALL=C sort
}

# Identifies the exact sources (release + patches) a tree was built from.
source_id() {
    echo "$LLVM_VERSION $(patches | xargs -r cat | sha256sum | cut -d' ' -f1)"
}

# configure <build dir> <cmake args...>
# A -C cache script only fills in values that are not in CMakeCache.txt yet,
# so edits to cmake/*.cmake would silently not apply to an existing tree.
# Whenever the arguments or the cache script (-C) change, start from an empty
# tree, so an incremental build is configured exactly like a fresh one.
configure() {
    local dir=$1 id prev='' arg
    local -a caches=()
    shift
    for arg; do
        [[ $prev == -C ]] && caches+=("$arg")
        prev=$arg
    done
    id=$({ printf '%s\n' "$@"; cat "${caches[@]}" </dev/null; } | sha256sum | cut -d' ' -f1)
    if [[ -f $dir/CMakeCache.txt && $(cat "$dir/.configure-id" 2>/dev/null) != "$id" ]]; then
        # Dropping the caches is not enough: the runtimes are configured
        # with the freshly built clang, and what their CMake checks find
        # depends on what the tree already contains (e.g. a libc++ from an
        # earlier build makes CMake skip the build-tree RPATH of libc++.so).
        log "Configuration of $dir changed, starting from an empty tree"
        rm -rf "$dir"
    fi
    cmake -G Ninja -S "$SRC/llvm" -B "$dir" "$@"
    echo "$id" >"$dir/.configure-id"
}

# fresh_if_toolchain_changed <build dir> <file>...
# Ninja tracks the paths of the compiler and of the PGO profile, not their
# contents. If any of the given files (compiler binaries, profile, ...)
# changed since the tree was last built, delete the tree so that no object
# built by the old toolchain survives.
fresh_if_toolchain_changed() {
    local dir=$1 id
    shift
    id=$(sha256sum "$@" | sha256sum | cut -d' ' -f1)
    if [[ -d $dir && $(cat "$dir/.toolchain-id" 2>/dev/null) != "$id" ]]; then
        log "Toolchain of $dir changed, starting it from scratch"
        rm -rf "$dir"
    fi
    mkdir -p "$dir"
    echo "$id" >"$dir/.toolchain-id"
}

# Files that define the stage-1 toolchain (for fresh_if_toolchain_changed).
stage1_toolchain_files() {
    local t=$STAGE1/bin
    readlink -f "$t/clang" "$t/lld" "$t/llvm-ar" "$t/llvm-objcopy" "$t/llvm-nm"
    echo "$STAGE1/lib/clang/$LLVM_MAJOR/lib/$(uname -m)-unknown-linux-gnu/libclang_rt.profile.a"
}

step_extract() {
    local tarball=/repo/sources/llvm-project-$LLVM_VERSION.src.tar.xz id p
    [[ -f $tarball ]] || die "$tarball not found, run './build.sh fetch'"
    id=$(source_id)
    if [[ -f $SRC/.source-id ]]; then
        [[ $(<"$SRC/.source-id") == "$id" ]] && return 0
        # Different sources invalidate every build tree.
        log "Sources changed, removing old build trees"
        rm -rf "$STAGE1_BUILD" "$STAGE1" "$PGO_BUILD" "$PGO_TRAIN" "$PGO_PROFILES" \
            "$PROFDATA" "$PROFDATA.source-id" "$STAGE2_BUILD" "$DESTDIR" "$PKG_ROOT"
    fi
    log "Extracting $(basename "$tarball")"
    rm -rf "$SRC"
    mkdir -p "$SRC"
    tar -C "$SRC" --strip-components=1 -xJf "$tarball"
    for p in $(patches); do
        log "Applying patch $(basename "$p")"
        patch -d "$SRC" -p1 --forward --batch <"$p"
    done
    echo "$id" >"$SRC/.source-id"
}

step_stage1() {
    step_extract
    log "Stage 1: $(gcc --version | head -n1) -> clang, lld"
    # The builder image (compiler, libraries) is the toolchain of stage 1.
    fresh_if_toolchain_changed "$STAGE1_BUILD" /opt/tools/TOOLS.txt /opt/tools/PACKAGES.txt
    configure "$STAGE1_BUILD" \
        -C /repo/cmake/stage1.cmake \
        -DCMAKE_C_COMPILER=gcc \
        -DCMAKE_CXX_COMPILER=g++ \
        -DCMAKE_INSTALL_PREFIX="$STAGE1" \
        -DPython3_EXECUTABLE="$PYTHON" \
        -DLLVM_PARALLEL_LINK_JOBS="$(link_jobs 4)"
    ninja -C "$STAGE1_BUILD" -j "$JOBS" install
    source_id >"$STAGE1/.source-id"
}

check_stage1() {
    [[ -x $STAGE1/bin/clang ]] || die "stage 1 is not built, run './build.sh stage1'"
    [[ -f $STAGE1/.source-id && $(<"$STAGE1/.source-id") == "$(source_id)" ]] ||
        die "stage 1 in $STAGE1 was built from different sources, run './build.sh stage1'"
}

# CMake arguments for a build compiled by the stage-1 toolchain with the
# stage 2 configuration (used for the final build and the PGO builds).
stage1_toolchain_args() {
    local t=$STAGE1/bin
    printf '%s\n' \
        -C /repo/cmake/stage2.cmake \
        -DCMAKE_C_COMPILER="$t/clang" \
        -DCMAKE_CXX_COMPILER="$t/clang++" \
        -DCMAKE_ASM_COMPILER="$t/clang" \
        -DCMAKE_AR="$t/llvm-ar" \
        -DCMAKE_RANLIB="$t/llvm-ranlib" \
        -DCMAKE_NM="$t/llvm-nm" \
        -DCMAKE_OBJCOPY="$t/llvm-objcopy" \
        -DCMAKE_OBJDUMP="$t/llvm-objdump" \
        -DCMAKE_STRIP="$t/llvm-strip" \
        -DPython3_EXECUTABLE="$PYTHON"
}

# Profile-guided optimisation: build an instrumented clang (host target
# only) and run it on a fixed training workload so that the profile is
# identical on every run (see scripts/pgo-train.py for how). Both PGO trees
# are built without LTO: with -flto the training compiles would stop before
# code generation, and the backend would get no profile.
step_pgo() {
    step_extract
    check_stage1
    local -a common
    mapfile -t common < <(stage1_toolchain_args)

    log "PGO 1/2: instrumented clang"
    local -a toolchain
    mapfile -t toolchain < <(stage1_toolchain_files)
    fresh_if_toolchain_changed "$PGO_BUILD" "${toolchain[@]}"
    configure "$PGO_BUILD" "${common[@]}" \
        -DLLVM_ENABLE_PROJECTS=clang \
        -DLLVM_ENABLE_RUNTIMES= \
        -DLLVM_TARGETS_TO_BUILD=Native \
        -DLLVM_ENABLE_LTO=OFF \
        -DLLVM_BUILD_INSTRUMENTED=IR \
        -DLLVM_PARALLEL_LINK_JOBS="$(link_jobs 2)"
    ninja -C "$PGO_BUILD" -j "$JOBS" clang

    log "PGO 2/2: training"
    # The training tree is configured and its generated headers are built
    # with the plain stage-1 compiler; only its compile commands are replayed
    # with the instrumented clang. No precompiled headers: the training has
    # to exercise header parsing, which is most of a real compile.
    configure "$PGO_TRAIN" "${common[@]}" \
        -DLLVM_ENABLE_PROJECTS=clang \
        -DLLVM_ENABLE_RUNTIMES= \
        -DLLVM_TARGETS_TO_BUILD=Native \
        -DLLVM_ENABLE_LTO=OFF \
        -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    ninja -C "$PGO_TRAIN" -j "$JOBS" LLVMSupport LLVMCore clangSema
    rm -f "$PROFDATA.source-id"
    "$PYTHON" /repo/scripts/pgo-train.py \
        --clang-dir "$PGO_BUILD/bin" \
        --compdb "$PGO_TRAIN/compile_commands.json" \
        --src "$SRC" \
        --profiles "$PGO_PROFILES" \
        --llvm-profdata "$STAGE1/bin/llvm-profdata" \
        --output "$PROFDATA" \
        --jobs "$JOBS"
    source_id >"$PROFDATA.source-id"
    sha256sum "$PROFDATA"
}

step_stage2() {
    step_extract
    check_stage1
    local toolchain_only=ON fat_lto=OFF per_link=2 pgo_args=() common=()
    mapfile -t common < <(stage1_toolchain_args)
    [[ $INSTALL_MODE == full ]] && toolchain_only=OFF
    # ThinLTO links run their own threads; 16 GB each leaves room for the
    # compile jobs running next to them.
    [[ $LTO != OFF ]] && per_link=16
    # The full install ships LLVM's static libraries. With LTO they would
    # hold only bitcode, which GNU ld and gcc cannot link: emit native code
    # next to it (as the official releases do).
    [[ $INSTALL_MODE == full && $LTO != OFF ]] && fat_lto=ON
    if [[ $PGO == ON ]]; then
        [[ -f $PROFDATA && $(<"$PROFDATA.source-id") == "$(source_id)" ]] ||
            die "no PGO profile for these sources, run './build.sh pgo' (or set PGO=OFF)"
        pgo_args=(-DLLVM_PROFDATA_FILE="$PROFDATA")
    fi
    log "Stage 2: $("$STAGE1/bin/clang" --version | head -n1) -> $PROJECTS + $RUNTIMES (targets: $TARGETS, PGO: $PGO, LTO: $LTO, install: $INSTALL_MODE)"
    local -a toolchain
    mapfile -t toolchain < <(stage1_toolchain_files)
    [[ $PGO == ON ]] && toolchain+=("$PROFDATA")
    fresh_if_toolchain_changed "$STAGE2_BUILD" "${toolchain[@]}"
    # shellcheck disable=SC2086 # EXTRA_CMAKE_ARGS is intentionally word-split
    configure "$STAGE2_BUILD" "${common[@]}" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DLLVM_PROFDATA_FILE= "${pgo_args[@]}" \
        -DLLVM_ENABLE_PROJECTS="$PROJECTS" \
        -DLLVM_ENABLE_RUNTIMES="$RUNTIMES" \
        -DLLVM_TARGETS_TO_BUILD="$TARGETS" \
        -DLLVM_ENABLE_LTO="$LTO" \
        -DLLVM_ENABLE_FATLTO="$fat_lto" \
        -DLLVM_INSTALL_TOOLCHAIN_ONLY="$toolchain_only" \
        -DLLVM_PARALLEL_LINK_JOBS="$(link_jobs $per_link)" \
        -DCMAKE_SKIP_INSTALL_ALL_DEPENDENCY=ON \
        $EXTRA_CMAKE_ARGS
    # Build only what gets installed. LLVM's default target also builds test
    # utilities, fuzzer stubs, libclang-cpp.so and other things the toolchain
    # install does not ship (a third of the executables); with LTO each of
    # them is a long link. Installing every install component (into a
    # scratch directory) builds exactly what they need.
    local -a components
    mapfile -t components < <(ninja -C "$STAGE2_BUILD" -t targets all |
        sed -n 's/^\(install-.*-stripped\): .*/\1/p' | LC_ALL=C sort)
    ((${#components[@]})) || die "no install components found in $STAGE2_BUILD"
    rm -rf "$STAGE2_BUILD/components-install"
    DESTDIR=$STAGE2_BUILD/components-install ninja -C "$STAGE2_BUILD" -j "$JOBS" "${components[@]}"
    rm -rf "$STAGE2_BUILD/components-install"
    # The real install runs the complete install script (all components,
    # including files that have none) and fails if anything it needs was
    # not built.
    log "Installing into $DESTDIR$PREFIX"
    rm -rf "$DESTDIR"
    DESTDIR=$DESTDIR ninja -C "$STAGE2_BUILD" install/strip
}

# Highest GLIBC_x.y symbol version referenced by any ELF file in $1.
required_glibc() {
    find "$1" -type f -exec readelf --version-info --wide {} + 2>/dev/null |
        grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' | sort -uV | tail -n1
}

pgo_info() {
    if [[ $PGO == ON ]]; then
        echo "IR PGO, profile sha256 $(sha256sum "$PROFDATA" | cut -d' ' -f1)"
    else
        echo "OFF"
    fi
}

write_buildinfo() {
    local p
    cat <<EOF
LLVM $LLVM_VERSION toolchain for $DISTRO_NAME ($DISTRO), $ARCH

Source:            llvm-project-$LLVM_VERSION.src.tar.xz
Source sha256:     $(sha256sum "/repo/sources/llvm-project-$LLVM_VERSION.src.tar.xz" | cut -d' ' -f1)
Patches:           $(patches | xargs -r -n1 basename | tr '\n' ' ')
Base image:        $BASE_IMAGE
Install prefix:    $PREFIX (the tree is relocatable)
Projects:          $PROJECTS
Runtimes:          $RUNTIMES
Targets:           $TARGETS
PGO:               $(pgo_info)
LTO:               $LTO
Install mode:      $INSTALL_MODE
Extra CMake args:  $EXTRA_CMAKE_ARGS
Requires glibc:    >= $(required_glibc "$PKG_ROOT/$PKG_NAME")
SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH

Patch checksums:
EOF
    for p in $(patches); do echo "  $(sha256sum "$p" | cut -d' ' -f1)  $(basename "$p")"; done
    echo
    echo "Builder tools:"
    sed 's/^/  /' /opt/tools/TOOLS.txt
    echo
    echo "Builder image packages:"
    sed 's/^/  /' /opt/tools/PACKAGES.txt
}

step_package() {
    [[ -d $DESTDIR$PREFIX/bin ]] || die "stage 2 is not installed, run './build.sh stage2'"
    local dir=$PKG_ROOT/$PKG_NAME p
    log "Packaging $PKG_NAME"
    rm -rf "$PKG_ROOT"
    mkdir -p "$dir"
    cp -a "$DESTDIR$PREFIX/." "$dir/"

    mkdir -p "$dir/LICENSES"
    for p in llvm clang lld compiler-rt libcxx libcxxabi libunwind clang-tools-extra; do
        [[ $p == clang-tools-extra && ";$PROJECTS;" != *";$p;"* ]] && continue
        cp "$SRC/$p/LICENSE.TXT" "$dir/LICENSES/$p.txt"
    done
    write_buildinfo >"$dir/BUILD-INFO.txt"

    # Deterministic archive: sorted entries, fixed owner and timestamps.
    find "$dir" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
    tar -C "$PKG_ROOT" \
        --sort=name --format=posix \
        --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
        --owner=0 --group=0 --numeric-owner \
        --mtime="@$SOURCE_DATE_EPOCH" \
        -cf - "$PKG_NAME" |
        xz -9 --threads=4 >"/out/$PKG_NAME.tar.xz.part"
    mv "/out/$PKG_NAME.tar.xz.part" "/out/$PKG_NAME.tar.xz"
    (cd /out && sha256sum "$PKG_NAME.tar.xz" >"$PKG_NAME.tar.xz.sha256")
    { cat "$dir/BUILD-INFO.txt"; echo; echo "Builder repository revision: $REPO_REVISION"; } \
        >"/out/$PKG_NAME.BUILD-INFO.txt"

    log "Done"
    cat "/out/$PKG_NAME.tar.xz.sha256"
    du -h "/out/$PKG_NAME.tar.xz" | cut -f1
}

[[ $# -gt 0 ]] || die "usage: $0 <stage1|pgo|stage2|package>..."
for step in "$@"; do
    case $step in
        stage1 | pgo | stage2 | package) "step_$step" ;;
        *) die "unknown step '$step'" ;;
    esac
done
