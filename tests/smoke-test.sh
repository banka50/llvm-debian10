#!/bin/bash
# Smoke tests for a packaged toolchain. Runs as root inside a clean container
# of the distribution under test (started by `./build.sh test`):
#   /pkg/toolchain.tar.xz   the package
#   /pkg/sources.list       pinned apt sources for this distribution
#   /tests                  this directory
set -uo pipefail

LLVM=/opt/llvm
CASES=/tests/cases
W=/tmp/smoke
PASSED=0
FAILED=()

pass() { echo "PASS  $1"; PASSED=$((PASSED + 1)); }
fail() {
    echo "FAIL  $1"
    sed 's/^/      | /' <<<"$2" | tail -n 30
    FAILED+=("$1")
}

# ok <name> <command...>: the command must succeed.
ok() {
    local name=$1 out
    shift
    if out=$("$@" 2>&1); then pass "$name"; else fail "$name" "$out"; fi
}

# ok_output <name> <regex> <command...>: must succeed and print <regex>.
ok_output() {
    local name=$1 re=$2 out
    shift 2
    if ! out=$("$@" 2>&1); then
        fail "$name" "$out"
    elif grep -qE -- "$re" <<<"$out"; then
        pass "$name"
    else
        fail "$name" "output does not match /$re/:"$'\n'"$out"
    fi
}

# detects <name> <regex> <command...>: must FAIL and print <regex>
# (used for sanitizers, which have to catch the planted bug).
detects() {
    local name=$1 re=$2 out
    shift 2
    if out=$("$@" 2>&1); then
        fail "$name" "expected a non-zero exit, got 0:"$'\n'"$out"
    elif grep -qE -- "$re" <<<"$out"; then
        pass "$name"
    else
        fail "$name" "output does not match /$re/:"$'\n'"$out"
    fi
}

section() { printf '\n--- %s\n' "$*"; }

# ---------------------------------------------------------------------------
section "Setup"
. /etc/os-release
echo "Distribution: $PRETTY_NAME, glibc $(ldd --version | head -n1 | awk '{print $NF}')"

