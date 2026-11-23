# Stage 2: the shipped toolchain. Compiled by the stage-1 clang and linked
# with the stage-1 lld. The runtimes (compiler-rt with sanitizers, libc++,
# libc++abi, libunwind) are compiled by the freshly built stage-2 clang.
#
# Values that build.sh lets you change (projects, targets, LTO, install mode)
# are passed with -D on the command line and override the defaults below.

set(CMAKE_BUILD_TYPE Release CACHE STRING "")

set(LLVM_ENABLE_PROJECTS "clang;lld" CACHE STRING "")
set(LLVM_ENABLE_RUNTIMES "compiler-rt;libcxx;libcxxabi;libunwind" CACHE STRING "")
set(LLVM_TARGETS_TO_BUILD "all" CACHE STRING "")
# ThinLTO (with the PGO profile) for the compiler and tools, like the official
# LLVM releases. It does not reach the runtimes: they are a separate CMake
# build, so libc++.a, the sanitizer runtimes etc. stay plain ELF objects
# that any linker can use.
set(LLVM_ENABLE_LTO Thin CACHE STRING "")
set(LLVM_ENABLE_LLD ON CACHE BOOL "")

set(LLVM_ENABLE_ASSERTIONS OFF CACHE BOOL "")
set(LLVM_INCLUDE_TESTS OFF CACHE BOOL "")
set(LLVM_INCLUDE_EXAMPLES OFF CACHE BOOL "")
set(LLVM_INCLUDE_BENCHMARKS OFF CACHE BOOL "")
set(LLVM_INCLUDE_DOCS OFF CACHE BOOL "")
set(LLVM_ENABLE_BINDINGS OFF CACHE BOOL "")

# ---- Reproducibility ----------------------------------------------------------
# No VCS revision in version strings, no absolute source paths in binaries.
set(LLVM_APPEND_VC_REV OFF CACHE BOOL "")
set(LLVM_USE_RELATIVE_PATHS_IN_FILES ON CACHE BOOL "")

# ---- Dependencies -------------------------------------------------------------
# The toolchain must run on a bare Debian install, so the only shared
# libraries it may need are glibc, libstdc++/libgcc and zlib (Priority:
# required on Debian). zstd is linked statically from /usr/local.
set(LLVM_ENABLE_ZLIB FORCE_ON CACHE STRING "")
set(LLVM_ENABLE_ZSTD FORCE_ON CACHE STRING "")
set(LLVM_USE_STATIC_ZSTD ON CACHE BOOL "")
set(LLVM_ENABLE_LIBXML2 OFF CACHE STRING "")
set(LLVM_ENABLE_LIBEDIT OFF CACHE BOOL "")
set(LLVM_ENABLE_LIBPFM OFF CACHE BOOL "")
set(LLVM_ENABLE_FFI OFF CACHE BOOL "")
set(LLVM_ENABLE_Z3_SOLVER OFF CACHE BOOL "")
set(LLVM_ENABLE_CURL OFF CACHE BOOL "")
set(LLVM_ENABLE_HTTPLIB OFF CACHE BOOL "")

# ---- What gets installed ------------------------------------------------------
# "toolchain" install mode: compilers, linker, runtimes and the LLVM tools
# below, but not the LLVM/Clang development libraries and headers.
set(LLVM_INSTALL_TOOLCHAIN_ONLY ON CACHE BOOL "")
set(LLVM_TOOLCHAIN_TOOLS
  # binutils replacements
  llvm-addr2line llvm-ar llvm-cxxfilt llvm-dlltool llvm-dwp llvm-lib
  llvm-nm llvm-objcopy llvm-objdump llvm-ranlib llvm-rc llvm-readelf
  llvm-readobj llvm-size llvm-strings llvm-strip llvm-windres
  llvm-install-name-tool llvm-bitcode-strip llvm-otool llvm-lipo
  llvm-libtool-darwin llvm-ml llvm-ml64 llvm-mt llvm-pdbutil llvm-undname
  # debugging, profiling, coverage, sanitizers
  llvm-symbolizer llvm-dwarfdump llvm-dwarfutil llvm-gsymutil dsymutil
  llvm-profdata llvm-profgen llvm-cov llvm-cxxmap llvm-xray sancov sanstats
  llvm-ctxprof-util llvm-cgdata llvm-remarkutil llvm-debuginfo-analyzer
  # IR and codegen
  llvm-as llvm-dis llvm-link llvm-extract llvm-split llvm-modextract
  llvm-bcanalyzer llvm-diff llvm-mc llvm-mca llvm-lto llvm-lto2 llvm-ifs
  llvm-reduce llvm-tli-checker opt llc lli
  CACHE STRING "")

# ---- Runtimes -----------------------------------------------------------------
# Same choices as the official LLVM release builds:
#  * per-target runtime directories (lib/<triple>/, include/<triple>/),
#  * libc++abi is folded into libc++.a so `-static-libstdc++` works with
#    `-stdlib=libc++`,
#  * libc++abi uses LLVM's libunwind.
set(LLVM_ENABLE_PER_TARGET_RUNTIME_DIR ON CACHE BOOL "")
set(LIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY ON CACHE BOOL "")
set(LIBCXXABI_USE_LLVM_UNWINDER ON CACHE BOOL "")
set(LIBCXX_INSTALL_MODULES ON CACHE BOOL "")
# libc++ does not use libatomic on x86-64/aarch64, but CMake links it when it
# finds it in the builder (it comes with gcc). That would make every program
# using the shared libc++ depend on libatomic1, which a bare Debian lacks.
set(LIBCXX_HAS_ATOMIC_LIB OFF CACHE BOOL "")
# The runtimes are configured while the rest of stage 2 is still building.
# CMake looks for clang-scan-deps next to the compiler and, if it is there
# already, scans C++20+ targets (libc++abi) for modules, so the build would
# depend on timing. None of the runtimes uses C++20 modules for itself.
set(RUNTIMES_CMAKE_ARGS "-DCMAKE_CXX_SCAN_FOR_MODULES=OFF" CACHE STRING "")

# compiler-rt: everything that builds on Linux, spelled out for clarity.
set(COMPILER_RT_BUILD_BUILTINS ON CACHE BOOL "")
set(COMPILER_RT_BUILD_CRT ON CACHE BOOL "")
set(COMPILER_RT_BUILD_SANITIZERS ON CACHE BOOL "")
set(COMPILER_RT_BUILD_XRAY ON CACHE BOOL "")
set(COMPILER_RT_BUILD_LIBFUZZER ON CACHE BOOL "")
set(COMPILER_RT_BUILD_PROFILE ON CACHE BOOL "")
set(COMPILER_RT_BUILD_MEMPROF ON CACHE BOOL "")
set(COMPILER_RT_BUILD_ORC ON CACHE BOOL "")
set(COMPILER_RT_BUILD_GWP_ASAN ON CACHE BOOL "")
set(COMPILER_RT_BUILD_CTX_PROFILE ON CACHE BOOL "")