cp /pkg/sources.list /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/*
printf '%s\n' 'Acquire::Check-Valid-Until "false";' 'Acquire::Retries "5";' >/etc/apt/apt.conf.d/90smoke
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null || { echo "apt-get update failed"; exit 1; }
apt-get install -y -qq --no-install-recommends xz-utils >/dev/null || exit 1

mkdir -p "$LLVM" "$W"
tar -C "$LLVM" --strip-components=1 -xJf /pkg/toolchain.tar.xz || exit 1
export PATH=$LLVM/bin:$PATH
cd "$W" || exit 1
head -n 1 "$LLVM/BUILD-INFO.txt"

# ---------------------------------------------------------------------------
section "Shared library dependencies on a bare system"
# Before installing anything else: every binary and shared library must
# load with only the packages of a minimal Debian install plus the libraries
# shipped in the package itself (libc++.so.1 -> libc++abi.so.1 etc.).
pkg_libs=$(find "$LLVM/lib" -maxdepth 1 -type d -name '*-linux-gnu' -printf '%p:')$LLVM/lib
missing=$(
    find "$LLVM" -type f \( -perm -u+x -o -name '*.so*' \) -print0 |
        LD_LIBRARY_PATH=$pkg_libs xargs -0 -n 64 ldd 2>/dev/null | grep 'not found' | sort -u
)
if [[ -z $missing ]]; then pass "all ELF files resolve their shared libraries"; else fail "missing shared libraries" "$missing"; fi

# The compiler is built with LTO, the shipped static libraries and objects
# must not be: LLVM bitcode in them would break linking with GNU ld or gcc.
# llvm-objdump prints a "file format" line for every ELF archive member and
# silently skips bitcode ones.
bitcode=$(
    find "$LLVM" -type f \( -name '*.a' -o -name '*.o' \) -print0 | sort -z |
        while IFS= read -r -d '' f; do
            if [[ $f == *.a ]]; then members=$("$LLVM/bin/llvm-ar" t "$f" | wc -l); else members=1; fi
            elf=$("$LLVM/bin/llvm-objdump" -f "$f" 2>/dev/null | grep -c 'file format elf')
            [[ $elf == "$members" ]] || echo "$f: $elf of $members members are ELF"
        done
)
if [[ -z $bitcode ]]; then pass "static libraries and objects are plain ELF (no LTO bitcode)"; else fail "LTO bitcode in static libraries" "$bitcode"; fi

ok_output "clang --version" 'clang version' clang --version
ok_output "ld.lld --version" 'LLD' ld.lld --version
for tool in llvm-ar llvm-nm llvm-objdump llvm-readelf llvm-symbolizer llvm-profdata llvm-cov llvm-xray sancov; do
    ok "$tool --version" "$tool" --version
done

# ---------------------------------------------------------------------------
section "Installing the system C/C++ development packages"
apt-get install -y -qq --no-install-recommends g++ >/dev/null || exit 1
g++ --version | head -n1

TRIPLE=$(clang -print-target-triple)
LIBCXX_DIR=$LLVM/lib/$TRIPLE
RPATH=-Wl,-rpath,$LIBCXX_DIR

# ---------------------------------------------------------------------------
section "C and C++ with the system libraries"
ok "C, system linker" clang -O2 $CASES/hello.c -o hello_bfd
ok_output "C, system linker: run" 'hello from clang' ./hello_bfd
ok "C, lld" clang -O2 -fuse-ld=lld $CASES/hello.c -o hello_lld
ok_output "C, lld: run" 'hello from clang' ./hello_lld
ok "C++, libstdc++" clang++ -O2 -fuse-ld=lld $CASES/hello.cpp -o hello_stdcxx
ok_output "C++, libstdc++: run" 'sum=6' ./hello_stdcxx
ok "C++ exceptions, libstdc++" clang++ -O2 $CASES/exceptions.cpp -o exc_stdcxx
ok_output "C++ exceptions, libstdc++: run" "caught 'boom'" ./exc_stdcxx

# ---------------------------------------------------------------------------
section "libc++"
ok "libc++, shared" clang++ -stdlib=libc++ -O2 -fuse-ld=lld "$RPATH" $CASES/hello.cpp -o hello_cxx
ok_output "libc++, shared: run" 'sum=6' ./hello_cxx
ok_output "libc++, shared: linked against libc++.so.1" 'libc\+\+\.so\.1' ldd ./hello_cxx
ok "libc++, -static-libstdc++" clang++ -stdlib=libc++ -static-libstdc++ -O2 -fuse-ld=lld $CASES/hello.cpp -o hello_cxx_static
ok_output "libc++, -static-libstdc++: run" 'sum=6' ./hello_cxx_static
# -pthread: before glibc 2.34 the pthread functions are in a separate libpthread.a
ok "libc++, fully static" clang++ -stdlib=libc++ -static -pthread -O2 -fuse-ld=lld $CASES/hello.cpp -o hello_cxx_full_static
ok_output "libc++, fully static: run" 'sum=6' ./hello_cxx_full_static
ok "libc++ C++23 (<print>, <expected>, ranges)" clang++ -std=c++23 -stdlib=libc++ -O2 -fuse-ld=lld "$RPATH" $CASES/cxx23.cpp -o cxx23
ok_output "libc++ C++23: run" 'squares: \[1, 4, 9, 16, 25\]' ./cxx23
ok "libc++ exceptions, shared" clang++ -stdlib=libc++ -O2 "$RPATH" $CASES/exceptions.cpp -o exc_cxx
ok_output "libc++ exceptions, shared: run" "caught 'boom', 6 frames" ./exc_cxx
ok "libc++ exceptions, static" clang++ -stdlib=libc++ -static-libstdc++ -O2 $CASES/exceptions.cpp -o exc_cxx_static
ok_output "libc++ exceptions, static: run" "caught 'boom', 6 frames" ./exc_cxx_static
STD_CPPM=$LLVM/share/libc++/v1/std.cppm
ok "import std: precompile std.cppm" clang++ -std=c++23 -stdlib=libc++ -Wno-reserved-module-identifier --precompile "$STD_CPPM" -o std.pcm
ok "import std: build" clang++ -std=c++23 -stdlib=libc++ -fuse-ld=lld "$RPATH" -fmodule-file=std=std.pcm $CASES/std_module.cpp std.pcm -o std_module
ok_output "import std: run" 'import.*std.*works' ./std_module

# ---------------------------------------------------------------------------
section "Sanitizers"
ok "ASan: build" clang -g -O1 -fsanitize=address $CASES/asan.c -o asan
detects "ASan: heap-buffer-overflow" 'ERROR: AddressSanitizer: heap-buffer-overflow' ./asan
detects "ASan: report is symbolized" 'in main .*asan\.c:[0-9]+' ./asan
ok "ASan + libc++: build" clang++ -g -O1 -fsanitize=address -stdlib=libc++ "$RPATH" $CASES/asan_cxx.cpp -o asan_cxx
detects "ASan + libc++: heap-use-after-free" 'heap-use-after-free' ./asan_cxx
ok "UBSan: build" clang -g -fsanitize=undefined -fno-sanitize-recover=all $CASES/ubsan.c -o ubsan
detects "UBSan: signed integer overflow" 'runtime error: signed integer overflow' ./ubsan
ok "TSan: build" clang -g -O1 -fsanitize=thread $CASES/tsan.c -o tsan
detects "TSan: data race" 'WARNING: ThreadSanitizer: data race' ./tsan
ok "TSan + libc++ std::thread: build" clang++ -g -O1 -fsanitize=thread -stdlib=libc++ "$RPATH" $CASES/tsan_cxx.cpp -o tsan_cxx
detects "TSan + libc++ std::thread: data race" 'WARNING: ThreadSanitizer: data race' ./tsan_cxx
ok "MSan: build" clang -g -O1 -fsanitize=memory $CASES/msan.c -o msan
detects "MSan: use-of-uninitialized-value" 'use-of-uninitialized-value' ./msan
ok "LSan: build" clang -g -fsanitize=leak $CASES/lsan.c -o lsan
detects "LSan: leak" 'detected memory leaks' ./lsan
ok "ASan leak detection: build" clang -g -fsanitize=address $CASES/lsan.c -o asan_leak
detects "ASan leak detection" 'detected memory leaks' ./asan_leak
ok "DFSan: build" clang -fsanitize=dataflow $CASES/dfsan.c -o dfsan
ok "DFSan: run" ./dfsan
ok "SafeStack: build" clang -fsanitize=safe-stack $CASES/hello.c -o safestack
ok_output "SafeStack: run" 'hello from clang' ./safestack
ok "CFI (LTO + lld + UBSan runtime): build" clang++ -O1 -flto -fvisibility=hidden -fsanitize=cfi -fno-sanitize-trap=cfi -fuse-ld=lld $CASES/cfi.cpp -o cfi
detects "CFI: bad virtual call" 'control flow integrity check for type' ./cfi

# ---------------------------------------------------------------------------
section "libFuzzer, coverage, XRay"
ok "libFuzzer: build" clang -g -O1 -fsanitize=fuzzer,address $CASES/fuzzer.c -o fuzzer
detects "libFuzzer: finds the planted crash" 'deadly signal' ./fuzzer -seed=1 -max_total_time=120 -artifact_prefix=$W/
ok "coverage: build" clang -fprofile-instr-generate -fcoverage-mapping $CASES/hello.c -o cov
ok "coverage: run" env LLVM_PROFILE_FILE=cov.profraw ./cov
ok "coverage: llvm-profdata merge" llvm-profdata merge -o cov.profdata cov.profraw
ok_output "coverage: llvm-cov report" 'hello\.c' llvm-cov report ./cov -instr-profile=cov.profdata
ok "XRay: build" clang -g -fxray-instrument $CASES/xray.c -o xray
# func_duration_threshold_us=0: by default the basic mode drops calls < 5 us
ok_output "XRay: run" '^90$' env XRAY_OPTIONS="patch_premain=true xray_mode=xray-basic xray_logfile_base=xray-log." \
    XRAY_BASIC_OPTIONS="func_duration_threshold_us=0" ./xray
ok_output "XRay: llvm-xray account" 'twice' sh -c 'llvm-xray account -instr_map=./xray -sort=count -sortorder=dsc -top=5 xray-log.* | llvm-cxxfilt'

# ---------------------------------------------------------------------------
section "LTO and cross-compilation"
ok "ThinLTO + lld" clang -O2 -flto=thin -fuse-ld=lld $CASES/hello.c -o hello_thinlto
ok_output "ThinLTO + lld: run" 'hello from clang' ./hello_thinlto
ok "Full LTO + lld (C++)" clang++ -O2 -flto -fuse-ld=lld $CASES/hello.cpp -o hello_lto
ok_output "Full LTO + lld: run" 'sum=6' ./hello_lto
for t in aarch64-linux-gnu riscv64-linux-gnu wasm32-unknown-unknown; do
    arch=${t%%-*}
    if llc --version | grep -qw "$arch"; then
        ok "cross-compile object for $t" clang --target=$t -O2 -c $CASES/freestanding.c -o cross_$arch.o
        ok_output "cross-compiled object is $arch" "Arch: $arch\$" llvm-readobj --file-headers cross_$arch.o
    fi
done

# ---------------------------------------------------------------------------
section "Summary"
echo "passed: $PASSED, failed: ${#FAILED[@]}"
if ((${#FAILED[@]})); then
    printf '  failed: %s\n' "${FAILED[@]}"
    exit 1
fi
